# RFID Migration Guide: Serial to GPIO/SPI on Raspberry Pi

## 📋 Overview

This guide documents the migration from USB Serial-based RFID reading (7 Arduinos) to direct GPIO/SPI communication on Raspberry Pi. The migration follows an **abstraction-first** approach to minimize risk and enable incremental deployment.

## 🎯 Migration Strategy

### Why Abstraction First?

1. **Risk Mitigation**: Test business logic independently of hardware
2. **Parallel Development**: Teams can work on different layers simultaneously
3. **Gradual Migration**: Deploy incrementally with feature flags
4. **Backward Compatibility**: Keep serial support during transition
5. **Testability**: Mock implementations for automated testing

### Architecture Before & After

#### Before (Tightly Coupled)
```
[7x Arduino+RC522] → [USB Serial] → [SerialPortsProvider] → [Business Logic]
                      (flutter_libserialport)
```

#### After (Abstracted)
```
[Hardware Layer]
     ↓
[Adapter Layer] ←→ [RFIDReader Interface]
     ↓                      ↓
[RFIDReaderManager]  [Business Logic]
     ↓
[RFIDReaderProvider]
```

## 📦 New Components

### Core Abstractions

#### 1. **RFIDReader Interface** (`lib/interfaces/rfid_reader.dart`)

Defines hardware-agnostic contract for RFID readers:

```dart
abstract class RFIDReader {
  String get deviceId;
  ReaderStatus get status;
  String get address;
  Stream<RFIDReading> get readings;
  Future<void> connect();
  Future<void> disconnect();
  Future<RFIDReading> scan();
  bool get isConnected;
}
```

**Key Data Models:**
- `RFIDReading`: Immutable reading event with deviceId, status, rfid, timestamp
- `ReaderStatus`: Enum (init, updating, ok, error, disconnected)
- `RFIDReaderManager`: Coordinates multiple readers

---

### Adapter Implementations

#### 2. **SerialRFIDAdapter** (`lib/adapters/serial_rfid_adapter.dart`)

Wraps existing Arduino + USB Serial logic:

**Features:**
- Protocol parsing: `(\d{2})(OK)([0-9A-F]{8})?`
- Serial configuration: 9600 baud, 8N1
- Timeout handling: Configurable scan duration
- Error mapping: `SerialPortError` → `RFIDReading.error`

**Usage:**
```dart
final adapter = SerialRFIDAdapter(
  address: '/dev/ttyUSB0',
);
await adapter.connect();
final reading = await adapter.scan();
```

---

#### 3. **GPIOSPIRFIDAdapter** (`lib/adapters/gpio_spi_rfid_adapter.dart`)

Direct communication with RC522 modules on Raspberry Pi:

**Hardware Topology:**
- **Shared SPI Bus** (`/dev/spidev0.0`): MISO (GPIO 9), MOSI (GPIO 10), SCK (GPIO 11), CE0 (GPIO 8, wired to the SDA/SS of all 7 modules)
- **Unique per module**: RST pin only. Module selection is by RST (one high at a time); there is no per-module SS pin.

**Default Pin Configuration (7 modules, `defaultReaderConfigs` in `lib/models/rfid_models.dart`):**
```dart
Module 1: RST=GPIO22
Module 2: RST=GPIO27
Module 3: RST=GPIO17
Module 4: RST=GPIO4
Module 5: RST=GPIO23
Module 6: RST=GPIO24
Module 7: RST=GPIO25
```

**Protocol:** MFRC522 (ISO14443A, 13.56 MHz)

**Current Status:** ⚠️ **SKELETON IMPLEMENTATION**
- GPIO control via sysfs (`/sys/class/gpio/`)
- SPI communication placeholders (requires `dart_periphery` or native extension)
- MFRC522 register definitions complete
- TODO: Implement full PICC anti-collision protocol

---

#### 4. **MockRFIDAdapter** (`lib/adapters/mock_rfid_adapter.dart`)

Testing implementation with predefined scenarios:

**Scenarios:**
- `full_meal`: 7 readers with valid RFIDs
- `partial`: Mix of cards and empty readers
- `errors`: Some readers in error state
- `empty`: No readers

**Usage:**
```dart
final manager = MockRFIDReaderManager(scenario: 'full_meal');
await manager.scanAll(); // Returns mock readings
```

---

### Business Logic Layer

#### 5. **MealIdentificationService** (`lib/services/meal_identification_service.dart`)

Extracted from UI, handles RFID → Meal conversion:

