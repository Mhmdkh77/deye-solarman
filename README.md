# deye_solarman

A Dart implementation of the **SolarmanV5 / Modbus RTU** protocol used by
Solarman-compatible data loggers on Deye hybrid solar inverters — read
battery SOC, PV power, grid status and more directly over your local
network, no cloud account required.

Framework-agnostic: works the same from a Flutter app or a plain `dart run`
script. Used in [Solar Grid](https://github.com/Mhmdkh77/solargrid), a
Flutter inverter-monitoring app.

Built with reference to [pysolarmanv5](https://github.com/jmccrohan/pysolarmanv5)
by Jonathan McCrohan.

## Install

Not published on pub.dev — depend on it directly from GitHub:

```yaml
dependencies:
  deye_solarman:
    git:
      url: https://github.com/Mhmdkh77/deye-solarman
      ref: v1.0.0 # pin to a tag; omit to track main
```

## Usage

### 1. Connect

You need the data logger's IP address and serial number (both are printed
on the logger itself, or discoverable via `Inverter.scan()`).

```dart
import 'package:deye_solarman/deye_solarman.dart';

final inverter = await Inverter.init(
  address: '192.168.1.50',
  loggerSerial: 2739492956,
);
```

### 2. Discover loggers on the network (optional)

Broadcasts a UDP discovery packet and returns any loggers that respond,
with their IP, MAC and serial number:

```dart
final loggers = await Inverter.scan();
```

### 3. Read registers

Pass a starting register address and how many consecutive registers to
read:

```dart
final data = await inverter.readHoldingRegisters(register: 184, quantity: 11);
print(data); // {Battery SOC: 82, Grid Relay Status: 1}
```

Only addresses present in `Inverter.registers` are returned — others in the
requested range are read from the device but dropped, so it's safe to over-read
a range.

Values are returned as **raw register integers** — scale factors (e.g. PV
voltage is ×0.1 V) are documented below but not applied automatically, so
multiply them yourself if you need real-world units. Registers marked
"signed" are already sign-corrected (two's complement).

### 4. Disconnect

```dart
await inverter.closeSocket();
```

## Registers

Addresses are for the **Deye hybrid inverter family** (e.g.
SUN-3.6/5/6K-SG03LP1-EU) via a Solarman-compatible data logger. Register
layouts are inverter-model specific — verify against your own inverter's
register map before trusting values from a different model.

`184` (Battery SOC) and `194` (Grid Relay Status) are confirmed directly
against real hardware (Deye SUN-5K-SG03LP1-EU + Solarman LSW-3 stick
logger). The rest are sourced from community Modbus documentation for the
Deye hybrid family and haven't been individually verified against this
author's hardware.

| Address | Name | Scale | Unit | Signed |
|---|---|---|---|---|
| 70 | Daily Battery Charge | ×0.1 | kWh | |
| 71 | Daily Battery Discharge | ×0.1 | kWh | |
| 108 | Daily Production | ×0.1 | kWh | |
| 109 | PV1 Voltage | ×0.1 | V | |
| 110 | PV1 Current | ×0.1 | A | |
| 111 | PV2 Voltage | ×0.1 | V | |
| 112 | PV2 Current | ×0.1 | A | |
| 183 | Battery Voltage | ×0.01 | V | |
| **184** | **Battery SOC** | ×1 | % | |
| 186 | PV1 Power | ×1 | W | |
| 187 | PV2 Power | ×1 | W | |
| 189 | Battery Status | — | lookup: 0=Charge, 1=Stand-by, 2=Discharge | |
| 190 | Battery Power | ×1 | W | ✅ |
| 191 | Battery Current | ×0.01 | A | ✅ |
| **194** | **Grid Relay Status** | — | lookup: 0=Off, 1=On | |

See `Modbus.pdf` in this repo for a fuller Deye Modbus register reference.

## Protocol notes

- Data loggers listen on TCP port `8899` for the Modbus-over-SolarmanV5
  frame protocol, and respond to UDP discovery broadcasts on port `48899`.
- Each `Inverter` wraps one persistent TCP socket; open one per logger and
  reuse it across reads rather than reconnecting per request.
