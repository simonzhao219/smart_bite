/// RFID Reader Abstraction Layer
/// 
/// This interface decouples the business logic from the specific hardware implementation.
/// Currently supports GPIO/SPI communication on Raspberry Pi.
/// 
/// All RFID readers must implement this interface to ensure consistent behavior
/// across different hardware platforms.
library;

import 'package:flutter/foundation.dart';

/// Status of an individual RFID reader module
enum ReaderStatus {
  /// Reader is initialized but not yet connected
  init,
  
  /// Reader is currently scanning/updating
  updating,
  
  /// Reader is connected and operating normally
  ok,
  
  /// Reader encountered an error
  error,
  
  /// Reader is disconnected or offline
  disconnected,
}

/// Represents a single RFID card reading event
@immutable
class RFIDReading {
  /// Unique identifier for the reader device (e.g., "01", "02", ... "07")
  final String deviceId;
  
  /// Current status of the reader
  final ReaderStatus status;
  
  /// RFID card UID (8-character hex string, e.g., "8804F9E3")
  /// Empty string if no card detected
  final String rfid;
  
  /// Timestamp when the reading was taken
  final DateTime timestamp;
  
  /// Optional error message if status is error
  final String? errorMessage;
  
  /// Optional raw data for debugging
  final String? rawData;

  const RFIDReading({
    required this.deviceId,
    required this.status,
    required this.rfid,
    required this.timestamp,
    this.errorMessage,
    this.rawData,
  });

  /// Creates a reading indicating initialization state
  factory RFIDReading.init(String deviceId) {
    return RFIDReading(
      deviceId: deviceId,
      status: ReaderStatus.init,
      rfid: '',
      timestamp: DateTime.now(),
    );
  }

  /// Creates a reading indicating an error state
  factory RFIDReading.error(String deviceId, String errorMessage) {
    return RFIDReading(
      deviceId: deviceId,
      status: ReaderStatus.error,
      rfid: '',
      timestamp: DateTime.now(),
      errorMessage: errorMessage,
    );
  }

  /// Creates a successful reading with RFID data
  factory RFIDReading.success(String deviceId, String rfid) {
    return RFIDReading(
      deviceId: deviceId,
      status: ReaderStatus.ok,
      rfid: rfid,
      timestamp: DateTime.now(),
    );
  }

  /// Check if this reading has valid RFID data
  bool get hasCard => rfid.isNotEmpty && status == ReaderStatus.ok;

  @override
  String toString() {
    return 'RFIDReading(deviceId: $deviceId, status: $status, rfid: $rfid, timestamp: $timestamp)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is RFIDReading &&
        other.deviceId == deviceId &&
        other.status == status &&
        other.rfid == rfid;
  }

  @override
  int get hashCode => Object.hash(deviceId, status, rfid);
}

/// Abstract interface for RFID readers
/// 
/// Implementations:
/// - GPIOSPIRFIDAdapter: Reads from RC522 modules via GPIO/SPI on Raspberry Pi
/// - MockRFIDAdapter: Mock implementation for testing
abstract class RFIDReader {
  /// Unique identifier for this reader (e.g., "01", "02", ... "07")
  String get deviceId;
  
  /// Current status of the reader
  ReaderStatus get status;
  
  /// Physical address/location identifier
  /// - For Serial: "/dev/ttyUSB0", "COM3", etc.
  /// - For GPIO: "SPI0.0", "GPIO17", etc.
  String get address;
  
  /// Stream of RFID readings from this reader
  /// Emits a new RFIDReading whenever a scan is performed
  Stream<RFIDReading> get readings;
  
  /// Connect to the RFID reader hardware
  /// Throws exception if connection fails
  Future<void> connect();
  
  /// Disconnect from the RFID reader hardware
  Future<void> disconnect();
  
  /// Perform a single scan for RFID cards
  /// Returns the latest reading
  Future<RFIDReading> scan();
  
  /// Check if the reader is currently connected
  bool get isConnected;
}

/// Manager for multiple RFID readers
/// 
/// Coordinates scanning across multiple reader devices and aggregates results
abstract class RFIDReaderManager extends ChangeNotifier {
  /// List of all managed RFID readers
  List<RFIDReader> get readers;
  
  /// Discover and initialize all available readers
  /// - For Serial: Scans for available COM/USB ports
  /// - For GPIO: Initializes configured SPI devices
  Future<void> discoverReaders();
  
  /// Scan all readers simultaneously
  /// Returns list of readings from all readers
  Future<List<RFIDReading>> scanAll();
  
  /// Get the most recent reading from a specific reader
  RFIDReading? getReading(String deviceId);
  
  /// Get all readings that have valid RFID cards detected
  List<RFIDReading> get validReadings;

  /// 上一次 [scanAll] 花的時間；實作不支援時為 null
  Duration? get lastScanDuration;

  /// 給設定頁顯示的診斷資訊 (時序設定、來源、各讀卡機摘要)；沒有就回空 map
  Map<String, String> get diagnostics;

  /// 重新載入設定 (例如 RFID 時序設定檔)；實作不支援時什麼都不做
  Future<void> reloadSettings();
  
  /// Dispose of all readers and clean up resources
  @override
  void dispose();
}
