import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

/// Describes a known Modbus holding register: its human-readable name, and
/// whether its raw 16-bit value should be interpreted as signed (two's
/// complement) rather than unsigned.
class RegisterDef {
  final String name;
  final bool signed;
  const RegisterDef(this.name, {this.signed = false});
}

/// SolarmanV5 / Modbus RTU inverter communication class.
/// Wraps a persistent TCP socket to a data-logger device.
class Inverter {
  final String _address;
  final int _loggerSerial;
  final int _port;
  late Socket _socket;
  int? _sequenceNumber;
  final Random _random = Random();

  /// Known register definitions keyed by Modbus address (as string).
  ///
  /// These addresses are for the Deye hybrid inverter family (e.g.
  /// SUN-5K-SG03LP1-EU) via a Solarman-compatible data logger. Register
  /// layouts are inverter-model specific — verify against your own
  /// inverter's register map before trusting values from a different model.
  ///
  /// Confirmed directly against real hardware (Deye SUN-5K-SG03LP1-EU +
  /// Solarman LSW-3 stick logger):
  ///   184 → Battery SOC
  ///   194 → Grid Relay Status
  ///
  /// The rest are sourced from community Modbus documentation for the Deye
  /// hybrid inverter family and have not been individually verified against
  /// this author's hardware.
  ///
  /// Scale/unit (not applied to returned values — see [readHoldingRegisters]):
  ///   70  Daily Battery Charge     ×0.1  kWh
  ///   71  Daily Battery Discharge  ×0.1  kWh
  ///   108 Daily Production        ×0.1  kWh
  ///   109 PV1 Voltage              ×0.1  V
  ///   110 PV1 Current              ×0.1  A
  ///   111 PV2 Voltage              ×0.1  V
  ///   112 PV2 Current              ×0.1  A
  ///   183 Battery Voltage          ×0.01 V
  ///   184 Battery SOC              ×1    %
  ///   186 PV1 Power                ×1    W
  ///   187 PV2 Power                ×1    W
  ///   189 Battery Status           lookup: 0=Charge, 1=Stand-by, 2=Discharge
  ///   190 Battery Power            ×1    W     (signed)
  ///   191 Battery Current          ×0.01 A     (signed)
  ///   194 Grid Relay Status        lookup: 0=Off, 1=On
  static const Map<String, RegisterDef> registers = {
    '70': RegisterDef('Daily Battery Charge'),
    '71': RegisterDef('Daily Battery Discharge'),
    '108': RegisterDef('Daily Production'),
    '109': RegisterDef('PV1 Voltage'),
    '110': RegisterDef('PV1 Current'),
    '111': RegisterDef('PV2 Voltage'),
    '112': RegisterDef('PV2 Current'),
    '183': RegisterDef('Battery Voltage'),
    '184': RegisterDef('Battery SOC'),
    '186': RegisterDef('PV1 Power'),
    '187': RegisterDef('PV2 Power'),
    '189': RegisterDef('Battery Status'),
    '190': RegisterDef('Battery Power', signed: true),
    '191': RegisterDef('Battery Current', signed: true),
    '194': RegisterDef('Grid Relay Status'),
  };

  final List<Completer<Uint8List>> _requestQueue = [];

  // SolarmanV5 frame constants (little-endian)
  final int _v5start = 0xA5;
  final List<int> _v5requestControlCode = [0x10, 0x45];
  final List<int> _v5responseControlCode = [0x10, 0x15];
  late List<int> _v5LoggerSerial;
  final int _v5frameType = 0x02;
  final List<int> _v5sensorType = [0, 0];
  // Total Working Time (4 bytes) + Power On Time (4 bytes) + Offset Time (4 bytes)
  final List<int> _v5TimeFields = List<int>.filled(12, 0);
  final int _v5end = 0x15;

  Inverter._(this._address, this._loggerSerial, this._port);

  String get address => _address;
  int get serial => _loggerSerial;
  int get port => _port;

  /// Broadcasts UDP discovery packet to find loggers on local network.
  /// Returns a list of maps with keys: ipAddress, mac, serial.
  static Future<List<Map<String, String>>> scan() async {
    final completer = Completer<void>();
    final List<Map<String, String>> dataLoggers = [];

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;

    socket.listen(
      (RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = socket.receive();
          if (datagram != null) {
            final data = String.fromCharCodes(datagram.data);
            try {
              final keys = ['ipAddress', 'mac', 'serial'];
              final values = data.split(',');
              if (values.length >= 3) {
                final result = Map.fromIterables(keys, values.take(3));
                dataLoggers.add(result);
                if (!completer.isCompleted) completer.complete();
              }
            } catch (_) {
              // Ignore malformed packets
            }
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );

    const request = 'WIFIKIT-214028-READ';
    final broadcastAddr = InternetAddress('255.255.255.255');
    const discoveryPort = 48899;

    socket.send(request.codeUnits, broadcastAddr, discoveryPort);

    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Timeout is expected if no loggers found
    } finally {
      socket.close();
    }

    return dataLoggers;
  }

  /// Creates and connects an Inverter instance to the given address.
  static Future<Inverter> init({
    required String address,
    required int loggerSerial,
    int port = 8899,
  }) async {
    final v5loggerSerial = [
      loggerSerial & 0xFF,
      (loggerSerial >> 8) & 0xFF,
      (loggerSerial >> 16) & 0xFF,
      (loggerSerial >> 24) & 0xFF,
    ];

    final instance = Inverter._(address, loggerSerial, port);
    instance._v5LoggerSerial = v5loggerSerial;
    instance._socket = await Socket.connect(address, port).timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw TimeoutException('Connection timed out'),
    );
    instance._startListening();

    return instance;
  }

