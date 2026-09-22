# GPIO/SPI Implementation Status

## Overview
This document tracks the implementation of GPIO/SPI RFID reading functionality for Raspberry Pi with 7 RC522 modules.

## ✅ Completed Implementation

### 1. Core SPI Communication
- **File**: `lib/adapters/gpio_spi_rfid_adapter.dart`
- **Status**: ✅ Complete
- **Details**:
  - SPI initialization using `dart_periphery` library (1 MHz clock, Mode 0)
  - SPI device: `/dev/spidev0.0`
  - Proper CS/SS pin control (LOW during transfer, HIGH idle)
  - Error handling with guaranteed SS pin state
  
**Methods Implemented**:
```dart
- _spiWrite(register, value)     // Write single byte to MFRC522 register
- _spiRead(register)              // Read single byte from register
- _spiReadMultiple(register, count) // Read multiple bytes (for FIFO)
```

### 2. MFRC522 Protocol
- **Status**: ✅ Complete
- **Implemented Commands**:
  - REQA (Request Type A) - Card detection
  - ANTICOLL (Anti-collision) - UID reading
  
**Methods Implemented**:
```dart
- _initializeMFRC522()  // Hardware reset, soft reset, register config, antenna enable
- _requestCard()        // REQA command with ATQA response validation
- _readCardUID()        // ANTICOLL with BCC verification (4-byte UID)
```

**Protocol Flow**:
1. Send REQA command (0x26) via FIFO
2. Configure bit framing (7 bits)
3. Execute Transceive command
4. Wait for ATQA response (2 bytes)
5. On success, send ANTICOLL (0x93)
6. Read 5 bytes: 4-byte UID + 1-byte BCC
7. Verify BCC (XOR of UID bytes)

### 3. GPIO Control
- **Status**: ✅ Complete
- **Implementation**: sysfs-based GPIO (/sys/class/gpio)
- **Controlled Pins**:
  - RST pin: Hardware reset for MFRC522
  - SS pin: Chip select for SPI communication

### 4. Hardware Initialization
- **Status**: ✅ Complete
- **Sequence**:
  1. Hardware reset via RST pin (LOW → HIGH with delays)
  2. Software reset command
  3. Wait for PowerDown bit clear
  4. Configure timer registers (timeout handling)
  5. Configure TX (100% ASK modulation)
  6. Set CRC preset (0x6363)
  7. Enable antenna
  8. Verify MFRC522 version (expects 0x91 or 0x92)

## 📋 Register Definitions

All MFRC522 registers defined in `MFRC522Registers` class:
- Command/Status: `commandReg`, `comIrqReg`, `errorReg`
- FIFO: `fifoDataReg`, `fifoLevelReg`
- Control: `controlReg`, `bitFramingReg`
- Mode: `modeReg`, `txControlReg`, `txASKReg`
- Timer: `tModeReg`, `tPrescalerReg`, `tReloadRegH/L`
- Version: `versionReg`

## 🔧 Technical Details

### SPI Protocol
```
Write: [Address byte (MSB=0)] [Data byte]
Read:  [Address byte (MSB=1)] [Dummy 0x00] → Response byte
```

### Pin Configuration (Per Module)
```
Module #X:
- SPI Bus: Shared /dev/spidev0.0
- MISO: GPIO 9 (shared)
- MOSI: GPIO 10 (shared)
- SCK:  GPIO 11 (shared)
- CE0:  GPIO 8 (shared, wired to the SDA/SS of all 7 modules)
- RST:  Unique per module (22, 27, 17, 4, 23, 24, 25 for modules 1-7;
        see `defaultReaderConfigs` in `lib/models/rfid_models.dart`)
```

### Dependencies
```yaml
dart_periphery: ^0.9.19  # SPI, GPIO access
```

## ⏳ Pending Tasks

### 3. Hardware Testing Suite
**Priority**: HIGH  
**Prerequisites**: Raspberry Pi with RC522 modules connected

**Test Cases to Implement**:
- [ ] GPIO loopback tests
- [ ] SPI version register read (verify MFRC522 communication)
- [ ] Single module RFID test
- [ ] 7-module concurrent scanning
- [ ] Performance benchmark (target: <2s for 7 modules)

**File to Create**: `test/hardware/gpio_test.dart`

### 4. UI Integration
**Priority**: MEDIUM  
**Prerequisites**: GPIO adapter functional

