import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/services/rfid_optimizer.dart';
import 'package:smart_bite/services/rfid_polling_service.dart';
import 'package:smart_bite/services/rfid_timing_config.dart';
import 'package:smart_bite/services/simple_mfrc522.dart';

/// 模擬一顆讀卡機：每個參數有自己的門檻，低於門檻就讀不到卡片
class FakeReaderModel {
  final int minRst;
  final int minAntenna;
  final int minReqaTimeout;
  final int minAttempts;

  /// RST 拉高後的就緒時間；null 代表 VersionReg 永遠讀不到
  final int? readyMs;

  /// 各 SPI 時脈的讀寫錯誤次數
  final Map<int, int> errorsBySpeed;

  /// 額外的偶發失敗條件 (第幾次掃描、當時的時序)
  final bool Function(int scanIndex, RfidTimingConfig timing)? flaky;

  const FakeReaderModel({
    this.minRst = 0,
    this.minAntenna = 0,
    this.minReqaTimeout = 0,
    this.minAttempts = 1,
    this.readyMs = 2,
    this.errorsBySpeed = const {},
    this.flaky,
  });
}

class FakeRunner implements RfidOptimizerRunner {
  final Map<String, FakeReaderModel> models;
  int scans = 0;
  int probeCalls = 0;
  int? openedSpeed;
  bool sessionOpen = false;
  final List<RfidTimingConfig> scanned = [];

  FakeRunner(this.models);

  @override
  List<String> get deviceIds => models.keys.toList()..sort();

  @override
  Future<List<LinkProbeResult>> probeLinks(
    int spiSpeedHz, {
    required int samples,
  }) async {
    probeCalls++;
    return [
      for (final entry in models.entries)
        LinkProbeResult(
          deviceId: entry.key,
          timeToReadyMs: entry.value.readyMs,
          version: entry.value.readyMs == null ? 0x00 : 0x92,
          samples: entry.value.readyMs == null ? 0 : samples * 2,
          mismatches: entry.value.errorsBySpeed[spiSpeedHz] ?? 0,
          elapsedMs: 1,
        ),
    ];
  }

  @override
  Future<void> openSession(int spiSpeedHz) async {
    openedSpeed = spiSpeedHz;
    sessionOpen = true;
  }

  @override
  Future<ScanCycleResult> scan(RfidTimingConfig timing) async {
    if (!sessionOpen) throw StateError('session not open');
    scans++;
    scanned.add(timing);
    final readers = <String, ReaderScanResult>{};
    for (final entry in models.entries) {
      final model = entry.value;
      final t = timing.forReader(entry.key);
      final detected = model.readyMs != null &&
          t.rstSettleMs >= model.minRst &&
          t.antennaSettleMs >= model.minAntenna &&
          t.reqaTimeoutMs >= model.minReqaTimeout &&
          t.reqaAttempts >= model.minAttempts &&
          !(model.flaky?.call(scans, t) ?? false);
      readers[entry.key] = ReaderScanResult(
        deviceId: entry.key,
        status: model.readyMs == null
            ? ReaderScanStatus.linkError
            : detected
                ? ReaderScanStatus.card
                : ReaderScanStatus.noCard,
        tagId: detected ? 'A22038F6' : null,
        elapsedMs: 10,
      );
    }
    return ScanCycleResult(readers: readers, totalMs: 70);
  }

  @override
  Future<void> closeSession() async {
    sessionOpen = false;
  }
}

/// 測試用的小輪數，邏輯跟預設值一樣
const testOptions = RfidOptimizerOptions(
  sweepRounds: 3,
  verifyRounds: 8,
  linkSamples: 10,
);

