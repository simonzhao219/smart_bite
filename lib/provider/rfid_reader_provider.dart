/// RFID Reader Provider
///
/// Abstracted provider that manages RFID readers independently of the hardware implementation.
/// Provides a hardware-agnostic interface for RFID reading.
///
/// Supports multiple reader implementations:
/// - GPIO/SPI (Raspberry Pi with RC522 modules)
/// - Mock (Testing)
library;

import 'package:flutter/material.dart';
import '../interfaces/rfid_reader.dart';
import '../services/meal_identification_service.dart';
import '../services/rfid_calibration.dart';
import '../services/rfid_optimizer.dart';
import '../services/rfid_timing_config.dart';

/// Provider for managing RFID readers and meal identification
class RFIDReaderProvider extends ChangeNotifier {
  final RFIDReaderManager _readerManager;
  final MealIdentificationService _mealService;

  List<String> _orderNames = [];
  bool _isScanning = false;
  DateTime? _lastUpdateTime;

  RFIDReaderProvider({
    required RFIDReaderManager readerManager,
    MealIdentificationService? mealService,
  })  : _readerManager = readerManager,
        _mealService = mealService ?? MealIdentificationService() {
    // Listen to reader manager changes
    _readerManager.addListener(_onReaderManagerUpdate);
  }

  // ========== Getters ==========

  /// List of all RFID readers
  List<RFIDReader> get readers => _readerManager.readers;

  /// List of identified meal names from last scan
  List<String> get orderNames => List.unmodifiable(_orderNames);

  /// Whether a scan is currently in progress
  bool get isScanning => _isScanning;

  /// Last update timestamp
  DateTime? get lastUpdateTime => _lastUpdateTime;

  /// Number of readers
  int get readerCount => readers.length;

  /// Number of valid cards detected in last scan
  int get validCardCount => _orderNames.length;

  /// 上一次掃描花的時間 (硬體不支援時為 null)
  Duration? get lastScanDuration => _readerManager.lastScanDuration;

  /// 診斷資訊 (時序設定、來源、各讀卡機摘要)
  Map<String, String> get diagnostics => _readerManager.diagnostics;

  /// 狀態為錯誤的讀卡機 deviceId (線路異常、晶片無回應…)
  List<String> get errorReaderIds => readers
      .where((reader) => reader.status == ReaderStatus.error)
      .map((reader) => reader.deviceId)
      .toList();

  /// 是否支援時序設定、連線檢測與自動最佳化
  bool get supportsCalibration => _readerManager.supportsCalibration;

  /// 連線檢測或自動最佳化進行中
  bool get isCalibrating => _readerManager.isCalibrating;

  /// 目前載入的時序設定 (含來源)
  RfidTimingLoadResult? get timingLoad => _readerManager.timingLoad;

  /// 讀取 (必要時載入) 時序設定
  Future<RfidTimingLoadResult?> loadTiming() async {
    final load = await _readerManager.loadTiming();
    notifyListeners();
    return load;
  }

  /// 儲存時序設定並重新載入
  Future<void> saveTiming(RfidTimingConfig config) async {
    await _readerManager.saveTiming(config);
    notifyListeners();
  }

  /// 連線檢測。開始時不另外 notify：manager 翻轉 [isCalibrating] 時會通知，
  /// 而且這裡在任何 await 之前 notify 會撞上對話框 initState 期間的 build。
  Future<List<LinkMeasurement>> probeLinks({
    List<int>? speeds,
    int samples = 200,
    void Function(String message)? onProgress,
  }) async {
    try {
      return await _readerManager.probeLinks(
        speeds: speeds,
        samples: samples,
        onProgress: onProgress,
      );
    } finally {
      notifyListeners();
    }
  }

  /// 自動最佳化 (七顆都要放卡片)。開始時不另外 notify，理由同 [probeLinks]。
  Future<OptimizationResult> optimize(
    RfidOptimizerOptions options, {
    void Function(OptimizerProgress progress)? onProgress,
    RfidCancelToken? cancel,
  }) async {
    try {
      return await _readerManager.optimize(
        options,
        onProgress: onProgress,
        cancel: cancel,
      );
    } finally {
      notifyListeners();
    }
  }

  // ========== Methods ==========

  /// Discover and initialize all available readers
  Future<void> discoverReaders() async {
    try {
      await _readerManager.discoverReaders();
      notifyListeners();
    } catch (e) {
      debugPrint('Error discovering readers: $e');
      rethrow;
    }
  }

