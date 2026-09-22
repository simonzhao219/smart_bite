/// RC522 輪巡自動最佳化 (純 Dart，不依賴 Flutter，CLI 與 app 共用)
///
/// 目標：一輪掃描時間最短，而且七顆讀卡機在驗證輪數內全部 100% 讀到卡片。
/// 測試時七顆都要放上卡片。
///
/// 流程：
/// 1. 連線階段 (不用卡)：各 SPI 時脈量每顆的讀寫錯誤率，取全部零錯誤的最高時脈；
///    量每顆 RST 拉高後的就緒時間，當 `rstSettleMs` 候選值的下限。
/// 2. 確認階段：用最保守的候選值跑幾輪，讀不到卡的讀卡機視為「不穩定」，
///    不參與後面的搜尋 (通常是卡片沒放好或線路問題)。
/// 3. 掃描階段：依序對 `rstSettleMs`、`antennaSettleMs`、`reqaTimeoutMs`、
///    `reqaAttempts` 由大往小試。每顆讀卡機各自有自己的候選值與進度，
///    但同一輪掃描裡七顆各測各的，所以每顆各自搜尋不需要七倍時間。
///    每個候選值跑 N 輪，全中才往下一個更小的值走；取最小可過的值之後再往上
///    加 [RfidOptimizerOptions.marginSteps] 階當安全餘裕。
/// 4. 驗證階段：用最終值跑 M 輪，任何一顆漏讀就把它的參數放寬一階重驗；
///    重驗仍失敗的讀卡機退回原設定並標記。
///
/// 硬體操作透過 [RfidOptimizerRunner] 抽象，單元測試用假物件模擬讀卡機的門檻。
library;

import '../models/rfid_models.dart';
import 'rfid_calibration.dart';
import 'rfid_polling_service.dart';
import 'rfid_timing_config.dart';
import 'simple_mfrc522.dart';

/// 取消用的 token：UI 按取消時呼叫 [cancel]，演算法會在下一輪前停下。
class RfidCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);
}

/// 演算法需要的硬體操作
abstract class RfidOptimizerRunner {
  /// 參與最佳化的讀卡機 deviceId
  List<String> get deviceIds;

  /// 以 [spiSpeedHz] 量測每顆的連線品質 (RST 就緒時間、讀寫錯誤率)
  Future<List<LinkProbeResult>> probeLinks(
    int spiSpeedHz, {
    required int samples,
  });

  /// 以 [spiSpeedHz] 開啟掃描 session，之後的 [scan] 都用它
  Future<void> openSession(int spiSpeedHz);

  /// 用 [timing] 掃一輪 (含每顆的覆寫值)
  Future<ScanCycleResult> scan(RfidTimingConfig timing);

  Future<void> closeSession();
}

/// 真實硬體：透過 [RfidScanSession] 操作 GPIO 與 SPI
class HardwareOptimizerRunner implements RfidOptimizerRunner {
  final List<ReaderConfig> configs;
  final RfidTimingConfig base;
  final RfidLog? log;
  RfidScanSession? _session;

  HardwareOptimizerRunner({
    required this.configs,
    required this.base,
    this.log,
  });

  @override
  List<String> get deviceIds => configs.map((c) => c.deviceId).toList();

  @override
  Future<List<LinkProbeResult>> probeLinks(
    int spiSpeedHz, {
    required int samples,
  }) async {
    await closeSession();
    final session = RfidScanSession(
      configs,
      timing: base.copyWith(spiSpeedHz: spiSpeedHz),
      log: log,
    );
    try {
      session.open();
      return await session.probeLinks(samples: samples);
    } finally {
      session.close();
    }
  }

  @override
  Future<void> openSession(int spiSpeedHz) async {
    await closeSession();
    _session = RfidScanSession(
      configs,
      timing: base.copyWith(spiSpeedHz: spiSpeedHz),
      log: log,
    )..open();
  }

