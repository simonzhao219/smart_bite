# Smart Bite

- [懂吃!懂吃!餐點份新互動裝置2.0](https://1drv.ms/p/s!Ak6Co3gh5pvwhtBtcQ0-O4qCFJIktw?e=lNM737&nav=eyJzSWQiOjI3NywiY0lkIjozNTk4NjY2NDA4fQ)

## 🎯 Purpose

The application is a **nutritional analysis and meal planning tool** that:
- Calculates daily nutritional needs based on age groups
- Analyzes dish compositions and labels
- Generates printable nutrition reports
- Interfaces with RFID hardware via GPIO/SPI on Raspberry Pi

## 🏗️ Project Structure

### **Core Architecture**

```
lib/
├── main.dart                    # Entry point
├── adapters/                    # Hardware adapters
│   ├── gpio_spi_rfid_adapter.dart  # GPIO/SPI RFID reader (Raspberry Pi)
│   └── mock_rfid_adapter.dart      # Mock adapter for testing
├── data/                        # Data layer (constants & mappings)
│   ├── comments.dart            # Nutrition/meal comments
│   ├── constant.dart            # App constants
│   ├── dailyneeds_for_sixteen_above.dart   # Adult nutrition requirements
│   ├── dailyneeds_for_under_fifteen.dart   # Youth nutrition requirements
│   ├── dishes_info.dart         # Dish/meal information database
│   ├── dishes_label.dart        # Categorization/labels for dishes
│   ├── id_to_meal.dart          # Meal ID mapping
│   └── three_label_one_code.dart
├── interfaces/                  # Abstract interfaces
│   └── rfid_reader.dart         # RFID reader interface
├── models/                      # Data models
│   └── rfid_models.dart         # RFID data structures
├── provider/                    # State management (Provider pattern)
│   ├── data_provider.dart       # App data state
│   └── rfid_reader_provider.dart # RFID reader state management
├── screens/                     # UI layer
│   ├── input_screen.dart        # User input interface
│   ├── printing_preview.dart    # Print preview for reports
│   └── setting_screen.dart      # App configuration
├── services/                    # Business logic services
│   ├── meal_identification_service.dart  # Meal identification
│   ├── mfrc522_constants.dart            # MFRC522 register definitions
│   ├── mfrc522.dart                       # MFRC522 driver
│   ├── rfid_polling_service.dart         # RFID polling logic
│   └── simple_mfrc522.dart               # Simplified MFRC522 interface
├── utils/                       # Utilities
│   └── platform_detector.dart   # Platform detection
└── widgets/                     # Reusable widgets
    ├── refactored_order_page.dart
    └── refactored_setting_page.dart
```

### **Assets**

- **`assets/fonts`** - Custom font (NotoSansCJK) for CJK (Chinese/Japanese/Korean) character support
- **`assets/images`** - Image resources

## 🔧 Key Technologies

### **Dependencies**

| Package | Purpose |
|---------|---------|
| `provider` | State management (MVVM pattern) |
| `dart_periphery` | GPIO/SPI hardware communication on Linux |
| `window_manager` | Desktop window control |
| `pdf` | PDF generation for reports |
| `printing` | Print functionality |
| `screenshot` | Capture UI as images |
| `image_gallery_saver` | Save screenshots |
| `path_provider` | File system access |

### **Platform**

- **SDK**: Dart 3.5.1+
- **Target**: Raspberry Pi (Linux ARM) with GPIO/SPI support
- **UI Framework**: Flutter with Material Design

## 🎨 Design Patterns

### **1. Provider Pattern (State Management)**
```dart
provider/
├── data_provider.dart          # Business logic & app state
└── rfid_reader_provider.dart   # RFID hardware communication state
```

The app uses the **Provider** pattern for:
- Separating business logic from UI
- Reactive state updates
- Dependency injection

### **2. Separation of Concerns**

```
┌─────────────┐
│   Screens   │ ◄── UI Layer (user interaction)
└──────┬──────┘
       │
┌──────▼──────┐
│  Providers  │ ◄── Business Logic Layer
└──────┬──────┘
       │
┌──────▼──────┐
│ Adapters/   │ ◄── Hardware Abstraction Layer
│ Services    │
└──────┬──────┘
       │
┌──────▼──────┐
│    Data     │ ◄── Data Layer (constants, models)
└─────────────┘
```

### **3. Screen-Based Navigation**
- Separate screens for distinct user flows
- Loading states for async operations
- Preview before final output

## 🔍 Key Features

1. **Age-Based Nutrition Calculation**
   - Different daily needs for under 15 vs. 16+ age groups
   - Personalized nutritional recommendations

2. **Meal Analysis**
   - Dish database with nutritional information
   - Categorization and labeling system
   - ID-based meal lookup

3. **Hardware Integration**
   - 7 顆 RC522 經 GPIO/SPI 輪巡，時序可調、可校正 (見 `documents/RFID_TIMING_TUNING.md`)
   - Real-time data exchange

4. **Report Generation**
   - PDF export capability
   - Print preview functionality
   - Screenshot capture for sharing

5. **Desktop-First Design**
   - Window management
   - File system integration
   - Print dialog support

## 🎯 Typical User Flow

```
1. Input Screen → User enters age/dietary info
2. (Serial communication with device)
3. Loading Screen → Processing nutrition calculations
4. Printing Preview → Review generated report
5. Export/Print → Save as PDF or print physical copy
```

## 💡 Architecture Strengths

✅ **Clear separation** between data, business logic, and UI  
✅ **Scalable** state management with Provider  
✅ **Modular** screen-based structure  
✅ **Multi-platform** ready (desktop focus)  
✅ **Professional** report generation capabilities

## 🚀 Potential Use Cases

- **Educational tool** for nutrition learning
- **Clinical setting** for dietary planning
- **Restaurant/cafeteria** meal analysis system
- **School nutrition** program management
