# RFID Reader Abstraction Layer

## Quick Start

### Running with Different Adapters

```bash
# Auto-detect platform (Raspberry Pi → GPIO, Desktop → Serial)
flutter run

# Force serial mode
RFID_MODE=serial flutter run

# Force GPIO mode (requires Raspberry Pi hardware)
RFID_MODE=gpio flutter run

# Use mock for development/testing
RFID_MODE=mock flutter run
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                   Application Layer                      │
│  (InputScreen, SettingScreen, DataProvider)             │
└────────────────────┬────────────────────────────────────┘
                     │
┌────────────────────▼────────────────────────────────────┐
│              RFIDReaderProvider                          │
│  • Manages RFID readers                                  │
│  • Identifies meals from RFID cards                      │
│  • Provides orderNames to business logic                 │
└────────────┬───────────────────┬────────────────────────┘
             │                   │
┌────────────▼──────┐   ┌────────▼─────────────────┐
│ RFIDReaderManager │   │ MealIdentificationService│
│ (interface)       │   │ • RFID → Meal lookup     │
└────────┬──────────┘   │ • Statistics             │
         │              └──────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────┐
│              Adapter Implementations                   │
│                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │   Serial     │  │  GPIO/SPI    │  │   Mock     │ │
│  │   Adapter    │  │   Adapter    │  │  Adapter   │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
└─────────┼──────────────────┼─────────────────┼────────┘
          │                  │                 │
┌─────────▼──────┐  ┌────────▼────────┐  ┌────▼──────┐
│ 7x Arduino     │  │ Raspberry Pi    │  │ Simulated │
│ + RC522        │  │ GPIO/SPI        │  │ Data      │
│ (USB Serial)   │  │ 7x RC522 Direct │  │           │
└────────────────┘  └─────────────────┘  └───────────┘
```

## Key Components

### Interfaces (`lib/interfaces/`)

**`rfid_reader.dart`**
- `RFIDReader`: Abstract interface for RFID readers
- `RFIDReading`: Immutable data class for reading events
- `ReaderStatus`: Enum for reader states
- `RFIDReaderManager`: Coordinates multiple readers

### Adapters (`lib/adapters/`)

**`serial_rfid_adapter.dart`**
- Wraps existing Arduino + USB Serial implementation
- Compatible with current hardware setup
- Protocol: `(\d{2})(OK)([0-9A-F]{8})?`

**`gpio_spi_rfid_adapter.dart`** ⚠️ In Progress
- Direct Raspberry Pi GPIO/SPI communication
- Supports 7 RC522 modules on shared SPI bus
- MFRC522 protocol implementation

**`mock_rfid_adapter.dart`**
- Testing and development mock
- Predefined scenarios: `full_meal`, `partial`, `errors`, `empty`

### Services (`lib/services/`)

**`meal_identification_service.dart`**
- Converts RFID UIDs to meal names
- Uses `id_to_meal.dart` database (623 entries)
- Provides statistics and validation

### Providers (`lib/provider/`)

**`rfid_reader_provider.dart`**
- Replaces `SerialPortsProvider` with abstraction
- Hardware-agnostic RFID reading
- Integrates meal identification
- Compatible interface with legacy code

### Utils (`lib/utils/`)

**`platform_detector.dart`**
- Auto-detects platform (Raspberry Pi, Desktop, etc.)
- Factory for creating appropriate RFID reader
- Environment variable override support

## Code Examples

### Basic Usage

```dart
import 'package:smart_bite/utils/platform_detector.dart';
import 'package:smart_bite/provider/rfid_reader_provider.dart';

// Create reader manager for current platform
final readerManager = RFIDReaderFactory.createReaderManager();

// Create provider
final provider = RFIDReaderProvider(readerManager: readerManager);

// Scan all readers and identify meals
await provider.updateReaders();

// Get identified meals
List<String> meals = provider.orderNames;
debugPrint('Detected meals: $meals');
```

### Mock Testing

```dart
import 'package:smart_bite/adapters/mock_rfid_adapter.dart';

// Create mock manager with test data
final mockManager = MockRFIDReaderManager(scenario: 'full_meal');

// Use in provider
final provider = RFIDReaderProvider(readerManager: mockManager);

// All scans return predefined test data
await provider.updateReaders();
assert(provider.orderNames.length == 7);
```

### Custom GPIO Configuration

```dart
import 'package:smart_bite/adapters/gpio_spi_rfid_adapter.dart';

final customConfigs = [
  RC522Config(
    deviceId: '01',
    spiDevice: '/dev/spidev0.0',
    rstPin: 17,
    ssPin: 8,
  ),
  // ... configure 6 more modules
];

final gpioManager = GPIOSPIRFIDReaderManager(configs: customConfigs);
```

## Widget Integration

### Using Refactored Widgets

```dart
import 'package:smart_bite/widgets/refactored_order_page.dart';
import 'package:smart_bite/widgets/refactored_setting_page.dart';

// In your app
class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: RefactoredOrderPage(
        onGoBack: () { /* ... */ },
        onSubmit: () { /* ... */ },
      ),
    );
  }
}
```

### Migration from Legacy

Replace:
```dart
// OLD
context.read<SerialPortsProvider>().updatePorts();
final meals = context.read<SerialPortsProvider>().orderNames;
```