  @override
  Future<ScanCycleResult> scan(RfidTimingConfig timing) {
    final session = _session;
    if (session == null) {
      throw StateError('掃描 session 尚未開啟');
    }
    return session.scanCycle(timing: timing);
  }

  @override
  Future<void> closeSession() async {
    _session?.close();
    _session = null;
  }
}

/// 最佳化的選項：候選值、輪數、餘裕
class RfidOptimizerOptions {
  /// 要測試的 SPI 時脈 (Hz)
  final List<int> spiSpeeds;

  /// 連線檢測每顆每個時脈的讀寫檢查次數
  final int linkSamples;

  /// 各參數的候選值，會由大往小試
  final List<int> rstCandidates;
  final List<int> antennaCandidates;
  final List<int> reqaTimeoutCandidates;
  final List<int> reqaAttemptCandidates;

  /// 掃描階段每個候選值跑幾輪
  final int sweepRounds;

  /// 驗證階段跑幾輪
  final int verifyRounds;

  /// 最小可過的值再往上加幾階當安全餘裕 (不套用在 reqaAttempts)
  final int marginSteps;

  /// 驗證失敗時最多放寬重驗幾次
  final int maxVerifyRetries;

  /// 跳過連線階段 (時脈維持目前設定)
  final bool skipLinkStage;

  const RfidOptimizerOptions({
    this.spiSpeeds = const [1000000, 500000, 250000],
    this.linkSamples = 200,
    this.rstCandidates = const [50, 30, 20, 15, 10],
    this.antennaCandidates = const [20, 10, 5, 2, 0],
    this.reqaTimeoutCandidates = const [25, 15, 10, 5],
    this.reqaAttemptCandidates = const [2, 1],
    this.sweepRounds = 5,
    this.verifyRounds = 20,
    this.marginSteps = 1,
    this.maxVerifyRetries = 2,
    this.skipLinkStage = false,
  });

  static const RfidOptimizerOptions defaults = RfidOptimizerOptions();

  /// 參數掃描順序 (對時間影響大的先)
  static const List<String> sweepOrder = [
    'rstSettleMs',
    'antennaSettleMs',
    'reqaTimeoutMs',
    'reqaAttempts',
  ];

  List<int> candidatesOf(String parameter) {
    switch (parameter) {
      case 'rstSettleMs':
        return rstCandidates;
      case 'antennaSettleMs':
        return antennaCandidates;
      case 'reqaTimeoutMs':
        return reqaTimeoutCandidates;
      case 'reqaAttempts':
        return reqaAttemptCandidates;
      default:
        throw ArgumentError.value(parameter, 'parameter');
    }
  }

  RfidOptimizerOptions copyWith({
    List<int>? spiSpeeds,
    int? linkSamples,
    List<int>? rstCandidates,
    List<int>? antennaCandidates,
    List<int>? reqaTimeoutCandidates,
    List<int>? reqaAttemptCandidates,
    int? sweepRounds,
    int? verifyRounds,
    int? marginSteps,
    int? maxVerifyRetries,
    bool? skipLinkStage,
  }) {
    return RfidOptimizerOptions(
      spiSpeeds: spiSpeeds ?? this.spiSpeeds,
      linkSamples: linkSamples ?? this.linkSamples,
      rstCandidates: rstCandidates ?? this.rstCandidates,
      antennaCandidates: antennaCandidates ?? this.antennaCandidates,
      reqaTimeoutCandidates:
          reqaTimeoutCandidates ?? this.reqaTimeoutCandidates,
      reqaAttemptCandidates:
          reqaAttemptCandidates ?? this.reqaAttemptCandidates,
      sweepRounds: sweepRounds ?? this.sweepRounds,
      verifyRounds: verifyRounds ?? this.verifyRounds,
      marginSteps: marginSteps ?? this.marginSteps,
      maxVerifyRetries: maxVerifyRetries ?? this.maxVerifyRetries,
      skipLinkStage: skipLinkStage ?? this.skipLinkStage,
    );
  }

