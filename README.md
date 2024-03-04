# Deye Inverter Connect

Dart code for interacting with Solarman data collectors used with Deye inverter. You can use this code in flutter or directly from cmd.

This code is made with the help of Pysolarman by Jonathan McCrohan [pysolarmanv5](https://github.com/jmccrohan/pysolarmanv5)

# How to use

### 1. Initialize Connection

You need data logger ip address and serial number

```dart
 Inverter inverter = await Inverter.init(address: "192.168.1.50", loggerSerial: 27xxxxxxxx);
```

### 2. Read Data

To read data you need to set starting register (e.g.: 184 which represent Battery SOC) and the number of registers to read starting from the register number you put.

```dart
 var data = await inverter.readHoldingRegisters(register: 184, quantity: 10);
```

Note that the register must be defined in the registers map in the code. I already added some :

```dart
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
```

you can refer to Modbus.pdf file I provided for more registers

### 3. Use Data

The data is structured in a map, you can print it or do whatever you want.

```dart
 print(data);
```

output :

```json
 {
  Battery SOC(%): 99,
  PV1 Power(W): 10,
  PV2 Power(w): 12,
  Battery Status(0:Charge, 1:Stand-by, 2:Discharge): 0,
  Battery Power(W): 202,
  Battery Current(0.01 A): 382,
  Grid Relay Status(0:Off, 1:On): 0
 }
```
