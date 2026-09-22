# RFID 輪巡時序：機制、設定與校正

這份文件說明 7 顆 Keyestudio RC522 輪巡的時間花在哪裡、為什麼線長會影響時間、
新版怎麼把等待值做成可調設定，以及如何在 Raspberry Pi 上用校正工具量出適合自己接線的值。

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

一輪掃描 (`RFIDPollingService.performOneLoopCycles`)：

1. 打開 7 支 RST GPIO 並全部拉低，七顆全部進 hard power-down。
2. `/dev/spidev0.0` 只開一次 (舊版每顆重開一次)。
3. 依序對每顆做 `SimpleMFRC522.scanOnce()`：
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

| 欄位 | 預設 | 依據 |
|---|---|---|
| `spiSpeedHz` | 1000000 | 舊版相同 |
| `rstSettleMs` | 50 | datasheet 8.8.2 只要求晶振啟動時間 + 37.74 µs，Arduino library 取 50 ms |
| `linkCheckTimeoutMs` | 50 | 保險用，線路正常時不會用到 |
| `antennaSettleMs` | 5 | ISO 14443-3 要求卡片在場開啟後 5 ms 內就緒 |
| `reqaTimeoutMs` | 25 | Arduino library 的 timer 設定 |
| `reqaAttempts` | 2 | 卡片剛上電偶爾會漏掉第一次 REQA |
| `commDeadlineMs` | 36 | Arduino library 的牆鐘上限 |
| `interReaderGapMs` | 1 | 兩顆之間的間隔 |
| `postScanSettleMs` | 0 | 舊版為 500 |
| `scanTimeoutSec` | 10 | 整輪逾時，舊版為 30 |

無卡時每顆約 `rstSettleMs + antennaSettleMs + reqaTimeoutMs × reqaAttempts + 幾 ms`，
預設值下 7 顆一輪約 0.8 秒；有卡的讀卡機更快，因為 REQA 不用等到逾時。
校正後 `rstSettleMs` 通常可以降到 10 到 20 ms，一輪約 0.5 秒。

## 3. 設定檔與環境變數

設定檔是 JSON，路徑依序為：

1. 環境變數 `RFID_TIMING_FILE` 指定的路徑
2. app 的文件目錄，Raspberry Pi OS 上是 `~/Documents/rfid_timing.json`

範例 (`~/Documents/rfid_timing.json`)：

```json
{
  "spiSpeedHz": 500000,
  "rstSettleMs": 20,
  "linkCheckTimeoutMs": 50,
  "antennaSettleMs": 5,
  "reqaTimeoutMs": 25,
  "reqaAttempts": 2,
  "commDeadlineMs": 36,
  "interReaderGapMs": 1,
  "postScanSettleMs": 0,
  "scanTimeoutSec": 10
}
```

只寫想改的欄位也可以，其餘沿用預設值。每個欄位也能用環境變數覆寫，
名稱是 `RFID_` 加上大寫蛇形，例如：

```bash
RFID_SPI_SPEED_HZ=250000 RFID_RST_SETTLE_MS=30 flutter run
```

超出範圍的值會被夾回邊界 (範圍見 `RfidTimingConfig.ranges`)。

app 在第一次掃描時載入設定；改了檔案之後，到設定頁展開「輪巡時序設定」按
「重新載入設定檔」，或重新啟動 app。設定頁同時會顯示設定來源、每個值、
估計一輪時間、上次掃描耗時與每顆讀卡機的摘要 (版本、就緒時間、耗時)。

## 4. 在 Pi 上校正

校正工具是 `scripts/rfid_calibrate.dart`，跟 app 共用同一套驅動與設定檔。
執行前先關閉 Smart Bite app，否則 GPIO 會顯示 busy。

