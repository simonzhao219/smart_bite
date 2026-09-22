#!/bin/bash
################################################################################
# GPIO Cleanup Script for Smart Bite Application
# 
# Purpose: Release GPIO pins that may be locked after app crashes or force-close
# Usage: Run this script before starting the app if GPIO pins are stuck
# 
# This script should be executed:
# 1. Manually when GPIO errors occur ("Device or resource busy")
# 2. Automatically on system boot (via systemd or rc.local)
# 3. Before app launch in production deployment
################################################################################

set -e  # Exit on error

# GPIO pins used by Smart Bite RFID readers (RST pins)
# Must match defaultReaderConfigs in lib/models/rfid_models.dart
GPIO_PINS=(22 27 17 4 23 24 25)

echo "🧹 Smart Bite GPIO Cleanup Starting..."
echo "================================================"

# Function to unexport a GPIO pin
cleanup_gpio_pin() {
    local pin=$1
    local gpio_path="/sys/class/gpio/gpio${pin}"
    
    # Check if pin is already exported
    if [ -d "$gpio_path" ]; then
        echo "📌 Cleaning up GPIO pin ${pin}..."
        
        # Try to unexport the pin
        if echo "$pin" > /sys/class/gpio/unexport 2>/dev/null; then
            echo "   ✓ GPIO pin ${pin} successfully released"
        else
            echo "   ⚠  Failed to unexport GPIO pin ${pin} (may not be in use)"
        fi
    else
        echo "   ℹ  GPIO pin ${pin} not in use, skipping"
    fi
}

# Check if running with sufficient privileges
if [ "$EUID" -ne 0 ]; then 
    echo "❌ ERROR: This script must be run as root (use sudo)"
    echo "   Usage: sudo ./scripts/gpio_cleanup.sh"
    exit 1
fi

# Cleanup each GPIO pin
for pin in "${GPIO_PINS[@]}"; do
    cleanup_gpio_pin "$pin"
done

echo "================================================"
echo "✅ GPIO cleanup completed successfully!"
echo ""
echo "💡 Tips:"
echo "   - If GPIO errors persist, check hardware connections"
echo "   - Verify GPIO pin numbers match your RC522 wiring"
echo "   - Check dmesg for kernel GPIO errors: dmesg | grep gpio"
echo "   - List currently exported GPIOs: ls -la /sys/class/gpio/"
echo ""
