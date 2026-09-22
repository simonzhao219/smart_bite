/// RFID Reader Provider
///
/// Abstracted provider that manages RFID readers independently of the hardware implementation.
/// Provides a hardware-agnostic interface for RFID reading.
///
/// Supports multiple reader implementations:
/// - GPIO/SPI (Raspberry Pi with RC522 modules)
/// - Mock (Testing)
///
/// 兩種掃描方式：
/// - [updateReaders]：掃一次，結果直接取代目前狀態 (設定頁的「掃描」按鈕、訂單頁的「重新感應」)。
/// - [startPolling] / [stopPolling]：持續背景輪巡，每輪結果做「黏性合併」
///   (見 [RfidTimingConfig.stickyRounds])，托盤晚放、中途換餐、偶發漏讀都不用客人按鈕。
///   訂單頁顯示的是合併後的狀態；「線路異常」只在連續 [linkErrorRounds] 輪都異常時才算。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../interfaces/rfid_reader.dart';
import '../services/meal_identification_service.dart';
import '../services/rfid_calibration.dart';
import '../services/rfid_optimizer.dart';
import '../services/rfid_timing_config.dart';

/// 每顆讀卡機的黏性合併狀態
class _StickyState {
  /// 最後一次讀到的卡片
  RFIDReading? lastCard;

  /// 最後一次讀到卡片是第幾輪
  int lastSeenRound = -1;

  /// 連續幾輪線路異常
  int errorRounds = 0;
}

/// Provider for managing RFID readers and meal identification
class RFIDReaderProvider extends ChangeNotifier {
  /// 連續幾輪線路異常才對外顯示成錯誤 (單次掃描不受此限制)
  static const int linkErrorRounds = 3;

  final RFIDReaderManager _readerManager;
  final MealIdentificationService _mealService;

  List<String> _orderNames = [];
  bool _isScanning = false;
  DateTime? _lastUpdateTime;

  /// 合併後的每顆狀態 (單次掃描時就是原始結果)
  final Map<String, RFIDReading> _merged = {};
  final Map<String, _StickyState> _sticky = {};

  /// 目前對外顯示為線路異常的讀卡機
  final Set<String> _errorIds = {};

  bool _polling = false;
  Future<void>? _pollLoop;

  /// 每次 [startPolling] 加一：舊的迴圈在 stop 又 start 之後醒來時，看到代數不同就退出，
  /// 不會出現兩個迴圈同時在跑
  int _pollGeneration = 0;
  int _round = 0;
  Completer<void>? _firstRound;

  /// 目前正在跑的那一輪 (背景輪巡或單次掃描)，用來讓兩者互相等待而不重疊
  Future<void>? _activeScan;

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

  /// List of identified meal names from the current (merged) state
  List<String> get orderNames => List.unmodifiable(_orderNames);

  /// Whether a single scan ([updateReaders]) is currently in progress
  bool get isScanning => _isScanning;

  /// 持續背景輪巡進行中
  bool get isPolling => _polling;

  /// 背景輪巡已完成幾輪 (從 [startPolling] 起算)
  int get pollRounds => _round;

  /// Last update timestamp
  DateTime? get lastUpdateTime => _lastUpdateTime;

  /// Number of readers
  int get readerCount => readers.length;

  /// Number of valid cards detected in the current (merged) state
  int get validCardCount => _orderNames.length;

  /// 上一次掃描花的時間 (硬體不支援時為 null)
  Duration? get lastScanDuration => _readerManager.lastScanDuration;

  /// 診斷資訊 (時序設定、來源、各讀卡機摘要)
  Map<String, String> get diagnostics => _readerManager.diagnostics;

  /// 目前生效的時序設定 (尚未載入時為預設值)
  RfidTimingConfig get timing =>
      _readerManager.timingLoad?.config ?? RfidTimingConfig.defaults;

  /// 對外顯示為線路異常的讀卡機 deviceId。
  /// 單次掃描：這一次異常就算；背景輪巡：連續 [linkErrorRounds] 輪異常才算。
  List<String> get errorReaderIds => _errorIds.toList()..sort();

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
  /// 背景輪巡進行中會先停下來、等目前那一輪結束，做完再恢復。
  Future<List<LinkMeasurement>> probeLinks({
    List<int>? speeds,
    int samples = 200,
    void Function(String message)? onProgress,
  }) async {
    final wasPolling = _polling;
    await stopPolling();
    try {
      return await _readerManager.probeLinks(
        speeds: speeds,
        samples: samples,
        onProgress: onProgress,
      );
    } finally {
      if (wasPolling) startPolling();
      notifyListeners();
    }
  }