void main() {
  group('RfidOptimizer', () {
    test('每顆讀卡機各自收斂到門檻以上再加一階餘裕', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(
          minRst: 10,
          minAntenna: 0,
          minReqaTimeout: 5,
          minAttempts: 1,
          readyMs: 2,
        ),
        '07': const FakeReaderModel(
          minRst: 20,
          minAntenna: 10,
          minReqaTimeout: 10,
          minAttempts: 2,
          readyMs: 5,
        ),
      });
      final progress = <OptimizerProgress>[];
      final optimizer = RfidOptimizer(
        runner,
        options: testOptions,
        onProgress: progress.add,
      );

      final result = await optimizer.run(base: RfidTimingConfig.defaults);

      expect(result.cancelled, isFalse);
      expect(result.allStable, isTrue);
      expect(result.config.spiSpeedHz, 1000000);
      expect(runner.openedSpeed, 1000000);
      expect(runner.sessionOpen, isFalse);

      // 01：就緒 2 ms → 下限 10；最小可過 10 → 餘裕一階 15
      final r01 = result.config.forReader('01');
      expect(r01.rstSettleMs, 15);
      expect(r01.antennaSettleMs, 2); // 0 可過 → 餘裕 2
      expect(r01.reqaTimeoutMs, 10); // 5 可過 → 餘裕 10
      expect(r01.reqaAttempts, 1); // 次數不加餘裕

      // 07：就緒 5 ms → 下限 15；20 可過、15 不行 → 餘裕 30
      final r07 = result.config.forReader('07');
      expect(r07.rstSettleMs, 30);
      expect(r07.antennaSettleMs, 20); // 10 可過、5 不行 → 餘裕 20
      expect(r07.reqaTimeoutMs, 15); // 10 可過、5 不行 → 餘裕 15
      expect(r07.reqaAttempts, 2);

      // 兩顆都比原本快
      expect(result.estimatedNoCardMsAfter,
          lessThan(result.estimatedNoCardMsBefore));
      expect(result.estimatedAllCardsMsAfter,
          lessThan(result.estimatedAllCardsMsBefore));
      expect(result.readers['01']!.verifyHits, testOptions.verifyRounds);
      expect(result.readers['07']!.timeToReadyMs, 5);
      expect(result.notes.join('\n'), contains('估計一輪'));

      // 進度：有回報、最後是完成、整體進度單調不減
      expect(progress, isNotEmpty);
      expect(progress.last.stage, OptimizerStage.done);
      expect(progress.last.fraction, 1);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].overallDone,
            greaterThanOrEqualTo(progress[i - 1].overallDone));
      }
      expect(result.roundsRun, runner.scans);
    });

    test('某顆在 1 MHz 有錯誤時整體降到 500 kHz', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(),
        '03': const FakeReaderModel(errorsBySpeed: {1000000: 3}),
      });
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);

      expect(result.config.spiSpeedHz, 500000);
      expect(runner.openedSpeed, 500000);
      expect(result.linkMeasurements.length, 2 * 3);
      expect(result.notes.join('\n'), contains('500000'));
    });

    test('最保守的值都讀不到的讀卡機標為不穩定並維持原設定，其他照常', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 10),
        '05': const FakeReaderModel(minRst: 999),
      });
      const base = RfidTimingConfig(rstSettleMs: 40);
      final result =
          await RfidOptimizer(runner, options: testOptions).run(base: base);

      expect(result.readers['05']!.stable, isFalse);
      expect(result.readers['05']!.note, contains('卡片'));
      // 放寬到升階清單的頂 (RST 500) 仍讀不到才放棄
      expect(result.readers['05']!.note, contains('RST 500'));
      expect(result.readers['05']!.values['rstSettleMs'], 40);
      expect(result.config.readerOverrides.containsKey('05'), isFalse);
      expect(result.readers['01']!.stable, isTrue);
      expect(result.config.forReader('01').rstSettleMs, 15);
      expect(result.unstableReaderIds, ['05']);
      expect(result.allStable, isFalse);
      expect(result.notes.join('\n'), contains('放寬'));
    });

    test('base 既有的覆寫會保留：不穩定的讀卡機、沒掃描的欄位、沒接的讀卡機都不動', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 10),
        '05': const FakeReaderModel(minRst: 999),
      });
      const base = RfidTimingConfig(
        readerOverrides: {
          '01': {'readerRetries': 3, 'commDeadlineMs': 60},
          '05': {'rstSettleMs': 80, 'readerRetries': 3},
          '09': {'antennaSettleMs': 7},
        },
      );
      final result =
          await RfidOptimizer(runner, options: testOptions).run(base: base);

      // 01 穩定：掃描過的四個參數蓋上去，其他欄位保留
      final o01 = result.config.readerOverrides['01']!;
      expect(o01['readerRetries'], 3);
      expect(o01['commDeadlineMs'], 60);
      expect(o01['rstSettleMs'], 15);
      expect(o01.containsKey('linkCheckTimeoutMs'), isFalse);
      // 05 不穩定：手動設的覆寫原封不動 (文件說的「維持原設定」)
      expect(result.config.readerOverrides['05'], {
        'rstSettleMs': 80,
        'readerRetries': 3,
      });
      expect(result.readers['05']!.values['rstSettleMs'], 80);
      // 09 沒接在這台機器上，也不能被清掉
      expect(result.config.readerOverrides['09'], {'antennaSettleMs': 7});
      // 最終設定的量測用欄位還原成 base 的值
      expect(result.config.forReader('01').linkCheckTimeoutMs,
          base.linkCheckTimeoutMs);
      expect(result.config.forReader('01').readerRetries, 3);
    });

    test('量測時關掉連線檢查保險與重新上電重讀，命中只算沒有重讀的那輪', () async {
      final runner = FakeRunner({'01': const FakeReaderModel(minRst: 10)});
      const base = RfidTimingConfig(
        linkCheckTimeoutMs: 80,
        readerRetries: 2,
        readerOverrides: {
          '01': {'readerRetries': 3},
        },
      );
      final result =
          await RfidOptimizer(runner, options: testOptions).run(base: base);

      expect(runner.scanned, isNotEmpty);
      for (final timing in runner.scanned) {
        final t = timing.forReader('01');
        expect(t.linkCheckTimeoutMs, 0);
        expect(t.readerRetries, 0);
      }
      final after = result.config.forReader('01');
      expect(after.linkCheckTimeoutMs, 80);
      expect(after.readerRetries, 3);
      expect(result.config.readerOverrides['01']!.containsKey('readerRetries'),
          isTrue);
      expect(
        result.config.readerOverrides['01']!.containsKey('linkCheckTimeoutMs'),
        isFalse,
      );
    });

    test('靠重新上電重讀才讀到的那輪不算命中', () async {
      // 假讀卡機：每次都要重讀一次才讀到 → 掃描時全部不算命中 → 全部不穩定
      final runner = _RereadRunner({'01': const FakeReaderModel()});
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);
      expect(result.allStable, isFalse);
      expect(result.config, RfidTimingConfig.defaults);
    });

    test('搜尋起點是目前生效的值：手動調大過的讀卡機不會被拿較小的值當起點', () async {
      // 07 需要 RST 70 ms；目前設定 80 (比候選最大值 50 大)，起點就是 80
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 10),
        '07': const FakeReaderModel(minRst: 70),
      });
      const base = RfidTimingConfig(
        readerOverrides: {
          '07': {'rstSettleMs': 80},
        },
      );
      final progress = <OptimizerProgress>[];
      final result = await RfidOptimizer(
        runner,
        options: testOptions,
        onProgress: progress.add,
      ).run(base: base);

      expect(result.allStable, isTrue);
      // 80 可過、50 不行 → 維持 80 (餘裕不會超過起點)
      expect(result.config.forReader('07').rstSettleMs, 80);
      expect(result.config.forReader('01').rstSettleMs, 15);
      // 07 從頭到尾沒有用比 80 小以外、比 50 大的奇怪值；第一輪就是 80
      final firstScan = runner.scanned.first.forReader('07');
      expect(firstScan.rstSettleMs, 80);
      expect(result.notes.join('\n'), isNot(contains('放寬')));
      // 進度單調不減、最後 100%
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i].overallDone,
            greaterThanOrEqualTo(progress[i - 1].overallDone));
      }
      expect(progress.last.fraction, 1);
    });

    test('起點讀不到時往上放寬，找得到「需要更長等待」的解', () async {
      // 03 需要 RST 150 ms：50 不行 → 放寬到 100 不行 → 200 可以
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 10),
        '03': const FakeReaderModel(minRst: 150),
      });
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);

      expect(result.allStable, isTrue);
      final r03 = result.config.forReader('03');
      // rst: 200 可過、100 不行 → 維持 200 (餘裕不超過放寬後的起點)
      expect(r03.rstSettleMs, 200);
      // 其他三個參數被一起放寬後，掃描階段再各自往下走回來
      expect(r03.antennaSettleMs, 2);
      expect(r03.reqaTimeoutMs, 10);
      expect(r03.reqaAttempts, 1);
      // 01 不受影響
      expect(result.config.forReader('01').rstSettleMs, 15);
      expect(result.notes.join('\n'), contains('放寬'));
      expect(result.readers['03']!.note, isNull);
    });

    test('連線檢測讀不到 VersionReg 的讀卡機不參與搜尋', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(),
        '06': const FakeReaderModel(readyMs: null),
      });
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);

      expect(result.readers['06']!.stable, isFalse);
      expect(result.readers['06']!.note, contains('VersionReg'));
      expect(result.readers['01']!.stable, isTrue);
      // 掃描時 06 沒有覆寫值
      for (final timing in runner.scanned) {
        expect(timing.readerOverrides.containsKey('06'), isFalse);
      }
    });

    test('取消時回傳原設定並標記 cancelled', () async {
      final runner = FakeRunner({'01': const FakeReaderModel()});
      final optimizer = RfidOptimizer(
        runner,
        options: testOptions,
        shouldCancel: () => runner.scans >= 3,
      );
      const base = RfidTimingConfig(rstSettleMs: 33);
      final result = await optimizer.run(base: base);

      expect(result.cancelled, isTrue);
      expect(result.config, base);
      expect(result.notes, contains('已取消'));
      expect(runner.scans, lessThanOrEqualTo(4));
      expect(runner.sessionOpen, isFalse);
    });

    test('驗證階段漏讀會放寬一階重驗', () async {
      // 02 在 REQA 只試 1 次時偶爾漏讀 (每 7 次掃描漏一次)
      final runner = FakeRunner({
        '02': FakeReaderModel(
          flaky: (index, t) => t.reqaAttempts == 1 && index % 7 == 0,
        ),
      });
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);

      expect(result.readers['02']!.stable, isTrue);
      expect(result.config.forReader('02').reqaAttempts, 2);
      expect(result.readers['02']!.verifyHits, testOptions.verifyRounds);
    });

    test('skipLinkStage 時不做連線檢測，時脈維持原設定', () async {
      final runner = FakeRunner({'01': const FakeReaderModel()});
      final result = await RfidOptimizer(
        runner,
        options: testOptions.copyWith(skipLinkStage: true),
      ).run(base: const RfidTimingConfig(spiSpeedHz: 250000));

      expect(runner.probeCalls, 0);
      expect(result.config.spiSpeedHz, 250000);
      expect(runner.openedSpeed, 250000);
      expect(result.linkMeasurements, isEmpty);
      // 沒有就緒時間 → rst 下限 10
      expect(result.config.forReader('01').rstSettleMs, 15);
    });

    test('全部讀卡機都讀不到卡片時不改設定', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 999),
        '02': const FakeReaderModel(minRst: 999),
      });
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);

      expect(result.cancelled, isFalse);
      expect(result.config, RfidTimingConfig.defaults);
      expect(result.allStable, isFalse);
      expect(result.notes.join('\n'), contains('卡片'));
    });
  });

  group('RfidOptimizerOptions', () {
    test('validated 排序、去重、修正輪數', () {
      const options = RfidOptimizerOptions(
        rstCandidates: [10, 50, 10, 20],
        reqaTimeoutCandidates: [0, 5, 25],
        sweepRounds: 0,
        verifyRounds: -3,
        marginSteps: -1,
      );
      final fixed = options.validated();
      expect(fixed.rstCandidates, [50, 20, 10]);
      expect(fixed.reqaTimeoutCandidates, [25, 5]);
      expect(fixed.sweepRounds, 1);
      expect(fixed.verifyRounds, 1);
      expect(fixed.marginSteps, 0);
    });

    test('升階值由小到大、去重，空清單代表不放寬', () {
      const options = RfidOptimizerOptions(
        rstEscalation: [500, 100, 100, 200],
        reqaAttemptEscalation: [0, 4, 3],
        antennaEscalation: [],
      );
      final fixed = options.validated();
      expect(fixed.rstEscalation, [100, 200, 500]);
      expect(fixed.reqaAttemptEscalation, [3, 4]);
      expect(fixed.antennaEscalation, isEmpty);
      expect(fixed.maxEscalationSteps, 3);
      expect(RfidOptimizerOptions.defaults.maxEscalationSteps, 3);
    });

    test('不放寬時，起點讀不到的讀卡機直接標為不穩定', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 10),
        '03': const FakeReaderModel(minRst: 150),
      });
      final result = await RfidOptimizer(
        runner,
        options: testOptions.copyWith(
          rstEscalation: [],
          antennaEscalation: [],
          reqaTimeoutEscalation: [],
          reqaAttemptEscalation: [],
        ),
      ).run(base: RfidTimingConfig.defaults);
      expect(result.readers['03']!.stable, isFalse);
      expect(result.readers['03']!.note, contains('RST 50'));
      expect(result.readers['01']!.stable, isTrue);
    });

    test('JSON 往返', () {
      const options = RfidOptimizerOptions(
        spiSpeeds: [500000],
        sweepRounds: 7,
        skipLinkStage: true,
      );
      final restored = RfidOptimizerOptions.fromJson(options.toJson());
      expect(restored.spiSpeeds, [500000]);
      expect(restored.sweepRounds, 7);
      expect(restored.skipLinkStage, isTrue);
      expect(restored.rstCandidates, options.rstCandidates);
      expect(restored.rstEscalation, options.rstEscalation);
      expect(restored.reqaAttemptEscalation, options.reqaAttemptEscalation);
    });

    test('maxSweepRounds 是每個參數一般階數的總和乘輪數 (不含升階)', () {
      const options = RfidOptimizerOptions.defaults;
      // (5-1) + (5-1) + (4-1) + (2-1) = 12 階 × 5 輪
      expect(options.maxSweepRounds, 60);
    });
  });

  group('OptimizationResult / OptimizerProgress JSON', () {
    test('結果往返', () async {
      final runner = FakeRunner({
        '01': const FakeReaderModel(minRst: 10),
        '02': const FakeReaderModel(readyMs: null),
      });
      final result = await RfidOptimizer(runner, options: testOptions)
          .run(base: RfidTimingConfig.defaults);

      final restored = OptimizationResult.fromJson(result.toJson());
      expect(restored.config, result.config);
      expect(restored.before, result.before);
      expect(restored.readers.keys, result.readers.keys);
      expect(restored.readers['01']!.values, result.readers['01']!.values);
      expect(restored.readers['02']!.stable, isFalse);
      expect(restored.readers['02']!.note, result.readers['02']!.note);
      expect(restored.linkMeasurements.length, result.linkMeasurements.length);
      expect(restored.notes, result.notes);
      expect(restored.roundsRun, result.roundsRun);
      expect(restored.cancelled, isFalse);
    });

    test('進度往返', () {
      const progress = OptimizerProgress(
        stage: OptimizerStage.sweep,
        message: '往下試',
        parameter: 'rstSettleMs',
        round: 2,
        totalRounds: 5,
        overallDone: 10,
        overallTotal: 40,
        candidates: {'01': 20, '07': 30},
        elapsedMs: 1234,
      );
      final restored = OptimizerProgress.fromJson(progress.toJson());
      expect(restored.stage, OptimizerStage.sweep);
      expect(restored.parameter, 'rstSettleMs');
      expect(restored.round, 2);
      expect(restored.candidates, {'01': 20, '07': 30});
      expect(restored.fraction, 0.25);
    });
  });
}

/// 每一輪都要重新上電重讀一次才讀到卡片的假硬體
class _RereadRunner extends FakeRunner {
  _RereadRunner(super.models);

  @override
  Future<ScanCycleResult> scan(RfidTimingConfig timing) async {
    final cycle = await super.scan(timing);
    return ScanCycleResult(
      totalMs: cycle.totalMs,
      readers: {
        for (final entry in cycle.readers.entries)
          entry.key: entry.value.copyWith(rereads: 1),
      },
    );
  }
}
