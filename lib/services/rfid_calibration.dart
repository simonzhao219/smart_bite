/// RFID 輪巡校正：從量測結果推薦時序設定 (純 Dart，單元測試可覆蓋)
///
/// 實際的硬體量測在 scripts/rfid_calibrate.dart，這裡只放不碰硬體的邏輯：
/// - 從各 SPI 時脈的連線品質選出可用的最高時脈
/// - 從各讀卡機的「RST 拉高到可讀」時間推薦 rstSettleMs
/// - 把量測結果排成表格
library;

import 'rfid_polling_service.dart';
import 'rfid_timing_config.dart';
import 'simple_mfrc522.dart';

/// 一顆讀卡機在某個 SPI 時脈下的連線量測
class LinkMeasurement {
  final int spiSpeedHz;
  final LinkProbeResult probe;

  const LinkMeasurement({required this.spiSpeedHz, required this.probe});

  Map<String, dynamic> toJson() => {
        'spiSpeedHz': spiSpeedHz,
        'probe': probe.toJson(),
      };

  factory LinkMeasurement.fromJson(Map<String, dynamic> json) =>
      LinkMeasurement(
        spiSpeedHz: (json['spiSpeedHz'] as num).toInt(),
        probe: LinkProbeResult.fromJson(
          Map<String, dynamic>.from(json['probe'] as Map),
        ),
      );
}

/// 推薦結果
class CalibrationRecommendation {
  final RfidTimingConfig config;

  /// 推薦的理由與警告，給人看的
  final List<String> notes;

  /// 是否每顆讀卡機都至少在一個時脈下就緒
  final bool allReadersReady;

  const CalibrationRecommendation({
    required this.config,
    required this.notes,
    required this.allReadersReady,
  });
}

class RfidCalibration {
  /// rstSettleMs 推薦值的下限 (ms)。量到再快也不建議低於這個值。
  static const int minRstSettleMs = 10;

  /// rstSettleMs 推薦值 = 量到的最大就緒時間 × [rstSettleMultiplier] + [rstSettleMarginMs]
  static const int rstSettleMultiplier = 2;
  static const int rstSettleMarginMs = 5;

  /// 從連線量測推薦設定。
  ///
  /// - `spiSpeedHz`：所有讀卡機都零錯誤的最高時脈；都有錯誤時取總錯誤數最少的時脈
  /// - `rstSettleMs`：所有讀卡機就緒時間的最大值 × 2 + 5 ms，最低 10 ms，
  ///   而且不會比 [base] 目前的值更長 (校正只往下修，保守值仍以 datasheet 為準)
  static CalibrationRecommendation recommend({
    required RfidTimingConfig base,
    required List<LinkMeasurement> measurements,
  }) {
    final notes = <String>[];
    if (measurements.isEmpty) {
      notes.add('沒有量測資料，維持目前設定');
      return CalibrationRecommendation(
        config: base,
        notes: notes,
        allReadersReady: false,
      );
    }

    // 依時脈分組
    final bySpeed = <int, List<LinkProbeResult>>{};
    for (final m in measurements) {
      bySpeed.putIfAbsent(m.spiSpeedHz, () => []).add(m.probe);
    }

    // 每顆讀卡機是否至少在某個時脈下就緒
    final readerIds = measurements.map((m) => m.probe.deviceId).toSet().toList()
      ..sort();
    final neverReady = readerIds
        .where((id) => measurements
            .where((m) => m.probe.deviceId == id)
            .every((m) => !m.probe.ready))
        .toList();
    if (neverReady.isNotEmpty) {
      notes.add('讀卡機 ${neverReady.join('、')} 在所有時脈下都讀不到 VersionReg，'
          '請檢查 RST、3.3V、GND 與 SPI 接線');
    }

    // 選時脈：所有就緒的讀卡機都零錯誤的最高時脈
    final speeds = bySpeed.keys.toList()..sort((a, b) => b.compareTo(a));
    int? chosenSpeed;
    for (final speed in speeds) {
      final probes = bySpeed[speed]!;
      final allClean = probes.every((p) => p.clean);
      if (allClean) {
        chosenSpeed = speed;
        break;
      }
    }
    if (chosenSpeed == null) {
      // 沒有全乾淨的時脈：取錯誤總數最少的 (同分取較高時脈)
      var bestErrors = -1;
      for (final speed in speeds) {
        final probes = bySpeed[speed]!;
        final errors = probes.fold<int>(
          0,
          (sum, p) => sum + (p.ready ? p.mismatches : p.samples + 1),
        );
        if (bestErrors < 0 || errors < bestErrors) {
          bestErrors = errors;
          chosenSpeed = speed;
        }
      }
      notes.add('沒有任何 SPI 時脈是全部零錯誤，先取錯誤最少的 $chosenSpeed Hz；'
          '建議縮短或改善 SCK/MISO/MOSI 走線後再校正一次');
    } else {
      notes.add('SPI 時脈 $chosenSpeed Hz：所有讀卡機讀寫零錯誤');
    }

    // rstSettleMs：就緒時間最大值 × 2 + 5，最低 10，不超過目前值
    final readyTimes = measurements
        .where((m) => m.probe.ready)
        .map((m) => m.probe.timeToReadyMs!)
        .toList();
    var rstSettleMs = base.rstSettleMs;
    if (readyTimes.isNotEmpty) {
      final maxReady = readyTimes.reduce((a, b) => a > b ? a : b);
      var suggested = maxReady * rstSettleMultiplier + rstSettleMarginMs;
      if (suggested < minRstSettleMs) suggested = minRstSettleMs;
      if (suggested < base.rstSettleMs) {
        rstSettleMs = suggested;
        notes.add('RST 拉高後最慢 $maxReady ms 就緒，rstSettleMs 由 '
            '${base.rstSettleMs} 下修為 $rstSettleMs');
      } else {
        notes.add('RST 拉高後最慢 $maxReady ms 就緒，維持 rstSettleMs = '
            '${base.rstSettleMs}');
      }
    }

    final config = base
        .copyWith(spiSpeedHz: chosenSpeed, rstSettleMs: rstSettleMs)
        .validated();

    return CalibrationRecommendation(
      config: config,
      notes: notes,
      allReadersReady: neverReady.isEmpty,
    );
  }

