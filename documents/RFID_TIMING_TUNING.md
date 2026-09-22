# RFID 輪巡時序：機制、設定、校正與自動最佳化

這份文件說明 7 顆 Keyestudio RC522 輪巡的時間花在哪裡、為什麼線長會影響時間、
新版怎麼把等待值做成可調設定 (全域值加上每顆讀卡機的覆寫)、
以及如何用設定頁或 CLI 量出適合自己接線的值。

## 1. 舊版為什麼慢、為什麼線長會影響時間

舊版每顆讀卡機一次讀取的流程與固定等待：

| 步驟 | 每顆 | 7 顆合計 |
|---|---|---|
| RST 高、低、高三段各 50 ms | 150 ms | 1.05 s |
| init 後固定等待 | 500 ms | 3.5 s |
| REQA 無卡時晶片 timer 逾時 | 約 15 ms | 約 0.1 s |
| resetReader 固定等待 | 500 ms | 3.5 s |
| dispose 時再做一次 resetReader | 500 ms | 3.5 s |
| 結尾「穩定」等待 | | 0.5 s |
| 合計 | 約 1.2 s | 約 12 s |

超過 98% 的時間是程式裡寫死的 `Future.delayed`，真正的 SPI 通訊不到 0.2 秒。

線長影響時間的原因在 `communicate()`：舊版等 IRQ 的迴圈用「讀 2000 次 ComIrqReg」當上限。
線路正常時晶片 timer 約 15 ms 就會舉起 IRQ，迴圈只跑兩三百次；
線路差、MISO 讀回全 0 或指令沒寫進晶片時，IRQ 永遠不會出現，迴圈就跑滿 2000 次。
每次讀取都是一個 spidev ioctl，跑滿一次約 0.1 到 0.2 秒，每顆最多兩次，
整輪因此多出 1 到 3 秒，而且每次都不一樣。線路壞掉時結果只會變成「沒有卡」，
UI 分不出是沒放餐盤還是線有問題。

## 2. 新版的輪巡流程

一輪掃描 (`RfidScanSession.scanCycle` / `RFIDPollingService.performOneLoopCycles`)：

1. 打開 7 支 RST GPIO 並全部拉低，七顆全部進 hard power-down。
2. `/dev/spidev0.0` 只開一次 (舊版每顆重開一次)。
3. 依序對每顆做 `SimpleMFRC522.scanOnce()`，每顆用自己生效的時序 (`RfidTimingConfig.forReader`)：
   - RST 拉高，等 `rstSettleMs` 讓振盪器啟動。
   - 讀 VersionReg 做連線檢查。讀不到 0x91 / 0x92 之類的合理值，
     最多再等 `linkCheckTimeoutMs`，仍讀不到就回報 **線路異常**，不再送 REQA。
   - 設定暫存器、開天線，等 `antennaSettleMs` 讓卡片上電。
   - 送 REQA，最多 `reqaAttempts` 次；有卡就做 anticoll 取 UID。
   - 關天線、RST 拉低。進 power-down 是立即的，不需要等待。
4. 釋放 GPIO 與 SPI。

等 IRQ 的迴圈改用牆鐘時間當上限 (`commDeadlineMs`，至少 `reqaTimeoutMs + 10`)，
線路再差也不會把掃描拖長，而是回報「晶片無回應」。

每顆的結果分五類，會顯示在設定頁的讀卡機列表與訂單頁的提示：

| 狀態 | 意思 | 該做什麼 |
|---|---|---|
| 有卡片 | 讀到 UID | 正常 |
| 沒有卡片 | 晶片正常，場內沒卡 | 正常 |
| 線路異常 | VersionReg 讀不到合理值 | 檢查 RST、3.3V、GND、SPI 接線 |
| 晶片無回應 | VersionReg 讀得到，但送指令後沒有任何 IRQ | 降 SPI 時脈、檢查 SCK/MOSI |
| 錯誤 | GPIO 打不開、SPI 失敗等例外 | 看 log，必要時跑 `scripts/gpio_cleanup.sh` |

### 預設值與預期時間

預設值以 MFRC522 datasheet 與 Arduino MFRC522 library 的保守值為準：