  /// Scan all readers and identify meals
  ///
  /// This is the main method that:
  /// 1. Scans all RFID readers
  /// 2. Identifies meals from card UIDs
  /// 3. Updates orderNames list
  /// 4. Notifies listeners
  Future<void> updateReaders() async {
    if (_isScanning) {
      debugPrint('Scan already in progress, skipping');
      return;
    }
    if (isCalibrating) {
      debugPrint('Calibration in progress, skipping scan');
      return;
    }

    _isScanning = true;
    _orderNames.clear();
    notifyListeners();

    try {
      // Scan all readers
      final readings = await _readerManager.scanAll();

      // Identify meals from valid readings
      _orderNames = _mealService.identifyMealsFromReadings(readings);

      // Enhanced logging for analytics - distinguish different empty scenarios
      if (_orderNames.isEmpty) {
        final totalReadings = readings.length;
        final validReadings = readings.where((r) => r.hasCard).length;
        final errorReadings =
            readings.where((r) => r.status == ReaderStatus.error).length;

        if (totalReadings == 0) {
          debugPrint(
              '📊 Analytics: No RFID scan performed (0 readers configured)');
        } else if (errorReadings > 0) {
          debugPrint(
              '📊 Analytics: RFID scan completed but encountered $errorReadings errors, 0 meals identified');
        } else if (validReadings == 0) {
          debugPrint(
              '📊 Analytics: RFID scan completed, no cards detected (user did not place any dishes)');
        } else {
          debugPrint(
              '📊 Analytics: RFID scan completed, $validReadings cards detected but no meals identified (unknown cards)');
        }
      } else {
        debugPrint('✓ Scan complete: ${_orderNames.length} meals identified');
        debugPrint('  Meals: $_orderNames');
      }

      // Update last scan timestamp
      _lastUpdateTime = DateTime.now();
    } catch (e) {
      debugPrint('Error during scan: $e');
      rethrow;
    } finally {
      _isScanning = false;
      notifyListeners();
    }
  }

  /// Get reading from a specific reader by device ID
  RFIDReading? getReading(String deviceId) {
    return _readerManager.getReading(deviceId);
  }

  /// 重新載入讀卡機設定 (例如 rfid_timing.json)
  Future<void> reloadSettings() async {
    try {
      await _readerManager.reloadSettings();
    } catch (e) {
      debugPrint('Error reloading reader settings: $e');
    } finally {
      notifyListeners();
    }
  }

  /// Get all readings with valid cards
  List<RFIDReading> get validReadings => _readerManager.validReadings;

  /// Get statistics about last scan
  Map<String, int> getStats() {
    final allReadings = readers
        .map((r) => getReading(r.deviceId))
        .whereType<RFIDReading>()
        .toList();

    return _mealService.getIdentificationStats(allReadings);
  }

  /// Get reader status summary
  Map<String, int> getReaderStatusSummary() {
    final statusCounts = <String, int>{
      'init': 0,
      'updating': 0,
      'ok': 0,
      'error': 0,
      'disconnected': 0,
    };

    for (final reader in readers) {
      final statusKey = reader.status.toString().split('.').last;
      statusCounts[statusKey] = (statusCounts[statusKey] ?? 0) + 1;
    }

    return statusCounts;
  }

  /// Check if all readers are in OK state
  bool get allReadersOk {
    return readers.every((r) => r.status == ReaderStatus.ok);
  }

  /// Check if any reader has an error
  bool get hasErrors {
    return readers.any((r) => r.status == ReaderStatus.error);
  }

  void _onReaderManagerUpdate() {
    notifyListeners();
  }

  @override
  void dispose() {
    _readerManager.removeListener(_onReaderManagerUpdate);
    _readerManager.dispose();
    super.dispose();
  }
}

/// Extension to convert ReaderStatus to user-friendly display strings
extension ReaderStatusDisplay on ReaderStatus {
  String get displayName {
    switch (this) {
      case ReaderStatus.init:
        return '初始化';
      case ReaderStatus.updating:
        return '更新中';
      case ReaderStatus.ok:
        return '正常';
      case ReaderStatus.error:
        return '錯誤';
      case ReaderStatus.disconnected:
        return '未連接';
    }
  }

  /// Get color for status display
  Color get color {
    switch (this) {
      case ReaderStatus.init:
        return Colors.grey;
      case ReaderStatus.updating:
        return Colors.blue;
      case ReaderStatus.ok:
        return Colors.green;
      case ReaderStatus.error:
        return Colors.red;
      case ReaderStatus.disconnected:
        return Colors.orange;
    }
  }
}