```bash
cd ~/Desktop/smart_bite

# 0. 看目前生效的設定與來源
dart run scripts/rfid_calibrate.dart show

# 1. 量每顆在 1 MHz / 500 kHz / 250 kHz 下的連線品質 (不需要放卡片)
dart run scripts/rfid_calibrate.dart link

# 2. 依量測結果推薦 spiSpeedHz 與 rstSettleMs，加 --write 直接寫入設定檔
dart run scripts/rfid_calibrate.dart recommend --write

# 3. 放好卡片，掃描不同的 RST / 天線等待值，看哪一組每顆都穩定讀到
dart run scripts/rfid_calibrate.dart sweep --rst 5,10,20,50 --antenna 0,2,5,10 --rounds 5

# 4. 把選好的值寫入
dart run scripts/rfid_calibrate.dart set rstSettleMs=20 antennaSettleMs=5

# 5. 用目前設定跑 10 輪，看每輪耗時與每顆的成功率
dart run scripts/rfid_calibrate.dart bench --rounds 10 --verbose
```

`link` 的輸出範例：

```
讀卡機    SPI Hz  就緒 ms VersionReg                錯誤/樣本 結果
01      1000000        2 0x92                            0/400 OK
07      1000000        3 0x92                           12/400 錯誤率 3.0%
07       500000        3 0x92                            0/400 OK
```

- 「就緒 ms」是 RST 拉高後 VersionReg 變成可讀的時間，`rstSettleMs` 只要比它大一些就夠。
  `recommend` 用「最大就緒時間 × 2 + 5 ms、最低 10 ms、不高於目前值」推薦。
- 「錯誤/樣本」是寫入再讀回不一致的次數。不是 0 就代表這個時脈下 SPI 不可靠，
  `recommend` 會選所有讀卡機都零錯誤的最高時脈。線最長的那顆通常最先出錯。

指令都可以加 `--readers 1,2,7` 只測某幾顆、`--file <path>` 指定設定檔、`--verbose` 看細節。

## 5. 長線的硬體建議

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

## 6. 疑難排解

| 現象 | 可能原因 | 處理 |
|---|---|---|
| 某顆一直「線路異常」，VersionReg=0x00 | MISO 沒接到、RST 沒拉高、模組沒電 | 量 RST 腳與 3.3V，換線 |
| VersionReg=0xFF | MISO 浮接或短路到高電位 | 檢查 MISO |
| 「晶片無回應」但 VersionReg 正常 | SCK / MOSI 訊號品質差，指令寫不進去 | 先 `set spiSpeedHz=500000`，再跑 `link` |
| 有卡但偶爾讀不到 | 天線等待不夠或卡片離天線太遠 | `sweep --antenna 5,10,20`，或 `set reqaAttempts=3` |
| 一輪時間忽長忽短 | 某顆在 timeout 邊緣 | `bench --verbose` 找出那顆，檢查接線 |
| `GPIOerrorCode.gpioErrorOpen` / busy | app 還在跑或上次沒正常結束 | 關 app，跑 `sudo ./scripts/gpio_cleanup.sh` |

## 7. 相關檔案

| 檔案 | 內容 |
|---|---|
| `lib/services/rfid_timing_config.dart` | 時序設定、載入順序、範圍檢查 |
| `lib/services/mfrc522.dart` | 暫存器層驅動，牆鐘上限的 `communicate()` |
| `lib/services/simple_mfrc522.dart` | 單顆讀取流程、連線檢查、校正用的 `probeLink()` |
| `lib/services/rfid_polling_service.dart` | 一輪掃描 |
| `lib/services/rfid_calibration.dart` | 校正推薦邏輯與報表 |
| `lib/adapters/gpio_spi_rfid_adapter.dart` | Flutter 端：載入設定、在 isolate 執行掃描、轉成 UI 狀態 |
| `scripts/rfid_calibrate.dart` | Pi 上的校正 CLI |
| `test/unit/mfrc522_driver_test.dart` | 用假 transport 驗證驅動與讀取流程 |