With:
```dart
// NEW
context.read<RFIDReaderProvider>().updateReaders();
final meals = context.read<RFIDReaderProvider>().orderNames;
```

## Testing

### Unit Tests

```dart
test('Mock adapter returns configured RFID', () async {
  final adapter = MockRFIDAdapter(
    deviceId: '01',
    mockRfidSequence: ['A22038F6'],
  );
  
  final reading = await adapter.scan();
  
  expect(reading.rfid, 'A22038F6');
  expect(reading.status, ReaderStatus.ok);
});
```

### Integration Tests

```dart
testWidgets('Order page displays detected meals', (tester) async {
  final mockManager = MockRFIDReaderManager(scenario: 'full_meal');
  final provider = RFIDReaderProvider(readerManager: mockManager);
  
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: provider,
      child: RefactoredOrderPage(...),
    ),
  );
  
  await provider.updateReaders();
  await tester.pump();
  
  expect(find.text('八寶良糧粥'), findsOneWidget);
});
```

## Hardware Setup

### Raspberry Pi GPIO Pins

Default configuration for 7 RC522 modules:

| Module | Device ID | RST Pin | SS Pin |
|--------|-----------|---------|--------|
| 1      | 01        | GPIO 17 | GPIO 8 |
| 2      | 02        | GPIO 27 | GPIO 7 |
| 3      | 03        | GPIO 22 | GPIO 25|
| 4      | 04        | GPIO 23 | GPIO 24|
| 5      | 05        | GPIO 18 | GPIO 12|
| 6      | 06        | GPIO 15 | GPIO 16|
| 7      | 07        | GPIO 14 | GPIO 20|

**Shared SPI Pins:**
- MISO: GPIO 9
- MOSI: GPIO 10
- SCK: GPIO 11

### Enable SPI

```bash
sudo raspi-config
# Navigate to: Interface Options → SPI → Enable
sudo reboot
```

### Permissions

```bash
# Add user to gpio and spi groups
sudo usermod -a -G gpio,spi $USER
```

## Troubleshooting

### Serial Port Not Found

```bash
# List available serial ports
ls /dev/tty*

# Check permissions
sudo chmod 666 /dev/ttyUSB0
```

### GPIO Permission Denied

```bash
# Check group membership
groups

# Should include 'gpio' - if not:
sudo usermod -a -G gpio $USER
# Log out and back in
```

### SPI Device Not Found

```bash
# Verify SPI is enabled
ls -l /dev/spidev*

# Should show: /dev/spidev0.0 and /dev/spidev0.1
```

### Platform Auto-detection Fails

```bash
# Check CPU info
cat /proc/cpuinfo | grep -i "raspberry\|bcm2"

# Force platform manually
RFID_MODE=gpio flutter run
```

## Performance

### Expected Scan Times

- **GPIO/SPI**: 約 0.8s for 7 modules with the conservative defaults (no card on any reader);
  約 0.5s after calibration. The old implementation took 約 12s because of hard-coded
  500 ms sleeps, and the time grew with cable length because the IRQ wait loop was
  bounded by a read count instead of wall-clock time.
- **Mock**: ~100ms (configurable delay)

### Timing Configuration and Calibration

All RC522 timing values (RST settle, antenna settle, REQA timeout/attempts, SPI clock,
deadlines) live in `RfidTimingConfig` and can be overridden without recompiling via
`~/Documents/rfid_timing.json` or `RFID_*` environment variables.
`scripts/rfid_calibrate.dart` measures each reader's link quality at several SPI clocks
and recommends values. See [RFID_TIMING_TUNING.md](RFID_TIMING_TUNING.md).

### Optimization Tips

1. Run `dart run scripts/rfid_calibrate.dart recommend --write` on the Pi after wiring changes
2. Lower `spiSpeedHz` (500 kHz / 250 kHz) for long cables; each transfer is only 2 bytes
3. Keep a GND wire next to SCK/MOSI/MISO and decouple each module's 3.3V
4. Minimize electrical noise near RFID modules

## API Reference

### RFIDReading

```dart
class RFIDReading {
  final String deviceId;      // "01" to "07"
  final ReaderStatus status;  // ok, error, updating, etc.
  final String rfid;          // "A22038F6" (8-char hex)
  final DateTime timestamp;
  final String? errorMessage;
  final String? rawData;
  
  bool get hasCard;           // true if valid RFID detected
}
```

### RFIDReaderProvider

```dart
class RFIDReaderProvider {
  List<RFIDReader> get readers;
  List<String> get orderNames;
  bool get isScanning;
  int get readerCount;
  int get validCardCount;
  
  Future<void> discoverReaders();
  Future<void> updateReaders();
  Map<String, int> getStats();
  Map<String, int> getReaderStatusSummary();
}
```

## Migration Status

- ✅ **Phase 1**: Abstraction layer complete
- 🔨 **Phase 2**: GPIO implementation in progress
- 📅 **Phase 3**: UI integration pending
- 📅 **Phase 4**: Cleanup and production deployment

See [RFID_MIGRATION_GUIDE.md](RFID_MIGRATION_GUIDE.md) for detailed migration plan.

## Contributing

When adding new RFID reader implementations:

1. Implement `RFIDReader` interface
2. Create corresponding `RFIDReaderManager`
3. Add to `RFIDReaderFactory.createReaderManager()`
4. Add tests in `test/rfid_reader_test.dart`
5. Update documentation

## License

See main project LICENSE file.