```dart
final service = MealIdentificationService();
final mealName = service.identifyMeal('A22038F6'); // → "八寶良糧粥"
final stats = service.getIdentificationStats(readings);
```

**Features:**
- Lookup from `id_to_meal.dart` (623 entries)
- Unknown meal handling: Returns "未知料理"
- Batch identification from `List<RFIDReading>`
- Statistics: total, valid, identified, unknown counts

---

#### 6. **RFIDReaderProvider** (`lib/provider/rfid_reader_provider.dart`)

Replaces `SerialPortsProvider` with abstraction:

```dart
final provider = RFIDReaderProvider(
  readerManager: SerialRFIDReaderManager(), // or GPIO, or Mock
);

await provider.updateReaders(); // Scan all, identify meals
List<String> meals = provider.orderNames; // Meal names
```

**Compatibility:**
- Same `orderNames` interface as legacy provider
- Integrates `MealIdentificationService`
- Provides reader statistics and status summaries

---

### Platform Detection

#### 7. **PlatformDetector** (`lib/utils/platform_detector.dart`)

Auto-detects platform and creates appropriate adapter:

```dart
// Auto-detect
final manager = RFIDReaderFactory.createReaderManager();

// Force platform
final gpioManager = RFIDReaderFactory.createReaderManager(
  forcePlatform: PlatformType.raspberryPi,
);
```

**Detection Logic:**
- Checks `/proc/cpuinfo` for "Raspberry Pi" or "BCM2xxx"
- Falls back to serial for Windows/macOS/Linux x86
- Supports environment variable override: `RFID_MODE=gpio|serial|mock`

---

## 🚀 Migration Phases

### Phase 1: Abstraction (✅ COMPLETE)

**Goal:** Create interfaces without breaking existing functionality

**Deliverables:**
- [x] `RFIDReader` interface and data models
- [x] `SerialRFIDAdapter` wrapping existing logic
- [x] `MealIdentificationService` extracted from UI
- [x] `MockRFIDAdapter` for testing
- [x] Unit tests for protocol parsing

**Verification:**
```dart
// Test with mock data
final manager = MockRFIDReaderManager(scenario: 'full_meal');
await manager.scanAll();
assert(manager.validReadings.length == 7);
```

**Status:** All core abstractions implemented and ready for testing.

---

### Phase 2: GPIO Implementation (🔨 IN PROGRESS)

**Goal:** Implement Raspberry Pi GPIO/SPI driver

**Current State:**
- ✅ GPIO pin control structure (sysfs)
- ✅ MFRC522 register definitions
- ✅ RC522 configuration management
- ⚠️ **TODO:** SPI communication (requires native library)
- ⚠️ **TODO:** MFRC522 protocol (anti-collision, UID reading)

**Next Steps:**

1. **Add SPI Library Dependency**
   ```yaml
   # pubspec.yaml
   dependencies:
     dart_periphery: ^0.9.0  # Or alternative SPI library
   ```

2. **Implement SPI Communication**
   ```dart
   Future<void> _spiWrite(int register, int value) async {
     final spi = SPI('/dev/spidev0.0', 0, 1000000);
     final txBuf = Uint8List.fromList([(register << 1) & 0x7E, value]);
     spi.transfer(txBuf);
     spi.dispose();
   }
   ```

3. **Implement MFRC522 Protocol**
   - PICC_REQA: Request card presence
   - Anti-collision loop: Read UID cascade levels
   - BCC verification: Check UID integrity

**Hardware Testing Plan:**
1. Test single module on SPI0.0
2. Verify RST pin reset functionality
3. Test shared bus with 2 modules (unique SS pins)
4. Scale to all 7 modules
5. Benchmark scan latency (target: <2s for all 7)

---

### Phase 3: Integration (🔜 NEXT)

**Goal:** Wire new abstractions into existing UI

**Tasks:**

1. **Update InputScreen to use RFIDReaderProvider**
   
   **File:** `lib/screens/input_screen.dart`
   
   **Replace:**
   ```dart
   // OLD
   context.select<SerialPortsProvider, List<OrderCard>>((provider) {
     // Manual RFID → Meal conversion in UI
   });
   ```
   
   **With:**
   ```dart
   // NEW
   final orderNames = context.select<RFIDReaderProvider, List<String>>(
     (provider) => provider.orderNames,
   );
   ```
   
   **Or use:** `RefactoredOrderPage` from `lib/widgets/refactored_order_page.dart`

2. **Update Settings Screen**
   
   **Replace:** `SettingPage` → `RefactoredSettingPage`
   
   **Features:**
   - Platform detection display
   - Reader statistics (total, OK, errors, cards)
   - Platform-specific config (serial ports vs GPIO pins)