| 欄位 | 預設 | 可對單顆覆寫 | 依據 |
|---|---|---|---|
| `spiSpeedHz` | 1000000 | 否 (整條 bus 共用) | 舊版相同 |
| `rstSettleMs` | 50 | 是 | datasheet 8.8.2 只要求晶振啟動時間 + 37.74 µs，Arduino library 取 50 ms |
| `linkCheckTimeoutMs` | 50 | 是 | 保險用，線路正常時不會用到 |
| `antennaSettleMs` | 5 | 是 | ISO 14443-3 要求卡片在場開啟後 5 ms 內就緒 |
| `reqaTimeoutMs` | 25 | 是 | Arduino library 的 timer 設定 |
| `reqaAttempts` | 2 | 是 | 卡片剛上電偶爾會漏掉第一次 REQA |
| `commDeadlineMs` | 36 | 是 | Arduino library 的牆鐘上限 |
| `interReaderGapMs` | 1 | 否 | 兩顆之間的間隔 |
| `postScanSettleMs` | 0 | 否 | 舊版為 500 |
| `scanTimeoutSec` | 10 | 否 | 整輪逾時，會自動至少是最壞情況的兩倍 |

每顆的時間：

| 情境 | 每顆約 |
|---|---|
| 有卡片 | `rstSettleMs + antennaSettleMs + 約 6 ms` (REQA 幾乎立刻有回應) |
| 沒有卡片 | `rstSettleMs + antennaSettleMs + reqaTimeoutMs × reqaAttempts + 約 5 ms` |

| 設定 | 七顆都有卡 | 七顆都沒卡 |
|---|---|---|
| 保守預設值 50 / 5 / 25 ms × 2 | 約 0.4 s | 約 0.8 s |
| 最佳化後例如 15 / 2 / 10 ms × 1 | 約 0.15 s | 約 0.2 s |

設定頁的卡片會顯示目前設定的估計值與上次實測值。

## 3. 設定檔、每顆覆寫與環境變數

設定檔是 JSON，路徑依序為：

1. 環境變數 `RFID_TIMING_FILE` 指定的路徑
2. app 的文件目錄，Raspberry Pi OS 上是 `~/Documents/rfid_timing.json`

範例 (`~/Documents/rfid_timing.json`)：

```json
{
  "spiSpeedHz": 500000,
  "rstSettleMs": 20,
  "antennaSettleMs": 5,
  "reqaTimeoutMs": 25,
  "reqaAttempts": 2,
  "readers": {
    "01": { "rstSettleMs": 15, "antennaSettleMs": 2, "reqaTimeoutMs": 10, "reqaAttempts": 1 },
    "07": { "rstSettleMs": 30, "antennaSettleMs": 10, "reqaTimeoutMs": 15, "reqaAttempts": 2 }
  }
}
```

- 頂層是全域值，只寫想改的欄位也可以，其餘沿用預設值。
- `readers` 區段對單顆讀卡機覆寫，key 是 deviceId (`"01"` 到 `"07"`)，
  只有上表標「可對單顆覆寫」的欄位有效，其他會被忽略。沒寫的欄位用全域值。
- 每個全域欄位也能用環境變數覆寫，名稱是 `RFID_` 加上大寫蛇形，例如：

```bash
RFID_SPI_SPEED_HZ=250000 RFID_RST_SETTLE_MS=30 flutter run
```

- 超出範圍的值 (含覆寫) 會被夾回邊界，範圍見 `RfidTimingConfig.ranges`。

app 在第一次掃描時載入設定。改了檔案之後，到設定頁按「重新載入設定檔」或重新啟動 app。

## 4. 設定頁

設定頁左欄的「輪巡時序設定」卡片顯示目前的 SPI 時脈、主要等待值、有幾顆有個別覆寫、
估計一輪時間 (全部沒卡 / 七顆都有卡)、上次實測耗時與設定來源，並有四個按鈕：

| 按鈕 | 做什麼 |
|---|---|
| 編輯設定 | 表單修改所有全域值 (有範圍檢查)，列出每顆的覆寫值並可清除，按「儲存」寫入設定檔並立即生效 |
| 連線檢測 | 不用放卡片。量每顆在 1 MHz / 500 kHz / 250 kHz 下的就緒時間與讀寫錯誤率，並建議 SPI 時脈與 RST 等待，可一鍵套用 |
| 自動最佳化 | 七顆都放卡片後執行第 5 節的演算法，顯示進度，結束後列出每顆的建議值與驗證結果，按「套用並儲存」寫入 |
| 重新載入設定檔 | 手動改過 JSON 之後重新讀取 |

