/// RFID 輪巡服務 (純 Dart，不依賴 Flutter，CLI 校正工具也共用)
///
/// 一輪掃描：
/// 1. 打開所有 RST 腳並拉低，七顆全部進 hard power-down
/// 2. 每個 SPI bus 只開一次 (舊版每顆都重開 /dev/spidev0.0)
/// 3. 依序把每顆叫醒、讀卡、再關掉 (見 [SimpleMFRC522.scanOnce])
/// 4. 釋放 GPIO 與 SPI
///
/// 舊版每顆固定睡 500 ms 三次 (init 後、reset 後、dispose 時)，
/// 七顆一輪約 12 秒；新版的等待值全部來自 [RfidTimingConfig]。
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

/// 依序輪巡多顆 RC522
class RFIDPollingService {
  final RfidTimingConfig timing;
  final RfidLog? log;

  RFIDPollingService({RfidTimingConfig? timing, this.log})
      : timing = (timing ?? RfidTimingConfig.defaults).validated();

  /// 對 [configs] 的每一顆各讀一次
  Future<ScanCycleResult> performOneLoopCycles(
    List<ReaderConfig> configs,
  ) async {
    final stopwatch = Stopwatch()..start();
    final results = <String, ReaderScanResult>{};
    final buses = <int, SPI>{};
    final lines = <GpioResetLine>[];
    final readers = <SimpleMFRC522>[];

    try {
      // 先把所有 RST 拉低，確保 bus 上一次只有一顆醒著
      for (final config in configs) {
        final line = GpioResetLine(config.rstPin);
        try {
          line.open();
        } catch (e) {
          _log('${config.deviceId}: 無法開啟 RST GPIO${config.rstPin}: $e');
          results[config.deviceId] = ReaderScanResult(
            deviceId: config.deviceId,
            status: ReaderScanStatus.error,
            error: 'GPIO${config.rstPin}: $e',
          );
          continue;
        }
        lines.add(line);

        final spi = buses.putIfAbsent(
          config.spiNum,
          () => SPI(config.spiNum, 0, SPImode.mode0, timing.spiSpeedHz),
        );
        readers.add(SimpleMFRC522(
          deviceNum: config.deviceNum,
          resetLine: line,
          transport: SpiMfrc522Transport(spi),
          timing: timing,
        ));
      }

      for (final reader in readers) {
        final result = await reader.scanOnce();
        results[reader.deviceId] = result;
        _log('${reader.deviceId}: ${result.summary}');
        if (timing.interReaderGapMs > 0) {
          await Future<void>.delayed(
            Duration(milliseconds: timing.interReaderGapMs),
          );
        }
      }
    } finally {
      for (final line in lines) {
        try {
          line.low();
          line.dispose();
        } catch (e) {
          _log('釋放 RST GPIO${line.pin} 失敗: $e');
        }
      }
      for (final spi in buses.values) {
        try {
          spi.dispose();
        } catch (e) {
          _log('關閉 SPI 失敗: $e');
        }
      }
      if (timing.postScanSettleMs > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: timing.postScanSettleMs),
        );
      }
    }

    final cycle = ScanCycleResult(
      readers: results,
      totalMs: stopwatch.elapsedMilliseconds,
    );
    _log('一輪掃描完成: $cycle');
    return cycle;
  }

  void _log(String message) => log?.call(message);

  /// 保留給舊呼叫端；本服務沒有跨輪次持有的資源
  void dispose() {}
}
