import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math';

class Inverter {
  final String _address;
  final int _loggerSerial;
  final int _port;
  late Socket _socket;
  int? _sequenceNumber;
  final Random _random = Random();
  final Map<String, String> registers = {
    "70": "Daily Battery Charge(0.1 kwh)",
    "71": "Daily Battery Discharge(0.1 kwh)",
    "108": "Daily Production(0.1 kWh)",
    "109": "PV1 Voltage(0.1 V)",
    "110": "PV1 Current(0.1 A)",
    "111": "PV2 Voltage(0.1 V)",
    "112": "PV2 Current(0.1 A)",
    "183": "Battery Voltage(0.01 V)",
    "184": "Battery SOC(%)",
    "186": "PV1 Power(W)",
    "187": "PV2 Power(w)",
    "189": "Battery Status(0:Charge, 1:Stand-by, 2:Discharge)",
    "190": "Battery Power(W)",
    "191": "Battery Current(0.01 A)",
    "194": "Grid Relay Status(0:Off, 1:On)",
  };
  final List<Completer<Uint8List>> _requestQueue = [];

  // fixed v5 frame bytes (little endian)
  final int _v5start = 0xA5;
  final List<int> _v5requestControlCode = [0x10, 0x45];
  final List<int> _v5responseControlCode = [0x10, 0x15];
  late List<int> _v5LoggerSerial;
  final int _v5frameType = 0x02;
  final List<int> _v5sensorType = [0, 0];
  final List<int> _v5TimeFields = List<int>.filled(12, 0); // Total Working Time (four bytes)  + Power On Time (four bytes) + Offset Time (four bytes)
  final int _v5end = 0x15;

  Inverter._(this._address, this._loggerSerial, this._port);

  String get address => _address;
  int get serial => _loggerSerial;
  int get port => _port;