**Tasks**:
- [ ] Replace `OrderPage` → `RefactoredOrderPage` in `input_screen.dart`
- [ ] Replace `SettingPage` → `RefactoredSettingPage` in `setting_screen.dart`
- [ ] Remove `SerialPortsProvider` dependencies
- [ ] Use `MealIdentificationService` instead of direct `idToMealName` lookup
- [ ] Test platform detection (RFID_MODE environment variable)

### 5. Unit Tests
**Priority**: MEDIUM

**Coverage Needed**:
- [ ] Mock adapter scenarios (4 test cases ready)
- [ ] Meal identification service
- [ ] Platform detection logic
- [ ] Error handling paths

**File to Create**: `test/unit/rfid_adapter_test.dart`

### 6. Raspberry Pi Hardware Testing
**Priority**: HIGH  
**Prerequisites**: Tasks 3, 4 complete

**Validation**:
- [ ] All 7 modules detected and initialized
- [ ] Correct UID reading for known cards
- [ ] Meal name mapping accuracy
- [ ] Performance meets <2s requirement
- [ ] Error recovery (card removed mid-scan)

### 7. Production Deployment
**Priority**: LOW  
**Prerequisites**: All above tasks complete

**Deployment Steps**:
- [ ] Final code review
- [ ] Documentation update
- [ ] Backup current Arduino-based system
- [ ] Deploy to production Raspberry Pi
- [ ] Monitor for 24 hours
- [ ] Decommission Arduino setup

## 🧪 Testing Commands

### Run with Mock Adapter (No Hardware)
```bash
RFID_MODE=mock flutter run
```

### Run with Serial Adapter (Current Arduino Setup)
```bash
RFID_MODE=serial flutter run
```

### Run with GPIO Adapter (Raspberry Pi)
```bash
# Auto-detected when running on Raspberry Pi
flutter run

# Or explicitly force GPIO mode
RFID_MODE=gpio flutter run
```

## 📊 Implementation Progress

| Component | Status | Lines of Code | Test Coverage |
|-----------|--------|---------------|---------------|
| SPI Communication | ✅ Complete | ~90 | ⏳ Pending |
| MFRC522 Protocol | ✅ Complete | ~140 | ⏳ Pending |
| GPIO Control | ✅ Complete | ~50 | ⏳ Pending |
| Hardware Init | ✅ Complete | ~40 | ⏳ Pending |
| Card Detection | ✅ Complete | ~60 | ⏳ Pending |
| UID Reading | ✅ Complete | ~70 | ⏳ Pending |
| **Total** | **70% Complete** | **~450** | **0%** |

## 🚀 Next Immediate Steps

1. **Create Hardware Test Suite** (Task 3)
   - Implement basic GPIO/SPI tests
   - Test single RC522 module
   - Validate version register read

2. **On-Raspberry-Pi Testing** (Task 6)
   - Connect one RC522 module
   - Run hardware tests
   - Debug any hardware-specific issues
   - Gradually add remaining 6 modules

3. **UI Integration** (Task 4)
   - Can be done in parallel with hardware testing
   - Use mock adapter for development

## 📝 Notes

### Known Limitations
- Current implementation supports 4-byte UIDs only
- 7-byte and 10-byte UIDs not yet implemented (CASCADE levels)
- Anti-collision handles single card per module only

### Future Enhancements (Post-Migration)
- Multi-card detection per module
- Extended UID support (7/10 bytes)
- Performance optimization (parallel scanning)
- Power management (antenna on/off cycling)

### Hardware Requirements
- Raspberry Pi (any model with 40-pin GPIO)
- 7× RC522 RFID modules (13.56 MHz)
- Proper power supply (RC522 requires stable 3.3V)
- Wiring harness for shared SPI (incl. CE0) + one unique RST line per module

## 🔗 Related Documentation

- [RFID_ARCHITECTURE.md](RFID_ARCHITECTURE.md) - Architecture overview
- [RFID_MIGRATION_GUIDE.md](RFID_MIGRATION_GUIDE.md) - Migration plan
- [QUICK_REFERENCE.md](QUICK_REFERENCE.md) - Quick reference guide
- [IMPLEMENTATION_SUMMARY.md](IMPLEMENTATION_SUMMARY.md) - Phase 1 summary

---
**Last Updated**: Phase 2 Implementation Complete  
**Author**: GitHub Copilot  
**Status**: Ready for Hardware Testing
