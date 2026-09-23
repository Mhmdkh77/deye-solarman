# deye_solarman

> **Tested on:** Deye SUN-5K-SG03LP1-EU hybrid inverter + Solarman LSW-3
> WiFi stick logger. Should work with other inverters in the Deye hybrid
> family via a Solarman-compatible logger, but only two registers (`184`,
> `194`) have actually been verified against real hardware — see
> [Registers](#registers) before trusting the rest.

A Dart implementation of the **SolarmanV5 / Modbus RTU** protocol used by
Solarman-compatible data loggers on Deye hybrid solar inverters — read
battery SOC, PV power, grid status and more directly over your local
network, no cloud account required.

Framework-agnostic: works the same from a Flutter app or a plain `dart run`
script. Used in [Solar Grid](https://github.com/Mhmdkh77/solargrid), a
Flutter inverter-monitoring app.

Built with reference to [pysolarmanv5](https://github.com/jmccrohan/pysolarmanv5)
by Jonathan McCrohan.

## Terminology

- **Data logger** — the network-connected dongle (e.g. a Solarman LSW-3
  "stick logger") plugged into your inverter's communication port. This is
  what this library actually talks to over TCP/IP; it bridges the
  inverter's Modbus registers onto your local network.
- **Inverter** — the solar inverter itself. Its data (battery SOC, PV
  power, etc.) is what you're ultimately reading, relayed through the
  logger.

This library models the connection as an `Inverter` object for readability,
but every connection detail you give it — IP address, port, serial number —
belongs to the **data logger**, not the inverter.

## Capabilities

- Discover data loggers on your local network via UDP broadcast (`Inverter.scan()`)
- Connect directly to a known logger by IP + serial number, no discovery needed
- Read any Modbus holding register range (`readHoldingRegisters`)
- Built-in name/scale/signed metadata for 14 known Deye hybrid registers —
  battery SOC/voltage/power/current/status, PV1/PV2 voltage/current/power,
  grid relay status, daily production/charge/discharge
- Correct sign handling for registers that can go negative (e.g. battery
  power/current when charging vs. discharging)
- Clean socket teardown (`closeSocket()`)

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

### 1. Get the logger's IP address and serial number

You need two things to connect: the data logger's **serial number**
(printed on a label on the logger itself) and its **IP address** — which is
*not* printed anywhere. Once the logger has joined your WiFi, its IP is
assigned by your router's DHCP, so you get it one of two ways:

- **Scan for it** — `Inverter.scan()` broadcasts a UDP discovery packet and
  returns any loggers that respond, IP and serial included (see below), or
- **Enter it manually**, if you already know it — check your router's
  connected-devices list or the Solarman/Deye phone app.

Either way, your app needs to be on the **same local network** as the
logger. UDP broadcast discovery in particular only reaches devices on the
same subnet — routers don't forward broadcast packets — so `scan()` won't
find a logger on a different network, even if a direct TCP connection to a
known IP might still reach it.

If the logger has never been set up on your WiFi, it starts in its own
access-point mode — connect to its `AP_<serial>` WiFi network and open
`10.10.100.254` in a browser to configure it first. This library doesn't
handle that initial setup step; it assumes the logger is already on your
network.

### 2a. Scan for loggers on the network

```dart
import 'package:deye_solarman/deye_solarman.dart';

final loggers = await Inverter.scan();
// [{ipAddress: 192.168.1.50, mac: ..., serial: 2739492956}]
```

### 2b. Or connect directly if you already know the IP and serial

```dart
final inverter = await Inverter.init(
  address: '192.168.1.50',
  loggerSerial: 2739492956,
);
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
