#!/bin/bash
################################################################################
# Raspberry Pi GPIO 驅動力 (pad drive strength) 調整
#
# 七顆 RC522 共用 SPI bus，長線加七顆負載會讓 SCK / MOSI 的邊緣變慢。
# Pi 的 GPIO 預設每腳 8 mA，這個腳本把 GPIO 0 到 27 這一組 pad 調高，
# 讓邊緣變快。SPI0 的 MOSI(10)、SCK(11) 與所有 RST 腳都在這一組；
# MISO(9) 是 RC522 在驅動，Pi 的 pad 強度管不到它。
#
# 用法:
#   sudo ./scripts/gpio_drive_strength.sh            # 只顯示目前的值 (預設動作)
#   sudo ./scripts/gpio_drive_strength.sh 12         # 設成 12 mA (建議先試這個)
#   sudo ./scripts/gpio_drive_strength.sh 16         # 設成 16 mA (最大)
#   sudo ./scripts/gpio_drive_strength.sh 8          # 還原預設
#
# 需要 pigpio (sudo apt install pigpio)。腳本會暫時啟動 pigpiod 來寫 pad 暫存器，
# 寫完就關掉，不會跟 app 使用的 gpiochip / spidev 衝突。設定在重開機前都有效；
# 要每次開機自動套用，見 documents/RFID_TIMING_TUNING.md。
#
# 注意: 驅動力越大，邊緣越快但振鈴也越明顯。請配合 app 的「連線檢測」看錯誤率，
# 一階一階試 (8 → 12 → 16)，並搭配較低的 SPI 時脈一起評估。
################################################################################

set -euo pipefail

PAD=0            # pad 0 = GPIO 0-27
DEFAULT_MA=8
TARGET="${1:-show}"

if [ "$EUID" -ne 0 ]; then
    echo "❌ 請用 sudo 執行: sudo $0 [mA|show]"
    exit 1
fi

if ! command -v pigs >/dev/null 2>&1; then
    echo "❌ 找不到 pigs (pigpio)。請先安裝: sudo apt install pigpio"
    exit 1
fi

STARTED_DAEMON=0
if ! pigs t >/dev/null 2>&1; then
    echo "ℹ  暫時啟動 pigpiod…"
    pigpiod
    STARTED_DAEMON=1
    sleep 0.5
fi

cleanup() {
    if [ "$STARTED_DAEMON" -eq 1 ]; then
        killall pigpiod 2>/dev/null || true
    fi
}
trap cleanup EXIT

CURRENT=$(pigs padg $PAD)
echo "目前 GPIO 0-27 驅動力: ${CURRENT} mA"

if [ "$TARGET" = "show" ]; then
    exit 0
fi

case "$TARGET" in
    2|4|6|8|10|12|14|16) ;;
    *)
        echo "❌ 驅動力必須是 2、4、6、8、10、12、14 或 16 (mA)，收到: $TARGET"
        exit 1
        ;;
esac

pigs pads $PAD "$TARGET"
NEW=$(pigs padg $PAD)
if [ "$NEW" != "$TARGET" ]; then
    echo "❌ 設定失敗，讀回 ${NEW} mA"
    exit 1
fi

if [ "$TARGET" -eq "$DEFAULT_MA" ]; then
    echo "✅ 已還原為預設 ${NEW} mA"
else
    echo "✅ GPIO 0-27 驅動力已設為 ${NEW} mA (重開機後會回到 ${DEFAULT_MA} mA)"
fi
echo "   接著到 app 設定頁按「連線檢測」比較各時脈的錯誤率。"