  /// 自動最佳化 (七顆都要放卡片)。開始時不另外 notify，理由同 [probeLinks]；
  /// 背景輪巡一樣先停、做完再恢復。
  Future<OptimizationResult> optimize(
    RfidOptimizerOptions options, {
    void Function(OptimizerProgress progress)? onProgress,
    RfidCancelToken? cancel,
  }) async {
    final wasPolling = _polling;
    await stopPolling();
    try {
      return await _readerManager.optimize(
        options,
        onProgress: onProgress,
        cancel: cancel,
      );
    } finally {
      if (wasPolling) startPolling();
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

  /// Scan all readers once and identify meals
  ///
  /// This is the main method that:
  /// 1. Scans all RFID readers
  /// 2. Identifies meals from card UIDs
  /// 3. Updates orderNames list
  /// 4. Notifies listeners
  ///
  /// 結果直接取代目前狀態 (不做黏性合併)。背景輪巡進行中會先等目前那一輪結束，
  /// 兩者不會同時碰硬體。
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
      // 等背景輪巡的那一輪結束再掃
      await _waitForActiveScan();
      final completer = Completer<void>();
      _activeScan = completer.future;
      final List<RFIDReading> readings;
      try {
        readings = await _readerManager.scanAll();
      } finally {
        completer.complete();
        _activeScan = null;
      }
      _replaceState(readings);

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

  /// Get the current (merged) reading of a reader
  RFIDReading? getReading(String deviceId) {
    return _merged[deviceId] ?? _readerManager.getReading(deviceId);
  }

  // ========== 持續背景輪巡 ==========

  /// 開始持續背景輪巡。校正進行中或已在輪巡時不做事。
  void startPolling() {
    if (_polling) return;
    if (isCalibrating) {
      debugPrint('Calibration in progress, polling not started');
      return;
    }
    _polling = true;
    _round = 0;
    _sticky.clear();
    _firstRound = Completer<void>();
    _pollLoop = _runPollLoop(++_pollGeneration);
    notifyListeners();
  }

  /// 停止背景輪巡，等目前這一輪結束才回來 (之後可以安全地跑校正或分析)
  Future<void> stopPolling() async {
    if (!_polling) return;
    _polling = false;
    final loop = _pollLoop;
    _pollLoop = null;
    if (loop != null) await loop;
    final first = _firstRound;
    if (first != null && !first.isCompleted) first.complete();
    notifyListeners();
  }

  /// 等背景輪巡的第一輪完成 (首頁按「開始」後用，取代固定等 3 秒)。
  /// 超過 [timeout] 就不再等，避免硬體卡住時卡在首頁。
  Future<void> waitForFirstRound({Duration? timeout}) async {
    final first = _firstRound;
    if (first == null || first.isCompleted) return;
    final limit = timeout ?? timing.scanTimeoutFor(readerCount);
    await first.future.timeout(limit, onTimeout: () {});
  }

  Future<void> _runPollLoop(int generation) async {
    bool active() => _polling && generation == _pollGeneration;

    while (active()) {
      if (isCalibrating) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }
      await _waitForActiveScan();
      if (!active()) break;

      final completer = Completer<void>();
      _activeScan = completer.future;
      try {
        final readings = await _readerManager.scanAll();
        _round++;
        _mergeRound(readings);
        _lastUpdateTime = DateTime.now();
      } catch (e) {
        debugPrint('Error during background poll: $e');
      } finally {
        completer.complete();
        _activeScan = null;
      }
      final first = _firstRound;
      if (first != null && !first.isCompleted) first.complete();
      notifyListeners();

      if (!active()) break;
      final gap = timing.pollGapMs;
      if (gap > 0) await Future<void>.delayed(Duration(milliseconds: gap));
    }
  }

  Future<void> _waitForActiveScan() async {
    while (true) {
      final active = _activeScan;
      if (active == null) return;
      await active;
    }
  }

  /// 單次掃描：結果直接取代目前狀態
  void _replaceState(List<RFIDReading> readings) {
    _merged.clear();
    _errorIds.clear();
    _sticky.clear();
    for (final reading in readings) {
      _merged[reading.deviceId] = reading;
      if (reading.status == ReaderStatus.error) _errorIds.add(reading.deviceId);
    }
  }

  /// 背景輪巡：黏性合併。
  /// - 這輪讀到卡：更新 (不同 UID 立即換掉，換餐)
  /// - 這輪沒卡或線路異常：距離上次讀到不超過 stickyRounds 就保留上次的卡片，否則清掉
  /// - 線路異常連續 [linkErrorRounds] 輪才對外顯示
  void _mergeRound(List<RFIDReading> readings) {
    final sticky = timing.stickyRounds;
    final before = _orderNames.join(',');
    for (final reading in readings) {
      final id = reading.deviceId;
      final state = _sticky.putIfAbsent(id, _StickyState.new);
      if (reading.hasCard) {
        state.lastCard = reading;
        state.lastSeenRound = _round;
        state.errorRounds = 0;
        _merged[id] = reading;
      } else {
        if (reading.status == ReaderStatus.error) {
          state.errorRounds++;
        } else {
          state.errorRounds = 0;
        }
        final last = state.lastCard;
        if (last != null && _round - state.lastSeenRound <= sticky) {
          _merged[id] = last;
        } else {
          state.lastCard = null;
          _merged[id] = reading;
        }
      }
      if (state.errorRounds >= linkErrorRounds) {
        _errorIds.add(id);
      } else {
        _errorIds.remove(id);
      }
    }
    _orderNames =
        _mealService.identifyMealsFromReadings(_merged.values.toList());
    final after = _orderNames.join(',');
    if (after != before) {
      debugPrint('Background poll round $_round: meals [$after]');
    }
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

  /// Get all (merged) readings with valid cards
  List<RFIDReading> get validReadings =>
      _merged.values.where((reading) => reading.hasCard).toList();

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
    _polling = false;
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
