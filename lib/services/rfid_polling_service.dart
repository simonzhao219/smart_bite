/// RFID 輪巡服務 (純 Dart，不依賴 Flutter，CLI 校正工具也共用)
///
/// 一輪掃描：
/// 1. 打開所有 RST 腳並拉低，七顆全部進 hard power-down
/// 2. 每個 SPI bus 只開一次 (舊版每顆都重開 /dev/spidev0.0)
/// 3. 依序把每顆叫醒、讀卡、再關掉 (見 [SimpleMFRC522.scanOnce])
/// 4. 釋放 GPIO 與 SPI
///
/// [RfidScanSession] 把 GPIO 與 SPI 保持開啟，可以連續跑很多輪
/// (校正與最佳化用)；[RFIDPollingService.performOneLoopCycles] 則是
/// 開一次、掃一輪、關掉，給 app 的按鈕觸發掃描用。
///
/// 舊版每顆固定睡 500 ms 三次 (init 後、reset 後、dispose 時)，
/// 七顆一輪約 12 秒；新版的等待值全部來自 [RfidTimingConfig]，
/// 而且每顆可以有自己的覆寫值 ([RfidTimingConfig.forReader])。
library;

import 'dart:async';

import 'package:dart_periphery/dart_periphery.dart';

import '../models/rfid_models.dart';
import 'mfrc522.dart';
import 'rfid_timing_config.dart';
import 'simple_mfrc522.dart';

typedef RfidLog = void Function(String message);

/// 一輪掃描的結果
class ScanCycleResult {
  /// deviceId → 結果
  final Map<String, ReaderScanResult> readers;

  /// 整輪花的時間 (ms)
  final int totalMs;

  const ScanCycleResult({required this.readers, required this.totalMs});

  int get cardCount => readers.values.where((r) => r.hasCard).length;

  /// 線路異常、晶片無回應或發生例外的讀卡機
  List<String> get errorReaderIds =>
      readers.values.where((r) => !r.linkOk).map((r) => r.deviceId).toList()
        ..sort();

  Map<String, dynamic> toJson() => {
        'totalMs': totalMs,
        'readers': {
          for (final entry in readers.entries) entry.key: entry.value.toJson(),
        },
      };

  factory ScanCycleResult.fromJson(Map<String, dynamic> json) {
    final rawReaders = Map<String, dynamic>.from(json['readers'] as Map);
    return ScanCycleResult(
      totalMs: (json['totalMs'] as num?)?.toInt() ?? 0,
      readers: {
        for (final entry in rawReaders.entries)
          entry.key: ReaderScanResult.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
    );
  }

  @override
  String toString() =>
      'ScanCycleResult(${totalMs}ms, $cardCount cards, errors: $errorReaderIds)';
}

/// 把 GPIO 與 SPI 保持開啟的掃描 session，可連續跑多輪。
///
/// SPI 時脈在 [open] 時決定 (用 [timing] 的 `spiSpeedHz`)，
/// 之後 [scanCycle] 傳入的時序只影響等待值與 REQA 設定。
class RfidScanSession {
  final List<ReaderConfig> configs;
  final RfidTimingConfig timing;
  final RfidLog? log;

  final Map<int, SPI> _buses = {};
  final List<GpioResetLine> _lines = [];
  final List<SimpleMFRC522> _readers = [];
  bool _isOpen = false;

  RfidScanSession(
    this.configs, {
    RfidTimingConfig? timing,
    this.log,
  }) : timing = (timing ?? RfidTimingConfig.defaults).validated();

  bool get isOpen => _isOpen;

  List<String> get deviceIds => configs.map((c) => c.deviceId).toList();