掃描與校正互斥：校正進行中不能掃描，掃描中也不能開始校正。
所有硬體操作都在背景 isolate 執行，UI 不會卡住。

## 5. 自動最佳化演算法

目標：一輪掃描時間最短，且七顆讀卡機在驗證輪數內全部 100% 讀到卡片。
測試時七顆都要放上卡片，過程中不要移動卡片。

1. **連線階段 (不用卡)**：對每個候選 SPI 時脈 (預設 1 MHz、500 kHz、250 kHz)，
   量每顆的 VersionReg 就緒時間與 200 次寫入讀回的錯誤數。
   取「所有讀卡機都零錯誤」的最高時脈；都有錯誤就取錯誤最少的並提醒檢查走線。
   每顆的就緒時間決定它 `rstSettleMs` 候選值的下限 (就緒時間 × 2 + 5 ms，最低 10 ms)。
2. **確認階段**：用最保守的候選值跑 N 輪。讀不到卡的讀卡機標為「不穩定」，
   不參與後面的搜尋並維持原設定，通常是卡片沒放好或線路問題。
3. **掃描階段**：依序對 `rstSettleMs` (50 → 30 → 20 → 15 → 10)、
   `antennaSettleMs` (20 → 10 → 5 → 2 → 0)、`reqaTimeoutMs` (25 → 15 → 10 → 5)、
   `reqaAttempts` (2 → 1) 由大往小試。每顆讀卡機各自有自己的候選值與進度，
   但一輪掃描本來就會輪過七顆，所以七顆在同一輪裡各測各的候選值，
   每顆各自搜尋不需要七倍時間。每個候選值跑 N 輪，全中才往下一個更小的值走；
   取最小可過的值之後，時間類參數再往上加「安全餘裕」階數 (預設 1 階)。
4. **驗證階段**：用最終值跑 M 輪。任何一顆漏讀就把它的時間類參數各放寬一階、
   REQA 次數回到最多，然後重驗 (最多 2 次)；仍失敗的讀卡機退回原設定並標記。
5. **輸出**：SPI 時脈、每顆的覆寫值、每顆的驗證命中率、估計一輪時間 (前後對照) 與說明。
   「套用並儲存」會把 SPI 時脈與 `readers` 覆寫寫入設定檔，全域值不動。

預設 N = 5、M = 20，整個流程約 30 到 60 秒。輪數與餘裕都可以在對話框裡調。
「穩定」的判定是統計上的：N 輪全中只能排除很明顯的失敗，
所以要靠餘裕階數與較多的驗證輪數把邊緣值排除；卡片位置、溫度改變後可以重跑一次。

## 6. CLI

校正工具是 `scripts/rfid_calibrate.dart`，跟 app 共用同一套驅動、演算法與設定檔。
執行前先關閉 Smart Bite app，否則 GPIO 會顯示 busy。

```bash
cd ~/Desktop/smart_bite

# 看目前生效的設定與來源 (含每顆覆寫)
dart run scripts/rfid_calibrate.dart show

# 連線品質 (不需要放卡片)
dart run scripts/rfid_calibrate.dart link

# 只依連線品質推薦 spiSpeedHz 與 rstSettleMs，--write 寫入設定檔
dart run scripts/rfid_calibrate.dart recommend --write

# 自動最佳化 (七顆都放卡片)，--write 寫入 SPI 時脈與每顆覆寫
dart run scripts/rfid_calibrate.dart optimize --write
dart run scripts/rfid_calibrate.dart optimize --sweep-rounds 10 --verify-rounds 50 --margin 2

# 以目前設定跑 10 輪，看每輪耗時與每顆的成功率
dart run scripts/rfid_calibrate.dart bench --rounds 10 --verbose

# 手動掃描 RST / 天線等待值組合 (放卡片)
dart run scripts/rfid_calibrate.dart sweep --rst 5,10,20,50 --antenna 0,2,5,10 --rounds 5

# 直接改設定檔：全域值、單顆覆寫、清除覆寫
dart run scripts/rfid_calibrate.dart set rstSettleMs=20 antennaSettleMs=5
dart run scripts/rfid_calibrate.dart set 07.rstSettleMs=30 07.antennaSettleMs=10
dart run scripts/rfid_calibrate.dart set 07.clear
dart run scripts/rfid_calibrate.dart set clear
```

