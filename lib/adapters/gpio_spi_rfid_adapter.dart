/// GPIO/SPI RFID Adapter for Raspberry Pi
///
/// Implements direct communication with RC522 RFID modules via SPI interface.
///
/// Hardware Reference: https://wiki.keyestudio.com/Ks0205_Keyestudio_RC522_Sensor
///
/// MFRC522 Protocol: ISO14443A (13.56 MHz RFID)
///
/// 輪巡時序 (RST 等待、REQA 逾時、SPI 時脈…) 由 [RfidTimingConfig] 控制，
/// 可透過 `rfid_timing.json` 或環境變數調整，詳見 documents/RFID_TIMING_TUNING.md。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../interfaces/rfid_reader.dart';
import '../models/rfid_models.dart';
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
/// 實際的 GPIO/SPI 操作在 background isolate 執行，避免卡住 UI。
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
    map['估計無卡一輪'] = '約 ${load.config.estimateNoCardScanMs(_configs.length)} ms';
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

  Future<RfidTimingLoadResult> _ensureTiming() async {
    final cached = _timingLoad;
    if (cached != null) return cached;

    var path = _timingFilePath;
    if (path == null) {
      try {
        final directory = await getApplicationDocumentsDirectory();
        path = '${directory.path}${Platform.pathSeparator}'
            '${RfidTimingConfig.defaultFileName}';
      } catch (e) {
        debugPrint('⚠ 無法取得文件目錄，改用預設路徑: $e');
        path = RfidTimingConfig.defaultFilePath();
      }
    }

    final load = await RfidTimingConfig.load(filePath: path);
    _timingLoad = load;
    debugPrint('RFID 時序設定: ${load.sourceDescription}');
    debugPrint('RFID 時序設定值: ${load.config.toJson()}');
    return load;
  }

  @override
  Future<List<RFIDReading>> scanAll() async {
    debugPrint('Starting async scan of ${_configs.length} readers...');
    final stopwatch = Stopwatch()..start();

    try {
      final load = await _ensureTiming();

      // Convert configs to serializable format for isolate
      final message = <String, dynamic>{
        'configs': [
          for (var i = 0; i < _configs.length; i++)
            _configs[i].toReaderConfig(i + 1).toJson(),
        ],
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
