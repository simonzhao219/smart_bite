# RFID System Quick Reference

## 🚀 Quick Start Commands

```bash
# Run with auto-detection (recommended)
flutter run

# Run with serial adapters (current Arduino setup)
RFID_MODE=serial flutter run

# Run with GPIO/SPI (Raspberry Pi)
RFID_MODE=gpio flutter run

# Run with mock data (development/testing)
RFID_MODE=mock flutter run
```

## 📝 Code Snippets

### Using the Provider

```dart
import 'package:smart_bite/provider/rfid_reader_provider.dart';

// In your widget
final provider = context.watch<RFIDReaderProvider>();

// Scan all readers
await provider.updateReaders();

// Get detected meals
List<String> meals = provider.orderNames;

// Check if scanning
if (provider.isScanning) {
  return CircularProgressIndicator();
}
```

### Creating a Reader Manager

```dart
import 'package:smart_bite/utils/platform_detector.dart';

// Auto-detect and create
final manager = RFIDReaderFactory.createReaderManager();

// Force specific platform
final mockManager = RFIDReaderFactory.createReaderManager(
  forcePlatform: PlatformType.mock,
);

// Custom GPIO configuration
final customManager = RFIDReaderFactory.createCustomGPIOReaderManager([
  RC522Config(deviceId: '01', spiNum: 0, rstPin: 22),
  // ... more configs
]);
```

### Testing with Mock Data

```dart
import 'package:smart_bite/adapters/mock_rfid_adapter.dart';

// Create mock manager with test scenario
final mock = MockRFIDReaderManager(scenario: 'full_meal');

// Use in provider
final provider = RFIDReaderProvider(readerManager: mock);

// All scans return predefined meals
await provider.updateReaders();
// Returns: [八寶良糧粥, 三杯鬼頭刀魚, 上海菜飯, ...]
```

### Meal Identification

```dart
import 'package:smart_bite/services/meal_identification_service.dart';

final service = MealIdentificationService();

// Single RFID lookup
String meal = service.identifyMeal('A22038F6'); // → "八寶良糧粥"

// Batch identification
List<String> meals = service.identifyMealsFromReadings(readings);

// Get statistics
Map<String, int> stats = service.getIdentificationStats(readings);
// Returns: {total: 7, valid: 5, identified: 4, unknown: 1}
```

## 🔧 Configuration

### Default GPIO Pins (Raspberry Pi)

Source of truth: `defaultReaderConfigs` in `lib/models/rfid_models.dart`.

| Module | Device ID | RST Pin |
|--------|-----------|---------|
| 1      | 01        | GPIO 22 |
| 2      | 02        | GPIO 27 |
| 3      | 03        | GPIO 17 |
| 4      | 04        | GPIO 4  |
| 5      | 05        | GPIO 23 |
| 6      | 06        | GPIO 24 |
| 7      | 07        | GPIO 25 |

**Shared SPI (`/dev/spidev0.0`):** MISO=GPIO9, MOSI=GPIO10, SCK=GPIO11, CE0=GPIO8 (SDA/SS of all 7 modules). Module selection is by RST; there is no per-module SS pin.

## 🧪 Testing

### Run with Mock Scenarios

```dart
// Test with full meal
RFID_MODE=mock flutter run

// In code, change scenario:
MockRFIDReaderManager(scenario: 'full_meal')  // All readers have cards
MockRFIDReaderManager(scenario: 'partial')    // Mix of cards and empty
MockRFIDReaderManager(scenario: 'errors')     // Some readers in error
MockRFIDReaderManager(scenario: 'empty')      // No readers
```

### Debug Output

Check console for:
```
[/dev/ttyUSB0][info] 01OKA22038F6
Detected results DeviceID="01", Status="OK", RFID="A22038F6"
Scan complete: 5 meals identified
Meals: [八寶良糧粥, 三杯鬼頭刀魚, 上海菜飯, 五目飯, 火龍果]
```

## 🐛 Troubleshooting