  static List<int> _descending(List<int> values, List<int> fallback) {
    final cleaned = values.where((v) => v >= 0).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return cleaned.isEmpty ? fallback : cleaned;
  }

  /// 候選值去重、由大到小排序；輪數至少 1
  RfidOptimizerOptions validated() {
    const d = defaults;
    return RfidOptimizerOptions(
      spiSpeeds: _descending(spiSpeeds, d.spiSpeeds),
      linkSamples: linkSamples < 1 ? 1 : linkSamples,
      rstCandidates: _descending(rstCandidates, d.rstCandidates),
      antennaCandidates: _descending(antennaCandidates, d.antennaCandidates),
      reqaTimeoutCandidates: _descending(
        reqaTimeoutCandidates.where((v) => v >= 1).toList(),
        d.reqaTimeoutCandidates,
      ),
      reqaAttemptCandidates: _descending(
        reqaAttemptCandidates.where((v) => v >= 1).toList(),
        d.reqaAttemptCandidates,
      ),
      sweepRounds: sweepRounds < 1 ? 1 : sweepRounds,
      verifyRounds: verifyRounds < 1 ? 1 : verifyRounds,
      marginSteps: marginSteps < 0 ? 0 : marginSteps,
      maxVerifyRetries: maxVerifyRetries < 0 ? 0 : maxVerifyRetries,
      skipLinkStage: skipLinkStage,
    );
  }

  /// 掃描階段最多要跑幾輪 (進度估算用)
  int get maxSweepRounds {
    var steps = 0;
    for (final parameter in sweepOrder) {
      steps += candidatesOf(parameter).length - 1;
    }
    return steps * sweepRounds;
  }

  Map<String, dynamic> toJson() => {
        'spiSpeeds': spiSpeeds,
        'linkSamples': linkSamples,
        'rstCandidates': rstCandidates,
        'antennaCandidates': antennaCandidates,
        'reqaTimeoutCandidates': reqaTimeoutCandidates,
        'reqaAttemptCandidates': reqaAttemptCandidates,
        'sweepRounds': sweepRounds,
        'verifyRounds': verifyRounds,
        'marginSteps': marginSteps,
        'maxVerifyRetries': maxVerifyRetries,
        'skipLinkStage': skipLinkStage,
      };

  factory RfidOptimizerOptions.fromJson(Map<String, dynamic> json) {
    List<int> ints(String key, List<int> fallback) {
      final raw = json[key];
      if (raw is! List) return fallback;
      return raw.map(RfidTimingConfig.parseIntValue).whereType<int>().toList();
    }

    int integer(String key, int fallback) =>
        RfidTimingConfig.parseIntValue(json[key]) ?? fallback;

    const d = defaults;
    return RfidOptimizerOptions(
      spiSpeeds: ints('spiSpeeds', d.spiSpeeds),
      linkSamples: integer('linkSamples', d.linkSamples),
      rstCandidates: ints('rstCandidates', d.rstCandidates),
      antennaCandidates: ints('antennaCandidates', d.antennaCandidates),
      reqaTimeoutCandidates:
          ints('reqaTimeoutCandidates', d.reqaTimeoutCandidates),
      reqaAttemptCandidates:
          ints('reqaAttemptCandidates', d.reqaAttemptCandidates),
      sweepRounds: integer('sweepRounds', d.sweepRounds),
      verifyRounds: integer('verifyRounds', d.verifyRounds),
      marginSteps: integer('marginSteps', d.marginSteps),
      maxVerifyRetries: integer('maxVerifyRetries', d.maxVerifyRetries),
      skipLinkStage: json['skipLinkStage'] == true,
    );
  }
}

enum OptimizerStage {
  link('連線檢測'),
  sanity('確認讀得到卡片'),
  sweep('搜尋參數'),
  verify('驗證'),
  done('完成');

  final String label;

  const OptimizerStage(this.label);