  /// 連線量測表格
  static String formatLinkTable(List<LinkMeasurement> measurements) {
    if (measurements.isEmpty) return '(沒有量測資料)';
    final buffer = StringBuffer();
    buffer.writeln(
      '${'讀卡機'.padRight(6)} ${'SPI Hz'.padLeft(9)} ${'就緒 ms'.padLeft(8)} '
      '${'VersionReg'.padRight(24)} ${'錯誤/樣本'.padLeft(10)} 結果',
    );
    final sorted = [...measurements]..sort((a, b) {
        final byId = a.probe.deviceId.compareTo(b.probe.deviceId);
        return byId != 0 ? byId : b.spiSpeedHz.compareTo(a.spiSpeedHz);
      });
    for (final m in sorted) {
      final p = m.probe;
      final verdict = !p.ready
          ? '未就緒'
          : p.clean
              ? 'OK'
              : '錯誤率 ${(p.errorRate * 100).toStringAsFixed(1)}%';
      buffer.writeln(
        '${p.deviceId.padRight(6)} ${m.spiSpeedHz.toString().padLeft(9)} '
        '${(p.timeToReadyMs?.toString() ?? '-').padLeft(8)} '
        '${_versionText(p.version).padRight(24)} '
        '${'${p.mismatches}/${p.samples}'.padLeft(10)} $verdict',
      );
    }
    return buffer.toString();
  }

  /// 多輪掃描的統計摘要
  static String formatBenchSummary(List<ScanCycleResult> cycles) {
    if (cycles.isEmpty) return '(沒有掃描資料)';
    final buffer = StringBuffer();
    final totals = cycles.map((c) => c.totalMs).toList();
    final avg = totals.reduce((a, b) => a + b) / totals.length;
    final min = totals.reduce((a, b) => a < b ? a : b);
    final max = totals.reduce((a, b) => a > b ? a : b);
    buffer.writeln('共 ${cycles.length} 輪：平均 ${avg.toStringAsFixed(0)} ms，'
        '最快 $min ms，最慢 $max ms');

    final readerIds =
        <String>{for (final c in cycles) ...c.readers.keys}.toList()..sort();
    buffer.writeln(
      '${'讀卡機'.padRight(6)} ${'有卡'.padLeft(5)} ${'沒卡'.padLeft(5)} '
      '${'線路異常'.padLeft(8)} ${'無回應'.padLeft(6)} ${'錯誤'.padLeft(5)} '
      '${'平均 ms'.padLeft(8)} ${'最慢 ms'.padLeft(8)}',
    );
    for (final id in readerIds) {
      final results = cycles
          .map((c) => c.readers[id])
          .whereType<ReaderScanResult>()
          .toList();
      int count(ReaderScanStatus status) =>
          results.where((r) => r.status == status).length;
      final elapsed = results.map((r) => r.elapsedMs).toList();
      final avgMs = elapsed.isEmpty
          ? 0
          : elapsed.reduce((a, b) => a + b) / elapsed.length;
      final maxMs =
          elapsed.isEmpty ? 0 : elapsed.reduce((a, b) => a > b ? a : b);
      buffer.writeln(
        '${id.padRight(6)} ${count(ReaderScanStatus.card).toString().padLeft(5)} '
        '${count(ReaderScanStatus.noCard).toString().padLeft(5)} '
        '${count(ReaderScanStatus.linkError).toString().padLeft(8)} '
        '${count(ReaderScanStatus.commTimeout).toString().padLeft(6)} '
        '${count(ReaderScanStatus.error).toString().padLeft(5)} '
        '${avgMs.toStringAsFixed(0).padLeft(8)} ${maxMs.toString().padLeft(8)}',
      );
    }
    return buffer.toString();
  }

  static String _versionText(int version) =>
      '0x${version.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}