  void _startListening() {
    _socket.listen(
      (Uint8List v5ResponseFrame) {
        try {
          final mbFrame = _decodeV5frame(v5ResponseFrame);
          if (_requestQueue.isNotEmpty) {
            _requestQueue[0].complete(mbFrame);
          }
        } catch (_) {
          // Keep-alive packets or malformed frames are silently ignored
        }
      },
      onDone: _socket.close,
      onError: (_) => _socket.close(),
    );
  }

  /// Reads [quantity] holding registers starting at [register].
  ///
  /// Returns a map of register-name → raw integer value, sign-corrected for
  /// registers known to be signed (see [registers]). Scale factors (e.g.
  /// PV voltage is ×0.1 V) are documented on [registers] but *not* applied
  /// here — apply them yourself if you need real-world units.
  Future<Map<String, int>> readHoldingRegisters({
    required int register,
    required int quantity,
  }) async {
    final mbRequest = _encodeMbFrame(1, register, quantity, 0x03);
    final v5Request = _encodeV5frame(mbRequest);

    final completer = Completer<Uint8List>();
    _requestQueue.add(completer);
    _socket.add(v5Request);

    final mbResponse = await completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _requestQueue.remove(completer);
        throw TimeoutException('Response timeout');
      },
    );
    _requestQueue.remove(completer);

    return _decodeMbFrame(register, mbResponse);
  }

  Uint8List _encodeMbFrame(
      int slaveId, int startAddress, int quantity, int functionCode) {
    final data = Uint8List.fromList([
      slaveId,
      functionCode,
      (startAddress >> 8) & 0xFF,
      startAddress & 0xFF,
      (quantity >> 8) & 0xFF,
      quantity & 0xFF,
    ]);

    final crc = _calculateCRC(data);
    return Uint8List.fromList([
      ...data,
      (crc >> 8) & 0xFF,
      crc & 0xFF,
    ]);
  }

  int _calculateCRC(Uint8List data) {
    int crc = 0xFFFF;
    for (final byte in data) {
      crc ^= byte;
      for (int i = 0; i < 8; i++) {
        if ((crc & 0x0001) != 0) {
          crc >>= 1;
          crc ^= 0xA001;
        } else {
          crc >>= 1;
        }
      }
    }
    return ((crc & 0xFF) << 8) | ((crc >> 8) & 0xFF);
  }

  Uint8List _encodeV5frame(Uint8List mbFrame) {
    final payloadLength = 15 + mbFrame.length;

    _sequenceNumber = _sequenceNumber == null
        ? _random.nextInt(0xFF)
        : (_sequenceNumber! + 1) & 0xFF;

    final header = Uint8List.fromList([
      _v5start,
      payloadLength & 0xFF,
      (payloadLength >> 8) & 0xFF,
      ..._v5requestControlCode,
      _sequenceNumber! & 0xFF,
      (_sequenceNumber! >> 8) & 0xFF,
      ..._v5LoggerSerial,
    ]);

    final payload = Uint8List.fromList([
      _v5frameType,
      ..._v5sensorType,
      ..._v5TimeFields,
      ...mbFrame,
    ]);

    final checksum = _checksum([...header, ...payload, 0, 0]);
    final trailer = Uint8List.fromList([checksum, _v5end]);

    return Uint8List.fromList([...header, ...payload, ...trailer]);
  }

  Uint8List _decodeV5frame(Uint8List frame) {
    final length = frame.length;
    final payloadLength = (frame[2] & 0xFFFF) << 8 | frame[1];

    if (frame[0] != _v5start || frame[length - 1] != _v5end) {
      throw Exception('V5 frame: invalid start/end bytes');
    }
    if (length != payloadLength + 13) {
      throw Exception('V5 frame: length mismatch');
    }
    if (frame[length - 2] != _checksum(frame)) {
      throw Exception('V5 frame: invalid checksum');
    }
    if (frame[5] != (_sequenceNumber! & 0xFF)) {
      throw Exception('V5 frame: invalid sequence number');
    }
    if (!_bytesEqual(frame.sublist(7, 11), _v5LoggerSerial)) {
      throw Exception('V5 frame: wrong logger serial');
    }
    if (!_bytesEqual(frame.sublist(3, 5), _v5responseControlCode)) {
      throw Exception('V5 frame: wrong control code');
    }
    if (frame[11] != _v5frameType) {
      throw Exception('V5 frame: wrong frame type');
    }

    final mbFrame = frame.sublist(25, length - 2);
    if (mbFrame.length < 5) {
      throw Exception('V5 frame: embedded Modbus frame too short');
    }

    return mbFrame;
  }

  Map<String, int> _decodeMbFrame(int startRegister, Uint8List frame) {
    final data = <String, int>{};
    int reg = startRegister;
    for (int i = 3; i < frame.length - 2; i += 2) {
      final def = registers['$reg'];
      if (def != null) {
        final raw = (frame[i] & 0xFFFF) << 8 | frame[i + 1];
        data[def.name] = def.signed ? raw.toSigned(16) : raw;
      }
      reg++;
    }
    return data;
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int _checksum(List<int> data) {
    int sum = 0;
    for (int i = 1; i < data.length - 2; i++) {
      sum += data[i] & 0xFF;
    }
    return sum & 0xFF;
  }

  Future<void> closeSocket() async {
    await _socket.close();
  }
}
