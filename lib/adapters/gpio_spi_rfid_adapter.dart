/// GPIO/SPI RFID Adapter for Raspberry Pi
///
/// Implements direct communication with RC522 RFID modules via SPI interface.
///
/// Hardware Reference: https://wiki.keyestudio.com/Ks0205_Keyestudio_RC522_Sensor
///
/// MFRC522 Protocol: ISO14443A (13.56 MHz RFID)
///
/// 輪巡時序 (RST 等待、REQA 逾時、SPI 時脈…) 由 [RfidTimingConfig] 控制，
/// 可透過 `rfid_timing.json`、環境變數或設定頁調整，也可以用設定頁的
/// 「自動最佳化」替每顆讀卡機找出最小可靠值。詳見 documents/RFID_TIMING_TUNING.md。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../interfaces/rfid_reader.dart';
import '../models/rfid_models.dart';
import '../services/rfid_calibration.dart';
import '../services/rfid_optimizer.dart';
import '../services/rfid_polling_service.dart';
import '../services/rfid_timing_config.dart';
import '../services/simple_mfrc522.dart';

/// Configuration for a single RC522 module on the shared SPI bus
class RC522Config {
  /// Device identifier (e.g., "01", "02", ... "07")
  final String deviceId;

  /// SPI bus number (e.g., 0 for /dev/spidev0.0)
  final int spiNum;

  /// GPIO pin number for RST (Reset) - unique per module
  final int rstPin;

  const RC522Config({
    required this.deviceId,
    required this.spiNum,
    required this.rstPin,
  });

  factory RC522Config.fromReaderConfig(ReaderConfig config) => RC522Config(
        deviceId: config.deviceId,
        spiNum: config.spiNum,
        rstPin: config.rstPin,
      );

  /// Convert to ReaderConfig for use with RFIDPollingService
  ReaderConfig toReaderConfig(int deviceNum) {
    return ReaderConfig(
      deviceNum: deviceNum,
      spiNum: spiNum,
      rstPin: rstPin,
    );
  }

  @override
  String toString() => 'RC522Config(id: $deviceId, spi: $spiNum, rst: $rstPin)';
}

