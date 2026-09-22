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

## 🚀 Build、Release 與 RPi4 安裝

### CI 流程 (GitHub Actions)

| Workflow | 觸發 | 內容 |
|----------|------|------|
| `.github/workflows/ci.yml` | push 到 `main`、所有 PR | x64 上跑 `flutter analyze --no-fatal-infos` 與 `flutter test` |
| `.github/workflows/release.yml` | push tag `v*`，或手動 Run workflow | 在 GitHub 託管的 ARM64 runner (`ubuntu-24.04-arm`) 上、於 `debian:bookworm` 容器內 `flutter build linux --release` (linux-arm64)，打包成 `smart_bite-linux-arm64.tar.gz` 並建立 GitHub Release |

為什麼在 Debian 12 容器裡 build：Raspberry Pi OS Bookworm 的 glibc 是 2.36，直接在 Ubuntu 24.04 build 出的執行檔會要求更新的 glibc 而無法啟動。容器與 Pi 用同一版 Debian 就不會有這個問題；產物在更新的 Trixie 上也能執行。

### 發佈新版本

```bash
git tag v1.0.0            # tag 必須以 v 開頭
git push origin v1.0.0
```

約 10 到 15 分鐘後，GitHub Release 頁面會有：

- `smart_bite-linux-arm64.tar.gz`：RPi4 執行檔 bundle (內含 `VERSION` 檔)
- `smart_bite-linux-arm64.tar.gz.sha256`：校驗碼
- `install.sh`：安裝腳本

Tag 含 `-` (例如 `v1.1.0-rc1`) 會標成 pre-release，`latest` 不會指向它。只想試 build 不發佈：Actions → Release → Run workflow，產物會放在該次 workflow 的 Artifacts。

### 在 RPi4 安裝 (curl 一行)

需求：Raspberry Pi 4、Raspberry Pi OS **64-bit** Bookworm (Debian 12) 或更新版、桌面環境、SPI 已開啟 (`sudo raspi-config nonint do_spi 0` 後重開機)。

```bash
# 安裝最新版到 /opt/smart_bite，並建立 /usr/local/bin/smart_bite
curl -fsSL https://raw.githubusercontent.com/simonzhao219/smart_bite/main/scripts/install.sh | sudo bash

# 指定安裝位置與版本
curl -fsSL https://raw.githubusercontent.com/simonzhao219/smart_bite/main/scripts/install.sh \
  | sudo bash -s -- --dir /home/pi/smart_bite --version v1.0.0
```

腳本會依序：下載該 release 的 tar.gz 並驗證 sha256 → 解壓到安裝目錄 (舊版整個換掉；使用者資料放在 `~/Documents`，不受影響) → `apt-get install` 執行期需要的 GTK/EGL 函式庫 → 建立 `/usr/local/bin/smart_bite` → 檢查 SPI 與 `spi`/`gpio` 群組並提示。其他選項：`--no-deps`、`--no-launcher`、`--from-file 本機.tar.gz`、`--repo`、`-h`。

執行與更新：

```bash
smart_bite                    # 或 /opt/smart_bite/smart_bite，會全螢幕啟動
RFID_MODE=mock smart_bite     # 沒接 RC522 時改用 mock 讀卡機
RFID_ENABLED_READERS=1 smart_bite   # 只接了 1 號讀卡機時只掃它 (也可在設定頁勾選或寫進 rfid_timing.json)
# 更新：再跑一次同一行 curl 指令
```

### 本機 build 與版本鎖定

- Flutter 版本鎖在兩個 workflow 的 `FLUTTER_VERSION` (目前 3.47.5)，本機建議用同版本；升級時兩個檔案一起改。
- `pubspec.lock` 與 `linux/` runner 專案 (Flutter 3.47 範本) 都已納入版控，CI 用 `flutter pub get --enforce-lockfile` 確保和本機一致。
- 手動 build 與打包 (在 Pi 上或任何 Linux)：

  ```bash
  flutter build linux --release
  scripts/package_linux.sh arm64 1.0.0                          # x64 機器改用 x64
  sudo scripts/install.sh --from-file dist/smart_bite-linux-arm64.tar.gz
  ```

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