### No Serial Ports Found
```bash
ls /dev/tty*
sudo chmod 666 /dev/ttyUSB0
```

### GPIO Permission Denied
```bash
sudo usermod -a -G gpio $USER
# Log out and back in
```

### SPI Not Working
```bash
sudo raspi-config
# Interface Options → SPI → Enable
sudo reboot
```

### Platform Detection Wrong
```bash
# Check detection
cat /proc/cpuinfo | grep -i "raspberry\|bcm2"

# Force platform
RFID_MODE=gpio flutter run
```

## 📊 Status Indicators

### ReaderStatus Colors

- 🔵 **Updating** (Blue) - Scanning in progress
- 🟢 **OK** (Green) - Reader connected and working
- 🔴 **Error** (Red) - Reader error
- ⚫ **Init** (Grey) - Not yet connected
- 🟠 **Disconnected** (Orange) - Reader offline

### UI Elements

```dart
// Check all readers OK
if (provider.allReadersOk) {
  // Safe to proceed
}

// Check for errors
if (provider.hasErrors) {
  // Show error message
}

// Get statistics
final stats = provider.getReaderStatusSummary();
// {init: 0, updating: 2, ok: 5, error: 0, disconnected: 0}
```

## 🔍 Common Patterns

### Waiting for Scan Completion

```dart
// Button with loading state
ElevatedButton(
  onPressed: provider.isScanning ? null : () async {
    await provider.updateReaders();
  },
  child: provider.isScanning 
    ? CircularProgressIndicator()
    : Text('Scan'),
)
```

### Displaying Reader Status

```dart
ListView.builder(
  itemCount: provider.readers.length,
  itemBuilder: (context, index) {
    final reader = provider.readers[index];
    return ListTile(
      leading: Icon(Icons.sensors, color: reader.status.color),
      title: Text('Reader ${reader.deviceId}'),
      subtitle: Text(reader.status.displayName),
      trailing: Text(reader.address),
    );
  },
)
```

### Error Handling

```dart
try {
  await provider.updateReaders();
} catch (e) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Scan failed: $e')),
  );
}
```

## 📚 Files to Know

### Core Files
- `lib/interfaces/rfid_reader.dart` - Interface definitions
- `lib/provider/rfid_reader_provider.dart` - Main provider
- `lib/utils/platform_detector.dart` - Platform detection

### Adapters
- `lib/adapters/serial_rfid_adapter.dart` - Arduino + USB
- `lib/adapters/gpio_spi_rfid_adapter.dart` - Raspberry Pi (⚠️ WIP)
- `lib/adapters/mock_rfid_adapter.dart` - Testing

### Widgets
- `lib/widgets/refactored_order_page.dart` - Order display
- `lib/widgets/refactored_setting_page.dart` - Settings UI

### Documentation
- `RFID_MIGRATION_GUIDE.md` - Complete migration plan
- `RFID_ARCHITECTURE.md` - Architecture details
- `IMPLEMENTATION_SUMMARY.md` - What's been done

## ⚡ Performance Tips

### Serial Mode
- Default timeout: 10s
- All 7 readers scan in parallel

### GPIO Mode (when implemented)
- Target: 1-2s for all 7 modules
- Sequential scanning (shared SPI bus)
- Faster per-module scan compensates

### Mock Mode
- Instant (100ms delay)
- Perfect for UI development
- No hardware required

## 🎯 Migration Status

Current Phase: **Phase 1 Complete** ✅

| Phase | Status | Description |
|-------|--------|-------------|
| 1     | ✅     | Abstraction layer complete |
| 2     | 🔨     | GPIO implementation in progress |
| 3     | 📅     | UI integration pending |
| 4     | 📅     | Production deployment planned |

## 📞 Need Help?

1. Check the console for debug output
2. Review `RFID_MIGRATION_GUIDE.md`
3. Test with `RFID_MODE=mock` to isolate issues
4. Verify hardware connections and permissions

---

**Last Updated:** 2025-12-14  
**Version:** 1.0.0