  static OptimizerStage fromName(String? name) => values.firstWhere(
        (value) => value.name == name,
        orElse: () => OptimizerStage.done,
      );
}

/// 進度回報
class OptimizerProgress {
  final OptimizerStage stage;
  final String message;

  /// 掃描階段目前在調的參數
  final String? parameter;

  /// 目前候選值跑到第幾輪 / 共幾輪
  final int round;
  final int totalRounds;

  /// 整體進度 (單位是「輪」的估計值)
  final int overallDone;
  final int overallTotal;

  /// 每顆讀卡機目前在測的候選值 (只有掃描階段有)
  final Map<String, int> candidates;

  final int elapsedMs;

  const OptimizerProgress({
    required this.stage,
    required this.message,
    this.parameter,
    this.round = 0,
    this.totalRounds = 0,
    this.overallDone = 0,
    this.overallTotal = 0,
    this.candidates = const {},
    this.elapsedMs = 0,
  });

  double get fraction {
    if (overallTotal <= 0) return 0;
    final value = overallDone / overallTotal;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  Map<String, dynamic> toJson() => {
        'stage': stage.name,
        'message': message,
        'parameter': parameter,
        'round': round,
        'totalRounds': totalRounds,
        'overallDone': overallDone,
        'overallTotal': overallTotal,
        'candidates': candidates,
        'elapsedMs': elapsedMs,
      };

  factory OptimizerProgress.fromJson(Map<String, dynamic> json) {
    final rawCandidates = json['candidates'];
    return OptimizerProgress(
      stage: OptimizerStage.fromName(json['stage'] as String?),
      message: json['message'] as String? ?? '',
      parameter: json['parameter'] as String?,
      round: (json['round'] as num?)?.toInt() ?? 0,
      totalRounds: (json['totalRounds'] as num?)?.toInt() ?? 0,
      overallDone: (json['overallDone'] as num?)?.toInt() ?? 0,
      overallTotal: (json['overallTotal'] as num?)?.toInt() ?? 0,
      candidates: rawCandidates is Map
          ? {
              for (final entry in rawCandidates.entries)
                entry.key.toString(): (entry.value as num).toInt(),
            }
          : const {},
      elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() =>
      'OptimizerProgress(${stage.label}: $message, $overallDone/$overallTotal)';
}

/// 一顆讀卡機的最佳化結果
class ReaderOptimizationSummary {
  final String deviceId;

  /// 最終採用的值 (只含掃描過的參數)
  final Map<String, int> values;

  /// 驗證階段讀到的次數 / 總輪數
  final int verifyHits;
  final int verifyRounds;

  /// 是否穩定 (有參與搜尋且通過驗證)
  final bool stable;

  /// 連線檢測量到的就緒時間
  final int? timeToReadyMs;

  /// 不穩定時的原因
  final String? note;

  const ReaderOptimizationSummary({
    required this.deviceId,
    required this.values,
    required this.verifyHits,
    required this.verifyRounds,
    required this.stable,
    this.timeToReadyMs,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'values': values,
        'verifyHits': verifyHits,
        'verifyRounds': verifyRounds,
        'stable': stable,
        'timeToReadyMs': timeToReadyMs,
        'note': note,
      };

  factory ReaderOptimizationSummary.fromJson(Map<String, dynamic> json) {
    final rawValues = json['values'];
    return ReaderOptimizationSummary(
      deviceId: json['deviceId'] as String,
      values: rawValues is Map
          ? {
              for (final entry in rawValues.entries)
                entry.key.toString(): (entry.value as num).toInt(),
            }
          : const {},
      verifyHits: (json['verifyHits'] as num?)?.toInt() ?? 0,
      verifyRounds: (json['verifyRounds'] as num?)?.toInt() ?? 0,
      stable: json['stable'] == true,
      timeToReadyMs: (json['timeToReadyMs'] as num?)?.toInt(),
      note: json['note'] as String?,
    );
  }
}

/// 最佳化結果
class OptimizationResult {
  /// 最佳化前的設定
  final RfidTimingConfig before;

  /// 建議套用的設定 (全域值 + 每顆覆寫 + SPI 時脈)
  final RfidTimingConfig config;

  final List<LinkMeasurement> linkMeasurements;
  final Map<String, ReaderOptimizationSummary> readers;
  final List<String> notes;
  final int elapsedMs;
  final int roundsRun;
  final bool cancelled;

  const OptimizationResult({
    required this.before,
    required this.config,
    required this.linkMeasurements,
    required this.readers,
    required this.notes,
    required this.elapsedMs,
    required this.roundsRun,
    this.cancelled = false,
  });

  List<String> get deviceIds => readers.keys.toList()..sort();

  bool get allStable =>
      readers.isNotEmpty && readers.values.every((r) => r.stable);

  List<String> get unstableReaderIds =>
      readers.values.where((r) => !r.stable).map((r) => r.deviceId).toList()
        ..sort();

  int get estimatedNoCardMsBefore => before.estimateNoCardScanMsFor(deviceIds);

  int get estimatedNoCardMsAfter => config.estimateNoCardScanMsFor(deviceIds);

  int get estimatedAllCardsMsBefore =>
      before.estimateAllCardsScanMsFor(deviceIds);

  int get estimatedAllCardsMsAfter =>
      config.estimateAllCardsScanMsFor(deviceIds);

  Map<String, dynamic> toJson() => {
        'before': before.toJson(),
        'config': config.toJson(),
        'linkMeasurements': linkMeasurements.map((m) => m.toJson()).toList(),
        'readers': {
          for (final entry in readers.entries) entry.key: entry.value.toJson(),
        },
        'notes': notes,
        'elapsedMs': elapsedMs,
        'roundsRun': roundsRun,
        'cancelled': cancelled,
      };

  factory OptimizationResult.fromJson(Map<String, dynamic> json) {
    final rawReaders = Map<String, dynamic>.from(json['readers'] as Map? ?? {});
    return OptimizationResult(
      before: RfidTimingConfig.fromJson(
        Map<String, dynamic>.from(json['before'] as Map),
      ),
      config: RfidTimingConfig.fromJson(
        Map<String, dynamic>.from(json['config'] as Map),
      ),
      linkMeasurements: (json['linkMeasurements'] as List? ?? const [])
          .map((raw) =>
              LinkMeasurement.fromJson(Map<String, dynamic>.from(raw as Map)))
          .toList(),
      readers: {
        for (final entry in rawReaders.entries)
          entry.key: ReaderOptimizationSummary.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          ),
      },
      notes: (json['notes'] as List? ?? const [])
          .map((n) => n.toString())
          .toList(),
      elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
      roundsRun: (json['roundsRun'] as num?)?.toInt() ?? 0,
      cancelled: json['cancelled'] == true,
    );
  }
}

/// 自動最佳化演算法
class RfidOptimizer {
  final RfidOptimizerRunner runner;
  final RfidOptimizerOptions options;
  final void Function(OptimizerProgress progress)? onProgress;
  final bool Function()? shouldCancel;

  RfidOptimizer(
    this.runner, {
    RfidOptimizerOptions? options,
    this.onProgress,
    this.shouldCancel,
  }) : options = (options ?? RfidOptimizerOptions.defaults).validated();

  Future<OptimizationResult> run({required RfidTimingConfig base}) async {
    final stopwatch = Stopwatch()..start();
    final ids = List<String>.from(runner.deviceIds)..sort();
    final notes = <String>[];
    final link = <LinkMeasurement>[];
    final readyMs = <String, int>{};
    final unstable = <String, String>{};
    var roundsRun = 0;
    var overallDone = 0;
    var speed = base.spiSpeedHz;

    final linkUnits = options.skipLinkStage
        ? 0
        : options.spiSpeeds.length * options.sweepRounds;
    final overallTotal = linkUnits +
        options.sweepRounds +
        options.maxSweepRounds +
        options.verifyRounds * (1 + options.maxVerifyRetries);

    bool cancelled() => shouldCancel?.call() ?? false;

    void report(
      OptimizerStage stage,
      String message, {
      String? parameter,
      int round = 0,
      int totalRounds = 0,
      Map<String, int> candidates = const {},
    }) {
      onProgress?.call(OptimizerProgress(
        stage: stage,
        message: message,
        parameter: parameter,
        round: round,
        totalRounds: totalRounds,
        overallDone: overallDone,
        overallTotal: overallTotal,
        candidates: candidates,
        elapsedMs: stopwatch.elapsedMilliseconds,
      ));
    }

    Map<String, ReaderOptimizationSummary> summaries({
      required Map<String, Map<String, int>> values,
      required Map<String, int> verifyHits,
      required int verifyRounds,
    }) {
      return {
        for (final id in ids)
          id: ReaderOptimizationSummary(
            deviceId: id,
            values: unstable.containsKey(id)
                ? _baseValues(base.forReader(id))
                : Map<String, int>.from(values[id] ?? const {}),
            verifyHits: verifyHits[id] ?? 0,
            verifyRounds: verifyRounds,
            stable: !unstable.containsKey(id),
            timeToReadyMs: readyMs[id],
            note: unstable[id],
          ),
      };
    }

    OptimizationResult unchanged({required bool cancelledFlag, String? note}) {
      if (note != null) notes.add(note);
      return OptimizationResult(
        before: base,
        config: base,
        linkMeasurements: link,
        readers:
            summaries(values: const {}, verifyHits: const {}, verifyRounds: 0),
        notes: notes,
        elapsedMs: stopwatch.elapsedMilliseconds,
        roundsRun: roundsRun,
        cancelled: cancelledFlag,
      );
    }

    // ---- 1. 連線階段 ----
    if (!options.skipLinkStage) {
      for (final candidateSpeed in options.spiSpeeds) {
        if (cancelled()) return unchanged(cancelledFlag: true, note: '已取消');
        report(OptimizerStage.link, 'SPI $candidateSpeed Hz 連線檢測');
        final probes = await runner.probeLinks(
          candidateSpeed,
          samples: options.linkSamples,
        );
        for (final probe in probes) {
          link.add(LinkMeasurement(spiSpeedHz: candidateSpeed, probe: probe));
        }
        overallDone += options.sweepRounds;
        report(OptimizerStage.link, 'SPI $candidateSpeed Hz 連線檢測完成');
      }

      final recommendation = RfidCalibration.recommend(
        base: base,
        measurements: link,
      );
      speed = recommendation.config.spiSpeedHz;
      notes.addAll(recommendation.notes);

      for (final id in ids) {
        final atSpeed = link.where(
          (m) =>
              m.spiSpeedHz == speed && m.probe.deviceId == id && m.probe.ready,
        );
        final anyReady = link.where(
          (m) => m.probe.deviceId == id && m.probe.ready,
        );
        if (atSpeed.isNotEmpty) {
          readyMs[id] = atSpeed.first.probe.timeToReadyMs!;
        } else if (anyReady.isNotEmpty) {
          readyMs[id] = anyReady
              .map((m) => m.probe.timeToReadyMs!)
              .reduce((a, b) => a > b ? a : b);
        } else {
          unstable[id] = '連線檢測時 VersionReg 讀不到，請檢查 RST、3.3V、GND 與 SPI 接線';
        }
      }
    }

    List<int> candidatesFor(String id, String parameter) {
      final raw = options.candidatesOf(parameter);
      if (parameter != 'rstSettleMs') return raw;
      final ready = readyMs[id];
      var floor = RfidCalibration.minRstSettleMs;
      if (ready != null) {
        final suggested = ready * RfidCalibration.rstSettleMultiplier +
            RfidCalibration.rstSettleMarginMs;
        if (suggested > floor) floor = suggested;
      }
      final filtered = raw.where((c) => c >= floor).toList();
      return filtered.isEmpty ? [floor] : filtered;
    }

    // 每顆的目前值：從最保守的候選值開始
    final values = <String, Map<String, int>>{
      for (final id in ids)
        id: {
          for (final parameter in RfidOptimizerOptions.sweepOrder)
            parameter: candidatesFor(id, parameter).first,
        },
    };

    RfidTimingConfig configFor(Map<String, Map<String, int>> perReader) {
      return base.copyWith(
        spiSpeedHz: speed,
        readerOverrides: {
          for (final id in ids)
            if (!unstable.containsKey(id))
              id: Map<String, int>.from(perReader[id]!),
        },
      );
    }

    /// 跑 [rounds] 輪，回傳每顆讀到卡片的次數；取消時提早結束
    Future<Map<String, int>> runRounds(
      RfidTimingConfig timing,
      int rounds, {
      required OptimizerStage stage,
      required String message,
      String? parameter,
      Map<String, int> candidates = const {},
    }) async {
      final hits = <String, int>{for (final id in ids) id: 0};
      for (var round = 1; round <= rounds; round++) {
        if (cancelled()) break;
        report(
          stage,
          message,
          parameter: parameter,
          round: round,
          totalRounds: rounds,
          candidates: candidates,
        );
        final cycle = await runner.scan(timing);
        roundsRun++;
        overallDone++;
        for (final id in ids) {
          if (cycle.readers[id]?.hasCard == true) hits[id] = hits[id]! + 1;
        }
      }
      return hits;
    }

    await runner.openSession(speed);
    try {
      // ---- 2. 確認階段 ----
      final activeIds = ids.where((id) => !unstable.containsKey(id)).toList();
      if (activeIds.isEmpty) {
        return unchanged(
          cancelledFlag: false,
          note: '所有讀卡機在連線檢測都失敗，沒有進行最佳化',
        );
      }

      final sanityHits = await runRounds(
        configFor(values),
        options.sweepRounds,
        stage: OptimizerStage.sanity,
        message: '用最保守的候選值確認每顆都讀得到卡片',
      );
      if (cancelled()) return unchanged(cancelledFlag: true, note: '已取消');
      for (final id in activeIds) {
        if (sanityHits[id]! < options.sweepRounds) {
          unstable[id] = '最保守的設定下仍讀不到卡片 '
              '(${sanityHits[id]}/${options.sweepRounds})，請確認卡片有放好';
        }
      }
      if (ids.every(unstable.containsKey)) {
        return unchanged(
          cancelledFlag: false,
          note: '所有讀卡機都讀不到卡片，請確認卡片放好後再試',
        );
      }

      // ---- 3. 掃描階段 ----
      var budgetDone = overallDone;
      for (final parameter in RfidOptimizerOptions.sweepOrder) {
        final budget =
            (options.candidatesOf(parameter).length - 1) * options.sweepRounds;
        final candidates = <String, List<int>>{
          for (final id in ids) id: candidatesFor(id, parameter),
        };
        final index = <String, int>{for (final id in ids) id: 0};
        final done = <String, bool>{
          for (final id in ids) id: unstable.containsKey(id),
        };

        while (true) {
          final active = ids
              .where(
                  (id) => !done[id]! && index[id]! + 1 < candidates[id]!.length)
              .toList();
          if (active.isEmpty) break;

          final trial = <String, Map<String, int>>{
            for (final id in ids) id: Map<String, int>.from(values[id]!),
          };
          for (final id in active) {
            trial[id]![parameter] = candidates[id]![index[id]! + 1];
          }

          final hits = await runRounds(
            configFor(trial),
            options.sweepRounds,
            stage: OptimizerStage.sweep,
            message: '${RfidTimingConfig.labels[parameter] ?? parameter} 往下試',
            parameter: parameter,
            candidates: {for (final id in active) id: trial[id]![parameter]!},
          );
          if (cancelled()) return unchanged(cancelledFlag: true, note: '已取消');

          for (final id in active) {
            if (hits[id] == options.sweepRounds) {
              index[id] = index[id]! + 1;
              values[id]![parameter] = candidates[id]![index[id]!];
            } else {
              done[id] = true;
            }
          }
        }

        // 安全餘裕：往上加幾階 (次數類的 reqaAttempts 不加)
        if (parameter != 'reqaAttempts' && options.marginSteps > 0) {
          for (final id in ids) {
            if (unstable.containsKey(id)) continue;
            var i = index[id]! - options.marginSteps;
            if (i < 0) i = 0;
            values[id]![parameter] = candidates[id]![i];
          }
        }

        budgetDone += budget;
        if (overallDone < budgetDone) overallDone = budgetDone;
      }

      // ---- 4. 驗證階段 ----
      var retries = 0;
      var verifyHits = <String, int>{};
      while (true) {
        verifyHits = await runRounds(
          configFor(values),
          options.verifyRounds,
          stage: OptimizerStage.verify,
          message: retries == 0
              ? '用最終值驗證 ${options.verifyRounds} 輪'
              : '放寬後重新驗證 (第 $retries 次)',
        );
        if (cancelled()) return unchanged(cancelledFlag: true, note: '已取消');

        final failing = ids
            .where((id) =>
                !unstable.containsKey(id) &&
                verifyHits[id]! < options.verifyRounds)
            .toList();
        if (failing.isEmpty) break;

        if (retries >= options.maxVerifyRetries) {
          for (final id in failing) {
            unstable[id] = '驗證 ${verifyHits[id]}/${options.verifyRounds} 次讀到，'
                '放寬 $retries 次仍不穩定，退回原設定';
          }
          break;
        }
        retries++;
        for (final id in failing) {
          _stepUp(id, values, candidatesFor);
          notes.add('讀卡機 $id 驗證漏讀 ${options.verifyRounds - verifyHits[id]!} 次，'
              '參數放寬一階後重驗');
        }
      }

      final finalConfig = configFor(values).validated();
      final readers = summaries(
        values: values,
        verifyHits: verifyHits,
        verifyRounds: options.verifyRounds,
      );
      final result = OptimizationResult(
        before: base,
        config: finalConfig,
        linkMeasurements: link,
        readers: readers,
        notes: notes,
        elapsedMs: stopwatch.elapsedMilliseconds,
        roundsRun: roundsRun,
      );
      notes.add('估計一輪：七顆都有卡 ${result.estimatedAllCardsMsAfter} ms，'
          '全部沒卡 ${result.estimatedNoCardMsAfter} ms '
          '(原本 ${result.estimatedAllCardsMsBefore} / '
          '${result.estimatedNoCardMsBefore} ms)');
      overallDone = overallTotal;
      report(OptimizerStage.done, '完成，共跑 $roundsRun 輪');
      return result;
    } finally {
      await runner.closeSession();
    }
  }

  /// 把某顆的時間類參數各放寬一階、REQA 次數回到最多
  static void _stepUp(
    String id,
    Map<String, Map<String, int>> values,
    List<int> Function(String id, String parameter) candidatesFor,
  ) {
    for (final parameter in RfidOptimizerOptions.sweepOrder) {
      final candidates = candidatesFor(id, parameter);
      if (parameter == 'reqaAttempts') {
        values[id]![parameter] = candidates.first;
        continue;
      }
      final current = values[id]![parameter]!;
      final position = candidates.indexOf(current);
      if (position > 0) {
        values[id]![parameter] = candidates[position - 1];
      } else if (position < 0) {
        values[id]![parameter] = candidates.first;
      }
    }
  }

  static Map<String, int> _baseValues(RfidTimingConfig timing) => {
        for (final parameter in RfidOptimizerOptions.sweepOrder)
          parameter: timing.valueOf(parameter),
      };
}