3. **Update main.dart Providers**
   
   Already updated to include:
   ```dart
   ChangeNotifierProvider(
     create: (context) => RFIDReaderProvider(
       readerManager: RFIDReaderFactory.createReaderManager(),
     ),
   )
   ```

**Feature Flag Strategy:**
```dart
// Environment variable to control migration
final useNewProvider = Platform.environment['USE_NEW_RFID'] == 'true';

providers: [
  if (useNewProvider)
    ChangeNotifierProvider(create: (_) => RFIDReaderProvider(...))
  else
    ChangeNotifierProvider(create: (_) => SerialPortsProvider()),
  // ...
]
```

**Verification:**
- [ ] Test on desktop with serial adapters
- [ ] Test on Raspberry Pi with GPIO adapters
- [ ] Test UI responsiveness during scanning
- [ ] Verify meal identification accuracy
- [ ] Check error handling and recovery

---

### Phase 4: Cleanup (📅 PLANNED)

**Goal:** Remove legacy code and dependencies

**Tasks:**

1. **Remove Serial-Specific Code**
   - Delete `lib/provider/serial_provider.dart` (or mark deprecated)
   - Remove `flutter_libserialport` dependency
   - Remove serial timeout slider (if GPIO is faster)

2. **Code Review & Cleanup**
   - Remove commented-out code
   - Update documentation
   - Add inline comments for complex GPIO logic

3. **Final Testing**
   - Integration tests with physical hardware
   - Performance benchmarking (7 modules scan time)
   - Error recovery testing (unplug module during scan)

---

## 🧪 Testing Strategy

### Unit Tests

**File:** `test/rfid_reader_test.dart` (to be created)

```dart
void main() {
  group('MockRFIDAdapter', () {
    test('should return configured RFID', () async {
      final adapter = MockRFIDAdapter(
        deviceId: '01',
        mockRfidSequence: ['A22038F6'],
      );
      final reading = await adapter.scan();
      expect(reading.rfid, 'A22038F6');
      expect(reading.deviceId, '01');
    });
  });

  group('MealIdentificationService', () {
    test('should identify known meal', () {
      final service = MealIdentificationService();
      final meal = service.identifyMeal('A22038F6');
      expect(meal, '八寶良糧粥');
    });

    test('should return unknown for invalid RFID', () {
      final service = MealIdentificationService();
      final meal = service.identifyMeal('INVALID');
      expect(meal, '未知料理');
    });
  });
}
```

### Integration Tests

**Loopback Test (GPIO without RC522):**
```dart
// Test GPIO control without actual RFID modules
final config = RC522Config(
  deviceId: '01',
  spiNum: 0, // /dev/spidev0.0
  rstPin: 22,
);
final adapter = GPIOSPIRFIDAdapter(config: config);
await adapter.connect(); // Should configure GPIO pins
// Verify GPIO state via sysfs
```

**End-to-End Test (with hardware):**
```dart
final manager = GPIOSPIRFIDReaderManager();
await manager.discoverReaders();
final readings = await manager.scanAll();
expect(readings.length, 7); // All modules scanned
expect(readings.where((r) => r.hasCard).isNotEmpty, true);
```

---

## 🐛 Known Issues & Limitations

### GPIO/SPI Adapter (Current)

1. **SPI Communication Not Implemented**
   - Placeholders in `_spiWrite()` and `_spiRead()`
   - **Action:** Add `dart_periphery` or create native extension

2. **MFRC522 Protocol Incomplete**
   - Missing anti-collision implementation
   - No UID reading logic
   - **Action:** Port Arduino `MFRC522` library logic to Dart

3. **Sequential Scanning Only**
   - Shared SPI bus requires sequential module polling
   - **Impact:** 7 modules × 100ms = 700ms minimum scan time
   - **Mitigation:** Optimize per-module scan to 50-100ms

4. **No Hardware Error Recovery**
   - Missing handling for:
     - Module disconnection during operation
     - SPI communication failures
     - Card authentication errors

### Serial Adapter

1. **Timeout Hardcoded**
   - Uses `currentLoadingTime` global variable
   - Should use instance variable

2. **No Connection Pooling**
   - Opens/closes port on every scan
   - **Impact:** Slower scanning on Windows

---

## 🔧 Configuration

### Environment Variables

Control RFID reader selection:

```bash
# Force serial mode (for testing on Raspberry Pi)
export RFID_MODE=serial
flutter run

# Force GPIO mode (for testing on desktop)
export RFID_MODE=gpio
flutter run

# Use mock for development
export RFID_MODE=mock
flutter run
```