/// GPIO/SPI RFID Reader Manager for Raspberry Pi
///
/// 按鈕觸發、一次讀完所有讀卡機再回傳結果。
/// 實際的 GPIO/SPI 操作 (掃描、連線檢測、自動最佳化) 都在 background isolate 執行，
/// 避免卡住 UI。
class GPIOSPIRFIDReaderManager extends ChangeNotifier
    implements RFIDReaderManager {
  final List<RC522Config> _configs;
  final Map<String, RFIDReading> _latestReadings = {};
  final Map<String, ReaderScanResult> _latestResults = {};

  /// 時序設定檔路徑；null 表示用 path_provider 的文件目錄
  final String? _timingFilePath;
  RfidTimingLoadResult? _timingLoad;
  Duration? _lastScanDuration;
  int? _lastCycleMs;
  bool _calibrating = false;

  /// Default configuration for 7 RC522 modules on Raspberry Pi
  ///
  /// Shared SPI bus: /dev/spidev0.0 (MISO=GPIO9, MOSI=GPIO10, SCK=GPIO11)
  /// Unique RST pins per module, 來源為 [defaultReaderConfigs]：
  /// - Reader 1: RST=GPIO22
  /// - Reader 2: RST=GPIO27
  /// - Reader 3: RST=GPIO17
  /// - Reader 4: RST=GPIO4
  /// - Reader 5: RST=GPIO23
  /// - Reader 6: RST=GPIO24
  /// - Reader 7: RST=GPIO25
  static List<RC522Config> get defaultConfigs =>
      defaultReaderConfigs.map(RC522Config.fromReaderConfig).toList();

  GPIOSPIRFIDReaderManager({
    List<RC522Config>? configs,
    String? timingFilePath,
  })  : _configs = configs ?? defaultConfigs,
        _timingFilePath = timingFilePath;

  /// 目前生效的時序設定 (尚未載入時為預設值)
  RfidTimingConfig get timing =>
      _timingLoad?.config ?? RfidTimingConfig.defaults;

  /// 時序設定的載入結果 (含來源)，尚未載入時為 null
  RfidTimingLoadResult? get timingLoadResult => _timingLoad;

  List<ReaderConfig> get _readerConfigs => [
        for (var i = 0; i < _configs.length; i++)
          _configs[i].toReaderConfig(i + 1),
      ];

  List<String> get _deviceIds => _configs.map((c) => c.deviceId).toList();

  @override
  List<RFIDReader> get readers {
    // Return virtual readers based on configs
    return _configs.map((config) {
      final reading = _latestReadings[config.deviceId];
      return _VirtualRFIDReader(
        deviceId: config.deviceId,
        status: reading?.status ?? ReaderStatus.init,
        address: 'SPI${config.spiNum}.0/GPIO${config.rstPin}',
      );
    }).toList();
  }

  @override
  Future<void> discoverReaders() async {
    // No persistent connections in button-triggered mode
    // Readers are created fresh for each scan
    debugPrint('GPIO/SPI readers configured: ${_configs.length} readers');
    await _ensureTiming();
    notifyListeners();
  }

  @override
  Duration? get lastScanDuration => _lastScanDuration;

  @override
  Map<String, String> get diagnostics {
    final load = _timingLoad;
    final map = <String, String>{};
    if (load == null) {
      map['時序設定'] = '尚未載入 (第一次掃描時載入)';
      return map;
    }
    map['設定來源'] = load.sourceDescription;
    map.addAll(load.config.describe());
    map['估計一輪 (全部沒卡)'] =
        '約 ${load.config.estimateNoCardScanMsFor(_deviceIds)} ms';
    map['估計一輪 (七顆都有卡)'] =
        '約 ${load.config.estimateAllCardsScanMsFor(_deviceIds)} ms';
    if (_lastScanDuration != null) {
      map['上次掃描耗時'] = '${_lastScanDuration!.inMilliseconds} ms'
          '${_lastCycleMs != null ? ' (硬體輪巡 $_lastCycleMs ms)' : ''}';
    }
    for (final result in _latestResults.values) {
      map['讀卡機 ${result.deviceId}'] = result.summary;
    }
    return map;
  }

  @override
  Future<void> reloadSettings() async {
    _timingLoad = null;
    await _ensureTiming();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 時序設定
  // ---------------------------------------------------------------------------

  @override
  bool get supportsCalibration => true;

  @override
  bool get isCalibrating => _calibrating;

  @override
  RfidTimingLoadResult? get timingLoad => _timingLoad;

  @override
  Future<RfidTimingLoadResult?> loadTiming() => _ensureTiming();

  @override
  Future<void> saveTiming(RfidTimingConfig config) async {
    final path = await _timingPath();
    await config.validated().saveTo(path);
    debugPrint('RFID 時序設定已寫入 $path');
    _timingLoad = null;
    await _ensureTiming();
    notifyListeners();
  }

  Future<String> _timingPath() async {
    final envPath = Platform.environment[RfidTimingConfig.fileEnvKey];
    if (envPath != null && envPath.isNotEmpty) return envPath;
    final configured = _timingFilePath;
    if (configured != null) return configured;
    try {
      final directory = await getApplicationDocumentsDirectory();
      return '${directory.path}${Platform.pathSeparator}'
          '${RfidTimingConfig.defaultFileName}';
    } catch (e) {
      debugPrint('⚠ 無法取得文件目錄，改用預設路徑: $e');
      return RfidTimingConfig.defaultFilePath();
    }
  }

  Future<RfidTimingLoadResult> _ensureTiming() async {
    final cached = _timingLoad;
    if (cached != null) return cached;

    final load = await RfidTimingConfig.load(filePath: await _timingPath());
    _timingLoad = load;
    debugPrint('RFID 時序設定: ${load.sourceDescription}');
    debugPrint('RFID 時序設定值: ${load.config.toJson()}');
    return load;
  }

  // ---------------------------------------------------------------------------
  // 掃描
  // ---------------------------------------------------------------------------

  @override
  Future<List<RFIDReading>> scanAll() async {
    if (_calibrating) {
      debugPrint('校正進行中，略過這次掃描');
      return _configs
          .map((config) =>
              _latestReadings[config.deviceId] ??
              RFIDReading.init(config.deviceId))
          .toList();
    }

    debugPrint('Starting async scan of ${_configs.length} readers...');
    final stopwatch = Stopwatch()..start();

    try {
      final load = await _ensureTiming();

      // Convert configs to serializable format for isolate
      final message = <String, dynamic>{
        'configs': [for (final config in _readerConfigs) config.toJson()],
        'timing': load.config.toJson(),
      };

      // Perform scan on background isolate to avoid UI blocking
      final raw = await compute(_performScanInIsolate, message);
      final cycle = ScanCycleResult.fromJson(raw);
      _lastScanDuration = stopwatch.elapsed;
      _lastCycleMs = cycle.totalMs;

      debugPrint('Scan complete in ${stopwatch.elapsedMilliseconds} ms '
          '(hardware ${cycle.totalMs} ms). Found ${cycle.cardCount} cards, '
          'errors: ${cycle.errorReaderIds}');

      // Convert results to RFIDReading objects (on main thread)
      final readings = <RFIDReading>[];
      _latestReadings.clear();
      _latestResults.clear();

      for (final config in _configs) {
        final result = cycle.readers[config.deviceId];
        final reading = _toReading(config.deviceId, result);
        readings.add(reading);
        _latestReadings[config.deviceId] = reading;
        if (result != null) _latestResults[config.deviceId] = result;
      }

      notifyListeners();
      return readings;
    } catch (e) {
      debugPrint('Error during scan: $e');
      _lastScanDuration = stopwatch.elapsed;

      // Return error readings for all readers
      final errorReadings = _configs
          .map((config) => RFIDReading.error(config.deviceId, e.toString()))
          .toList();

      _latestResults.clear();
      for (final reading in errorReadings) {
        _latestReadings[reading.deviceId] = reading;
      }

      notifyListeners();
      return errorReadings;
    }
  }

  RFIDReading _toReading(String deviceId, ReaderScanResult? result) {
    if (result == null) {
      return RFIDReading.error(deviceId, '沒有回傳結果');
    }
    if (result.hasCard) {
      return RFIDReading(
        deviceId: deviceId,
        status: ReaderStatus.ok,
        rfid: result.tagId!, // Already in hex format from SimpleMFRC522
        timestamp: DateTime.now(),
        rawData: result.summary,
      );
    }
    if (result.linkOk) {
      return RFIDReading(
        deviceId: deviceId,
        status: ReaderStatus.ok,
        rfid: '',
        timestamp: DateTime.now(),
        rawData: 'NO_CARD ${result.summary}',
      );
    }
    // 線路異常、晶片無回應或例外：明確標成錯誤，UI 才分得出「沒放餐盤」和「線有問題」
    return RFIDReading(
      deviceId: deviceId,
      status: ReaderStatus.error,
      rfid: '',
      timestamp: DateTime.now(),
      errorMessage: '${result.status.label}'
          '${result.error != null ? ' (${result.error})' : ''}',
      rawData: result.summary,
    );
  }

  /// Static method for isolate execution (no instance state access)
  ///
  /// [message] 內含 `configs` (接線) 與 `timing` (時序設定) 的 JSON。
  static Future<Map<String, dynamic>> _performScanInIsolate(
    Map<String, dynamic> message,
  ) async {
    final configs = (message['configs'] as List)
        .map((raw) =>
            ReaderConfig.fromJson(Map<String, dynamic>.from(raw as Map)))
        .toList();
    final timing = RfidTimingConfig.fromJson(
      Map<String, dynamic>.from(message['timing'] as Map),
    );

    final pollingService = RFIDPollingService(timing: timing, log: debugPrint);
    // 整輪逾時：設定值與最壞情況的兩倍取較大者，超過就視為硬體卡死
    final timeout = timing.scanTimeoutFor(configs.length);
    try {
      final result = await pollingService.performOneLoopCycles(configs).timeout(
        timeout,
        onTimeout: () {
          debugPrint('⚠️  RFID scan timeout in isolate');
          throw TimeoutException(
            'RFID scan timeout after ${timeout.inSeconds} seconds',
          );
        },
      );
      return result.toJson();
    } catch (e) {
      debugPrint('❌ Error in isolate scan: $e');
      rethrow;
    } finally {
      pollingService.dispose();
    }
  }

  // ---------------------------------------------------------------------------
  // 連線檢測與自動最佳化 (在獨立 isolate 執行，進度透過 SendPort 回傳)
  // ---------------------------------------------------------------------------

  @override
  Future<List<LinkMeasurement>> probeLinks({
    List<int>? speeds,
    int samples = 200,
    void Function(String message)? onProgress,
  }) async {
    final load = await _ensureTiming();
    final result = await _runCalibrationJob(
      {
        'kind': 'probe',
        'speeds': speeds ?? RfidOptimizerOptions.defaults.spiSpeeds,
        'samples': samples,
        'configs': [for (final config in _readerConfigs) config.toJson()],
        'base': load.config.toJson(),
      },
      onProgress: (map) => onProgress?.call(map['message'] as String? ?? ''),
    );
    return (result['measurements'] as List)
        .map((raw) =>
            LinkMeasurement.fromJson(Map<String, dynamic>.from(raw as Map)))
        .toList();
  }

  @override
  Future<OptimizationResult> optimize(
    RfidOptimizerOptions options, {
    void Function(OptimizerProgress progress)? onProgress,
    RfidCancelToken? cancel,
  }) async {
    final load = await _ensureTiming();
    final result = await _runCalibrationJob(
      {
        'kind': 'optimize',
        'options': options.toJson(),
        'configs': [for (final config in _readerConfigs) config.toJson()],
        'base': load.config.toJson(),
      },
      onProgress: (map) => onProgress?.call(OptimizerProgress.fromJson(map)),
      cancel: cancel,
    );
    return OptimizationResult.fromJson(result);
  }

  /// 在獨立 isolate 跑一個校正工作。
  /// isolate 先送回它的 control SendPort (用來取消)，之後送 progress / result / error。
  Future<Map<String, dynamic>> _runCalibrationJob(
    Map<String, dynamic> message, {
    void Function(Map<String, dynamic> progress)? onProgress,
    RfidCancelToken? cancel,
  }) async {
    if (_calibrating) {
      throw StateError('連線檢測或最佳化已在進行中');
    }
    _calibrating = true;
    notifyListeners();

    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final completer = Completer<Map<String, dynamic>>();
    SendPort? controlPort;

    void sendCancel() => controlPort?.send('cancel');
    cancel?.addListener(sendCancel);

    final subscription = receivePort.listen((data) {
      if (data is SendPort) {
        controlPort = data;
        if (cancel?.isCancelled == true) data.send('cancel');
        return;
      }
      if (data is! Map) return;
      final map = Map<String, dynamic>.from(data);
      switch (map['type']) {
        case 'progress':
          onProgress?.call(map);
        case 'result':
          if (!completer.isCompleted) completer.complete(map);
        case 'error':
          if (!completer.isCompleted) {
            completer.completeError(
              StateError(map['message']?.toString() ?? '未知錯誤'),
            );
          }
      }
    });
    final errorSubscription = errorPort.listen((data) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('校正 isolate 發生錯誤: $data'));
      }
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _calibrationIsolateEntry,
        <String, dynamic>{...message, 'sendPort': receivePort.sendPort},
        onError: errorPort.sendPort,
        debugName: 'rfid-calibration',
      );
      return await completer.future;
    } finally {
      cancel?.removeListener(sendCancel);
      await subscription.cancel();
      await errorSubscription.cancel();
      receivePort.close();
      errorPort.close();
      isolate?.kill(priority: Isolate.immediate);
      _calibrating = false;
      notifyListeners();
    }
  }

  static Future<void> _calibrationIsolateEntry(
    Map<String, dynamic> message,
  ) async {
    final sendPort = message['sendPort'] as SendPort;
    final control = ReceivePort();
    var cancelled = false;
    control.listen((data) {
      if (data == 'cancel') cancelled = true;
    });
    sendPort.send(control.sendPort);

    try {
      final configs = (message['configs'] as List)
          .map((raw) =>
              ReaderConfig.fromJson(Map<String, dynamic>.from(raw as Map)))
          .toList();
      final base = RfidTimingConfig.fromJson(
        Map<String, dynamic>.from(message['base'] as Map),
      );
      final runner = HardwareOptimizerRunner(
        configs: configs,
        base: base,
        log: debugPrint,
      );

      if (message['kind'] == 'probe') {
        final speeds = (message['speeds'] as List)
            .map((value) => (value as num).toInt())
            .toList();
        final samples = (message['samples'] as num).toInt();
        final measurements = <Map<String, dynamic>>[];
        for (final speed in speeds) {
          if (cancelled) break;
          sendPort.send({'type': 'progress', 'message': 'SPI $speed Hz 連線檢測中'});
          final probes = await runner.probeLinks(speed, samples: samples);
          for (final probe in probes) {
            measurements.add(
              LinkMeasurement(spiSpeedHz: speed, probe: probe).toJson(),
            );
          }
        }
        sendPort.send({'type': 'result', 'measurements': measurements});
      } else {
        final options = RfidOptimizerOptions.fromJson(
          Map<String, dynamic>.from(message['options'] as Map),
        );
        final optimizer = RfidOptimizer(
          runner,
          options: options,
          onProgress: (progress) =>
              sendPort.send({'type': 'progress', ...progress.toJson()}),
          shouldCancel: () => cancelled,
        );
        final result = await optimizer.run(base: base);
        sendPort.send({'type': 'result', ...result.toJson()});
      }
    } catch (e) {
      sendPort.send({'type': 'error', 'message': e.toString()});
    } finally {
      control.close();
    }
  }

  @override
  RFIDReading? getReading(String deviceId) {
    return _latestReadings[deviceId];
  }

  @override
  List<RFIDReading> get validReadings {
    return _latestReadings.values.where((reading) => reading.hasCard).toList();
  }

  @override
  void dispose() {
    _latestReadings.clear();
    _latestResults.clear();
    super.dispose();
  }
}

/// Virtual RFID reader for status display
/// Used by GPIOSPIRFIDReaderManager to provide reader information
/// without maintaining persistent connections
class _VirtualRFIDReader implements RFIDReader {
  @override
  final String deviceId;

  @override
  final ReaderStatus status;

  @override
  final String address;

  _VirtualRFIDReader({
    required this.deviceId,
    required this.status,
    required this.address,
  });

  @override
  Stream<RFIDReading> get readings => const Stream.empty();

  @override
  Future<void> connect() async {
    throw UnimplementedError('Virtual reader does not support connection');
  }

  @override
  Future<void> disconnect() async {
    throw UnimplementedError('Virtual reader does not support disconnection');
  }

  @override
  Future<RFIDReading> scan() async {
    throw UnimplementedError('Virtual reader does not support direct scanning');
  }

  @override
  bool get isConnected => false;
}