`link` 的輸出範例：

```
讀卡機    SPI Hz  就緒 ms VersionReg                錯誤/樣本 結果
01      1000000        2 0x92                            0/400 OK
07      1000000        3 0x92                           12/400 錯誤率 3.0%
07       500000        3 0x92                            0/400 OK
```

- 「就緒 ms」是 RST 拉高後 VersionReg 變成可讀的時間，`rstSettleMs` 只要比它大一些就夠。
- 「錯誤/樣本」是寫入再讀回不一致的次數。不是 0 就代表這個時脈下 SPI 不可靠，線最長的那顆通常最先出錯。

指令都可以加 `--readers 1,2,7` 只測某幾顆、`--file <path>` 指定設定檔、`--verbose` 看細節。

## 7. 長線的硬體建議

七顆模組共用 MISO、MOSI、SCK 與 CE0，被 RST 拉低的晶片輸出腳是「凍結」而不是高阻抗，
線越長、負載越重，1 MHz 的訊號邊緣越差。校正之外可以做的：

- 先降 SPI 時脈。每次傳輸只有 2 bytes，降到 500 kHz 或 250 kHz 對一輪時間幾乎沒有影響。
- SCK、MOSI、MISO 各自跟一條 GND 絞在一起或用排線相鄰配置，減少串音。
- 在 Pi 端的 SCK 與 MOSI 串一顆 22 到 100 Ω 電阻，抑制反射。
- 每顆模組的 3.3V 與 GND 就近加 100 nF 電容；供電線用粗一點的線，避免天線開啟時壓降。
- 不要把 SPI 線跟天線、電源線並排走太長。
- 若之後想更穩、更快，可以改成每顆用自己的 CS (SDA) 腳、RST 常態拉高：
  開機初始化一次，之後每輪只做 REQA 與 anticoll，一輪約 0.2 秒，
  而且 CS 拉高時 MISO 會真正進高阻抗。這需要多接 7 條線與軟體改動，目前的架構已預留
  `Mfrc522Transport` 與 `ResetLine` 抽象，可以在不動業務邏輯的情況下替換。

## 8. 疑難排解

| 現象 | 可能原因 | 處理 |
|---|---|---|
| 某顆一直「線路異常」，VersionReg=0x00 | MISO 沒接到、RST 沒拉高、模組沒電 | 量 RST 腳與 3.3V，換線 |
| VersionReg=0xFF | MISO 浮接或短路到高電位 | 檢查 MISO |
| 「晶片無回應」但 VersionReg 正常 | SCK / MOSI 訊號品質差，指令寫不進去 | 先降 SPI 時脈，再跑連線檢測 |
| 最佳化說某顆「最保守的設定下仍讀不到卡片」 | 卡片沒放好、卡片壞了或天線區被金屬蓋住 | 調整卡片位置後重跑 |
| 最佳化後偶爾漏讀 | 餘裕不夠或卡片位置跟校正時不同 | 用「安全餘裕 2 階」重跑，或手動把該顆的值調大 |
| 一輪時間忽長忽短 | 某顆在 timeout 邊緣 | `bench --verbose` 找出那顆，檢查接線 |
| `GPIOerrorCode.gpioErrorOpen` / busy | app 還在跑或上次沒正常結束 | 關 app，跑 `sudo ./scripts/gpio_cleanup.sh` |

## 9. 硬體暫時不能改時的軟體對策

線長造成的問題本質是 SPI 位元錯誤。接線與供電動不了時，軟體還有這幾個槓桿：

### 9.1 驅動層容錯 (預設已開啟)

| 欄位 | 預設 | 做什麼 |
|---|---|---|
| `writeVerifyRetries` | 2 | 關鍵暫存器 (timer、ASK、Mode、TxControl、ComIEn、Command、BitFraming、FIFO 內容數) 寫入後讀回驗證，不符就重寫，最多 2 次。偶發的位元錯誤因此只多花幾十微秒 |
| `anticollRetries` | 2 | UID 的 BCC 校驗失敗時 (卡片還在 READY) 直接重送 anticoll，之後才重做 REQA；第二次起改用 WUPA |
| `readerRetries` | 1 | 一顆回報線路異常、晶片無回應或 SPI 寫入錯誤時，RST 重新上電再讀一次 |