  /// 開啟所有 RST (全部拉低) 與 SPI bus。已開啟時不做事。
  ///
  /// 任何一支 RST 打不開 (GPIO busy、權限) 就整輪失敗並指名腳位：那顆的 RST 沒被
  /// 拉低時可能是高的 (GPIO4 開機預設上拉)，晶片醒著搶 MISO，其他六顆全都會讀不到，
  /// 繼續掃只會回報六條線「線路異常」，錯的方向。
  void open() {
    if (_isOpen) return;
    try {
      // 先把所有 RST 拉低，確保 bus 上一次只有一顆醒著
      for (final config in configs) {
        final line = GpioResetLine(config.rstPin);
        try {
          line.open();
        } catch (e) {
          _log('${config.deviceId}: 無法開啟 RST GPIO${config.rstPin}: $e');
          throw StateError(
            '讀卡機 ${config.deviceId} 的 RST GPIO${config.rstPin} 打不開 ($e)。'
            '這支腳沒拉低時其他讀卡機也讀不到，整輪掃描中止；'
            '請關閉其他使用 GPIO 的程式或執行 scripts/gpio_cleanup.sh',
          );
        }
        _lines.add(line);

        final spi = _buses.putIfAbsent(
          config.spiNum,
          () => SPI(config.spiNum, 0, SPImode.mode0, timing.spiSpeedHz),
        );
        _readers.add(SimpleMFRC522(
          deviceNum: config.deviceNum,
          resetLine: line,
          transport: SpiMfrc522Transport(spi),
          timing: timing.forReader(config.deviceId),
        ));
      }
      _isOpen = true;
    } catch (e) {
      close();
      rethrow;
    }
  }

  /// 對每一顆各讀一次。[timing] 不給就用 session 的設定。
  Future<ScanCycleResult> scanCycle({RfidTimingConfig? timing}) async {
    if (!_isOpen) open();
    final effective = (timing ?? this.timing).validated();
    final stopwatch = Stopwatch()..start();
    final results = <String, ReaderScanResult>{};

    for (var i = 0; i < _readers.length; i++) {
      final reader = _readers[i];
      final result = await reader.scanOnce(
        timing: effective.forReader(reader.deviceId),
      );
      results[reader.deviceId] = result;
      _log('${reader.deviceId}: ${result.summary}');
      // 顆間間隔只在兩顆之間，最後一顆之後不等
      if (effective.interReaderGapMs > 0 && i < _readers.length - 1) {
        await Future<void>.delayed(
          Duration(milliseconds: effective.interReaderGapMs),
        );
      }
    }

    if (effective.postScanSettleMs > 0) {
      await Future<void>.delayed(
        Duration(milliseconds: effective.postScanSettleMs),
      );
    }

    return ScanCycleResult(
      readers: results,
      totalMs: stopwatch.elapsedMilliseconds,
    );
  }

  /// 量測每顆的連線品質 (見 [SimpleMFRC522.probeLink])
  Future<List<LinkProbeResult>> probeLinks({
    int samples = 200,
    int maxReadyMs = 300,
    Iterable<String>? deviceIds,
  }) async {
    if (!_isOpen) open();
    final wanted = deviceIds?.toSet();
    final results = <LinkProbeResult>[];
    for (final reader in _readers) {
      if (wanted != null && !wanted.contains(reader.deviceId)) continue;
      final probe = await reader.probeLink(
        samples: samples,
        maxReadyMs: maxReadyMs,
      );
      results.add(probe);
      _log('${reader.deviceId}: $probe');
    }
    return results;
  }

  /// RST 全部拉低並釋放 GPIO 與 SPI。可重複呼叫。
  void close() {
    for (final line in _lines) {
      try {
        line.low();
        line.dispose();
      } catch (e) {
        _log('釋放 RST GPIO${line.pin} 失敗: $e');
      }
    }
    _lines.clear();
    _readers.clear();
    for (final spi in _buses.values) {
      try {
        spi.dispose();
      } catch (e) {
        _log('關閉 SPI 失敗: $e');
      }
    }
    _buses.clear();
    _isOpen = false;
  }

  void _log(String message) => log?.call(message);
}

/// 依序輪巡多顆 RC522
class RFIDPollingService {
  final RfidTimingConfig timing;
  final RfidLog? log;

  RFIDPollingService({RfidTimingConfig? timing, this.log})
      : timing = (timing ?? RfidTimingConfig.defaults).validated();

  /// 對 [configs] 的每一顆各讀一次：開啟 session、掃一輪、關閉
  Future<ScanCycleResult> performOneLoopCycles(
    List<ReaderConfig> configs,
  ) async {
    final session = RfidScanSession(configs, timing: timing, log: log);
    try {
      session.open();
      final cycle = await session.scanCycle();
      _log('一輪掃描完成: $cycle');
      return cycle;
    } finally {
      session.close();
    }
  }

  void _log(String message) => log?.call(message);

  /// 保留給舊呼叫端；本服務沒有跨輪次持有的資源
  void dispose() {}
}