### Custom GPIO Configuration

Override default pin assignments:

```dart
final customConfigs = [
  RC522Config(deviceId: '01', spiNum: 0, rstPin: 5),
  RC522Config(deviceId: '02', spiNum: 0, rstPin: 13),
  // ... 5 more
];

final manager = GPIOSPIRFIDReaderManager(configs: customConfigs);
```

---

## 📊 Performance Considerations

### Serial (Current)

- **Scan Time:** 10s default (configurable 3-20s)
- **Latency:** USB Serial + Arduino processing
- **Throughput:** All 7 modules scanned in parallel

### GPIO/SPI (Target)

- **Scan Time:** 1-2s total for 7 modules
- **Latency:** Direct SPI communication (~1ms per transaction)
- **Throughput:** Sequential (shared bus) but much faster per module

### Optimization Tips

1. **Reduce Timeout:** Lower scan timeout to 1-2s for GPIO
2. **Antenna Optimization:** Ensure proper RC522 antenna gain configuration
3. **Batch Processing:** Group SPI transactions to reduce overhead

---

## 🔒 Security Considerations

### GPIO Access

Raspberry Pi GPIO requires appropriate permissions:

```bash
# Add user to gpio group
sudo usermod -a -G gpio $USER

# Or run with elevated privileges (not recommended for production)
sudo flutter run
```

### SPI Device Permissions

```bash
# Enable SPI interface
sudo raspi-config
# Interface Options → SPI → Enable

# Verify device exists
ls -l /dev/spidev0.*
```

---

## 📚 References

### Hardware Documentation

- [Keyestudio RC522 Sensor](https://wiki.keyestudio.com/Ks0205_Keyestudio_RC522_Sensor)
- [MFRC522 Datasheet](https://www.nxp.com/docs/en/data-sheet/MFRC522.pdf)
- [ISO14443A Protocol](https://www.nxp.com/docs/en/application-note/AN10833.pdf)

### Software Libraries

- [dart_periphery](https://pub.dev/packages/dart_periphery) - SPI/GPIO for Dart
- [flutter_libserialport](https://pub.dev/packages/flutter_libserialport) - Current serial library
- [Arduino MFRC522](https://github.com/miguelbalboa/rfid) - Reference implementation

### Flutter Documentation

- [Provider State Management](https://pub.dev/packages/provider)
- [Platform Detection](https://api.flutter.dev/flutter/dart-io/Platform-class.html)

---

## ❓ FAQ

**Q: Can I use both serial and GPIO readers simultaneously?**

A: Yes! Create a composite manager:
```dart
final serialManager = SerialRFIDReaderManager();
final gpioManager = GPIOSPIRFIDReaderManager();
// Combine readers in custom manager
```

**Q: What if my Raspberry Pi has different GPIO pins?**

A: Pass custom `RC522Config` to `GPIOSPIRFIDReaderManager`.

**Q: How do I test GPIO code without Raspberry Pi?**

A: Use `MockRFIDAdapter` or force mock mode:
```dart
final manager = RFIDReaderFactory.createReaderManager(
  forcePlatform: PlatformType.mock,
);
```

**Q: Will this work on Raspberry Pi 5?**

A: Yes, but verify GPIO pin numbers (BCM2712 vs BCM2711).

**Q: Can I use I2C instead of SPI?**

A: RC522 supports both, but SPI is faster. Modify `GPIOSPIRFIDAdapter` for I2C.

---

## 📞 Support

For issues or questions:
1. Check `get_errors` tool output
2. Review debug logs: `debugPrint` statements throughout adapters
3. Test with `MockRFIDAdapter` to isolate hardware issues
4. Verify GPIO permissions and SPI device access

---

## ✅ Migration Checklist

- [x] Phase 1: Abstraction layer complete
- [x] Phase 1: Service layer extracted
- [x] Phase 1: Mock adapter for testing
- [ ] Phase 2: SPI library integrated
- [ ] Phase 2: MFRC522 protocol implemented
- [ ] Phase 2: Hardware tested (1 module)
- [ ] Phase 2: Hardware tested (7 modules)
- [ ] Phase 3: UI updated to use new provider
- [ ] Phase 3: Settings screen refactored
- [ ] Phase 3: End-to-end testing
- [ ] Phase 4: Legacy code removed
- [ ] Phase 4: Documentation complete
- [ ] Phase 4: Production deployment

---

**Last Updated:** 2025-12-14  
**Version:** 1.0.0  
**Status:** Phase 1 Complete, Phase 2 In Progress