  static Future<List<Map<String, String>>> scan() async {
    Completer<void> completer = Completer<void>();
    List<Map<String, String>> dataLoggers = [];
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
              final values = data.split(",");
              final result = Map.fromIterables(keys, values);
              dataLoggers.add(result);
              completer.complete();
            } catch (e) {
              completer.completeError("Error parsing data: $e");
            }
          }
        }
      },
      onError: (error) {
        completer.completeError("Socket error: $error");
      },
    );
    const request = "WIFIKIT-214028-READ";
    final address = InternetAddress("255.255.255.255"); // Broadcast address
    const port = 48899;

    socket.send(request.codeUnits, address, port);
    await completer.future.timeout(const Duration(seconds: 5));

    socket.close();
    return dataLoggers;
  }

  static Future<Inverter> init({required address, required loggerSerial, port = 8899}) async {
    List<int> v5loggerSerial = [
      loggerSerial & 0xFF,
      (loggerSerial >> 8) & 0xFF,
      (loggerSerial >> 16) & 0xFF,
      (loggerSerial >> 24) & 0xFF,
    ];

    var instance = Inverter._(address, loggerSerial, port);
    instance._v5LoggerSerial = v5loggerSerial;
    instance._socket = await Socket.connect(address, port).timeout(const Duration(seconds: 10), onTimeout: () {
      throw TimeoutException('Connection timed out');
    });
    instance._start();

    return instance;
  }

  void _start() {
    _socket.listen((Uint8List v5ResponseFrame) {
      try {
        Uint8List mbResposeFrame = _decodeV5frame(v5ResponseFrame);
        if (_requestQueue.isNotEmpty) {
          _requestQueue[0].complete(mbResposeFrame);
        }
      } catch (e) {
        print(e);
      }
    }, onDone: () {
      _socket.close();
    }, onError: (error) {
      _socket.close();
    });
  }

  Future<Map<String, int>> readHoldingRegisters({required int register, required int quantity}) async {
    Uint8List mbRequestFrame = _encodeMbFrame(1, register, quantity, 0x03);
    Uint8List v5RequestFrame = _encodeV5frame(mbRequestFrame);

    final completer = Completer<Uint8List>();
    _requestQueue.add(completer);
    _socket.add(v5RequestFrame);

    Uint8List mbResposeFrame = await completer.future.timeout(const Duration(seconds: 5), onTimeout: () async {
      _requestQueue.remove(completer);
      throw TimeoutException("Response Timeout");
    });
    _requestQueue.remove(completer);
    Map<String, int> data = _decodeMbFrame(register, mbResposeFrame);

    return data;
  }

  Uint8List _encodeMbFrame(int slaveId, int startAddress, int quantity, int functionCode) {
    Uint8List data = Uint8List.fromList([
      slaveId,
      functionCode,
      (startAddress >> 8) & 0xFF, // High byte of the start address
      startAddress & 0xFF, // Low byte of the start address
      (quantity >> 8) & 0xFF, // High byte of the quantity
      quantity & 0xFF, // Low byte of the quantity
    ]);

    int crc = _calculateCRC(data);

    Uint8List frame = Uint8List.fromList([
      ...data,
      (crc >> 8) & 0xFF, // High byte of the CRC
      crc & 0xFF, // Low byte of the CRC
    ]);

    return frame;
  }

  int _calculateCRC(Uint8List data) {
    int crc = 0xFFFF;

    for (int byte in data) {
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

  Uint8List _encodeV5frame(Uint8List mbRequestFrame) {
    int payloadLength = 15 + mbRequestFrame.length;

    if (_sequenceNumber == null) {
      _sequenceNumber = _random.nextInt(0xFF);
    } else {
      _sequenceNumber = (_sequenceNumber! + 1) & 0xFF;
    }

    Uint8List v5header = Uint8List.fromList([
      _v5start, // start
      payloadLength & 0xFF, // length low
      (payloadLength >> 8) & 0xFF, // length high
      ..._v5requestControlCode,
      _sequenceNumber! & 0xFF, // sequence number low
      (_sequenceNumber! >> 8) & 0xFF, // sequence number high
      ..._v5LoggerSerial,
    ]);

    Uint8List v5payload = Uint8List.fromList([
      _v5frameType, // Frame Type
      ..._v5sensorType, // Sensor Type
      ..._v5TimeFields, // Offset Time
      ...mbRequestFrame // Modbus Frame
    ]);

    int checksum = _checksum([...v5header, ...v5payload, 0, 0]);
    Uint8List v5trailer = Uint8List.fromList([checksum, _v5end]);

    return Uint8List.fromList([...v5header, ...v5payload, ...v5trailer]);
  }

  Uint8List _decodeV5frame(Uint8List frame) {
    int length = frame.length;
    int payloadLength = (frame[2] & 0xFFFF) << 8 | frame[1];

    if (frame[0] != _v5start || frame[length - 1] != _v5end) {
      throw Exception("V5 frame contains invalid start or end values");
    }
    if (length != payloadLength + 13) {
      throw Exception("frame_len does not match payload_len");
    }
    if (frame[length - 2] != _checksum(frame)) {
      throw Exception("V5 frame contains invalid V5 checksum");
    }
    if (frame[5] != _sequenceNumber! & 0xFF) {
      throw Exception("V5 frame contains invalid sequence number");
    }
    if (!_isEqual(frame.sublist(7, 11), _v5LoggerSerial)) {
      throw Exception("V5 frame contains incorrect data logger serial number");
    }
    if (!_isEqual(frame.sublist(3, 5), _v5responseControlCode)) {
      throw Exception("V5 frame contains incorrect control code");
    }
    if (frame[11] != _v5frameType) {
      throw Exception("V5 frame contains invalid frametype");
    }

    Uint8List mbFrame = frame.sublist(25, length - 2);
    if (mbFrame.length < 5) {
      throw Exception("V5 frame does not contain a valid Modbus RTU frame");
    }

    return mbFrame;
  }

  Map<String, int> _decodeMbFrame(int register, Uint8List frame) {
    Map<String, int> data = {};
    for (var i = 3; i < frame.length - 2; i += 2) {
      if (registers["$register"] != null) {
        int value = (frame[i] & 0xFFFF) << 8 | frame[i + 1];
        data[registers["$register"]!] = value;
      }
      register++;
    }
    return data;
  }

  bool _isEqual(List<int> list1, List<int> list2) {
    if (list1.length != list2.length) return false;
    for (var i = 0; i < list1.length; i++) {
      if (list1[i] != list2[i]) {
        return false;
      }
    }
    return true;
  }

  int _checksum(List<int> data) {
    int checksum = 0;
    for (int i = 1; i < data.length - 2; i++) {
      checksum += data[i] & 0xFF;
    }
    return checksum & 0xFF;
  }

  Future<void> closeSocket() async {
    await _socket.close();
  }
}
