/// GPIO Cleanup Utility for Smart Bite Application
library gpio_cleanup;

/// This Dart script provides GPIO cleanup functionality that can be called
/// from within the Flutter app or run as a standalone utility.
/// 
/// Usage:
///   - Standalone: dart run scripts/gpio_cleanup.dart
///   - From app: import and call GPIOCleanup.cleanupAll()
/// 
/// This is safer than shell scripts because it uses the same dart_periphery
/// library as the main app, ensuring consistent GPIO handling.

import 'dart:io';

import 'package:dart_periphery/dart_periphery.dart';
import 'package:smart_bite/models/rfid_models.dart';

// ignore_for_file: avoid_print

class GPIOCleanup {
  /// GPIO pins used by Smart Bite RFID readers (RST pins)
  /// 與 app 使用同一份接線表 [defaultReaderConfigs]，改接線時只要改那一處
  static final List<int> rfidResetPins =
      defaultReaderConfigs.map((config) => config.rstPin).toList();

  /// Cleanup all RFID GPIO pins
  /// 
  /// Attempts to release all GPIO pins that may be locked after crashes.
  /// Safe to call even if pins are not in use - will handle errors gracefully.
  /// 
  /// Returns: Map of pin numbers to cleanup status (true = success, false = failed)
  static Future<Map<int, bool>> cleanupAll() async {
    final results = <int, bool>{};
    
    print('🧹 Starting GPIO cleanup for Smart Bite...');
    print('=' * 60);
    
    for (final pin in rfidResetPins) {
      try {
        results[pin] = await _cleanupPin(pin);
      } catch (e) {
        print('   ❌ Unexpected error cleaning GPIO $pin: $e');
        results[pin] = false;
      }
    }
    
    print('=' * 60);
    final successCount = results.values.where((v) => v).length;
    print('✅ Cleanup complete: $successCount/${rfidResetPins.length} pins released');
    print('');
    
    return results;
  }

  /// Cleanup a single GPIO pin
  static Future<bool> _cleanupPin(int pin) async {
    GPIO? gpio;
    
    try {
      print('📌 Attempting to cleanup GPIO pin $pin...');
      
      // Try to open the GPIO pin
      // If it's stuck, this will either:
      // 1. Successfully open it (allowing us to close it properly)
      // 2. Throw an error (pin already in use or invalid)
      try {
        gpio = GPIO(pin, GPIOdirection.gpioDirOut);
        
        // Successfully opened - now close it properly
        gpio.dispose();
        print('   ✓ GPIO pin $pin successfully released');
        return true;
      } catch (e) {
        // Pin might be in use or already free
        final errorMsg = e.toString();
        if (errorMsg.contains('Device or resource busy') || 
            errorMsg.contains('busy')) {
          print('   ⚠  GPIO pin $pin is locked (busy)');
          // Try force cleanup via sysfs
          return await _forceUnexport(pin);
        } else if (errorMsg.contains('No such device') || 
                   errorMsg.contains('not exported')) {
          print('   ℹ  GPIO pin $pin not in use, skipping');
          return true;
        } else {
          print('   ❌ Failed to cleanup GPIO pin $pin: $e');
          return false;
        }
      }
    } catch (e) {
      print('   ❌ Error cleaning GPIO pin $pin: $e');
      return false;
    } finally {
      // Ensure GPIO is disposed even if errors occur
      gpio?.dispose();
    }
  }

  /// Force unexport a GPIO pin via sysfs
  /// 
  /// Last resort cleanup method when dart_periphery cannot release the pin.
  /// Requires root privileges.
  static Future<bool> _forceUnexport(int pin) async {
    try {
      print('   🔧 Attempting force unexport via sysfs...');
      
      // Check if pin is exported
      final gpioPath = Directory('/sys/class/gpio/gpio$pin');
      if (!await gpioPath.exists()) {
        print('   ℹ  GPIO pin $pin not exported in sysfs');
        return true;
      }
      
      // Write to unexport file
      final unexportFile = File('/sys/class/gpio/unexport');
      await unexportFile.writeAsString('$pin\n');
      
      print('   ✓ GPIO pin $pin force unexported successfully');
      return true;
    } catch (e) {
      if (e.toString().contains('Permission denied')) {
        print('   ❌ Permission denied - run with sudo for force cleanup');
      } else {
        print('   ❌ Force unexport failed: $e');
      }
      return false;
    }
  }

  /// Check current GPIO status
  /// 
  /// Returns a map of pin numbers to their status:
  /// - "free": Pin is not in use
  /// - "in_use": Pin is currently exported/in use
  /// - "unknown": Cannot determine status
  static Future<Map<int, String>> checkStatus() async {
    final status = <int, String>{};
    
    print('🔍 Checking GPIO status...');
    print('=' * 60);
    
    for (final pin in rfidResetPins) {
      final gpioPath = Directory('/sys/class/gpio/gpio$pin');
      if (await gpioPath.exists()) {
        status[pin] = 'in_use';
        print('   📍 GPIO $pin: IN USE');
      } else {
        status[pin] = 'free';
        print('   ⚪ GPIO $pin: FREE');
      }
    }
    
    print('=' * 60);
    return status;
  }
}

/// Main entry point for standalone execution
Future<void> main(List<String> args) async {
  print('');
  print('╔════════════════════════════════════════════════════════════╗');
  print('║     Smart Bite GPIO Cleanup Utility (Dart Version)        ║');
  print('╚════════════════════════════════════════════════════════════╝');
  print('');
  
  // Parse command line arguments
  final checkOnly = args.contains('--check') || args.contains('-c');
  final forceMode = args.contains('--force') || args.contains('-f');
  
  if (args.contains('--help') || args.contains('-h')) {
    _printHelp();
    exit(0);
  }
  
  try {
    if (checkOnly) {
      // Check status only
      await GPIOCleanup.checkStatus();
    } else {
      // Perform cleanup
      if (!forceMode && !Platform.isLinux) {
        print('⚠  Warning: This utility is designed for Linux systems');
        print('   Current platform: ${Platform.operatingSystem}');
        print('   Use --force to override this check');
        exit(1);
      }
      
      final results = await GPIOCleanup.cleanupAll();
      
      // Exit with error code if any cleanup failed
      final allSuccess = results.values.every((v) => v);
      exit(allSuccess ? 0 : 1);
    }
  } catch (e) {
    print('');
    print('❌ Fatal error during GPIO cleanup: $e');
    exit(1);
  }
}

void _printHelp() {
  print('''
Usage: dart run scripts/gpio_cleanup.dart [OPTIONS]

Options:
  -h, --help     Show this help message
  -c, --check    Check GPIO status without cleaning up
  -f, --force    Force cleanup even on non-Linux systems (not recommended)

Examples:
  # Cleanup all GPIO pins
  dart run scripts/gpio_cleanup.dart
  
  # Check current GPIO status
  dart run scripts/gpio_cleanup.dart --check
  
  # Force cleanup (use with caution)
  sudo dart run scripts/gpio_cleanup.dart --force

Notes:
  - Run with sudo if permission errors occur
  - Safe to run multiple times
  - Will not affect non-RFID GPIO pins
  - GPIO pins configured for cleanup: ${GPIOCleanup.rfidResetPins.join(', ')}

Integration with Flutter App:
  Import the GPIOCleanup class in your app:
  
    import 'package:smart_bite/scripts/gpio_cleanup.dart';
    
    // Call on app startup
    await GPIOCleanup.cleanupAll();
    
    // Or check status
    final status = await GPIOCleanup.checkStatus();
''');
}