三個欄位都可以對單顆覆寫。線路正常時它們幾乎不花時間；線路差時每顆最多多
`readerRetries` 次完整讀取。設定頁的讀卡機列表與 CLI 的摘要會顯示
`重寫×N` (暫存器重寫次數) 與 `重讀×M` (重新上電次數)，這兩個數字就是每顆線路品質的即時指標：
長期看到某顆 `重寫` 不是 0，代表那條線在錯誤邊緣，該降時脈或提高驅動力。

新增的狀態「SPI 寫入錯誤」代表重寫之後暫存器仍讀回不符，線路錯誤率已經高到重試也救不了。

### 9.2 提高 Pi 的 GPIO 驅動力

Pi 4 的 GPIO 預設每腳 8 mA，長線加七顆負載會讓 SCK / MOSI 邊緣變慢。
`scripts/gpio_drive_strength.sh` 用 pigpio 把 GPIO 0 到 27 這一組 pad 調高，
這是不動接線時最接近「硬體修正」的手段：

```bash
sudo apt install pigpio                      # 只需一次
sudo ./scripts/gpio_drive_strength.sh show   # 看目前的值
sudo ./scripts/gpio_drive_strength.sh 12     # 先試 12 mA
sudo ./scripts/gpio_drive_strength.sh 16     # 不夠再試 16 mA
sudo ./scripts/gpio_drive_strength.sh 8      # 還原預設
```

每改一階就到設定頁按「連線檢測」比較各時脈的錯誤率。驅動力越大邊緣越快，
但振鈴也越明顯，所以要跟 SPI 時脈一起評估，不是越大越好。
設定在重開機前有效；要每次開機自動套用，建立一個 systemd 服務：

```ini
# /etc/systemd/system/gpio-drive-strength.service
[Unit]
Description=Raise GPIO pad drive strength for the RC522 SPI bus
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/home/pi/Desktop/smart_bite/scripts/gpio_drive_strength.sh 12

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now gpio-drive-strength.service
```

### 9.3 固定核心時脈

Pi 4 的 SPI 時脈由核心時脈分頻而來，核心時脈會隨負載在 200 與 500 MHz 之間切換。
在 `/boot/firmware/config.txt` (舊系統是 `/boot/config.txt`) 加上：

```
core_freq=500
core_freq_min=500
```

可以避免 SPI 時脈跟著漂移。風險低，代價是待機功耗略高。

### 9.4 期望與極限

- 重試機制能吃掉偶發錯誤 (錯誤率個位數 % 以下)，掃描時間幾乎不受影響。
- 錯誤率超過一成的線，重試會把時間拉長、偶爾仍會漏讀，那條線最終還是要縮短、
  改善走線或改成獨立 CS 接法。
- 判斷方法：連線檢測在 1 MHz 有錯、500 kHz 歸零是訊號問題，先降時脈；
  各時脈都零錯誤但掃描時常出現「晶片無回應」，是開天線後的供電或地抖動，
  需要就近供電與電容。

## 10. 相關檔案

| 檔案 | 內容 |
|---|---|
| `lib/services/rfid_timing_config.dart` | 時序設定、每顆覆寫、載入順序、範圍檢查、時間估算 |
| `lib/services/mfrc522.dart` | 暫存器層驅動，牆鐘上限的 `communicate()` |
| `lib/services/simple_mfrc522.dart` | 單顆讀取流程、連線檢查、校正用的 `probeLink()` |
| `lib/services/rfid_polling_service.dart` | 掃描 session 與一輪掃描 |
| `lib/services/rfid_calibration.dart` | 連線品質推薦邏輯與報表 |
| `lib/services/rfid_optimizer.dart` | 自動最佳化演算法、選項、進度與結果 |
| `lib/adapters/gpio_spi_rfid_adapter.dart` | Flutter 端：載入與儲存設定、在 isolate 執行掃描 / 連線檢測 / 最佳化 |
| `lib/widgets/rfid_timing_settings.dart` | 設定頁的卡片、編輯對話框、連線檢測、自動最佳化 UI |
| `scripts/rfid_calibrate.dart` | Pi 上的 CLI |
| `scripts/gpio_drive_strength.sh` | 調整 Pi GPIO pad 驅動力 (pigpio) |
| `test/unit/rfid_optimizer_test.dart` | 用模擬讀卡機驗證演算法 |
| `test/unit/mfrc522_driver_test.dart` | 用假 transport 驗證驅動與讀取流程 |
