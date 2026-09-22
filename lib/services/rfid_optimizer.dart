/// RC522 輪巡自動最佳化 (純 Dart，不依賴 Flutter，CLI 與 app 共用)
///
/// 目標：一輪掃描時間最短，而且七顆讀卡機在驗證輪數內全部 100% 讀到卡片。
/// 測試時七顆都要放上卡片。
///
/// 流程：
/// 1. 連線階段 (不用卡)：各 SPI 時脈量每顆的讀寫錯誤率，取全部零錯誤的最高時脈；
///    量每顆 RST 拉高後的就緒時間，當 `rstSettleMs` 候選值的下限。
/// 2. 確認階段：每顆從「起點值」跑幾輪。起點 = max(目前生效的值, 一般候選值的最大值)，
///    手動調大過的讀卡機 (例如線最長那顆的 `rstSettleMs: 80`) 不會被拿較小的值去測。
///    讀不到卡的讀卡機把四個參數一起往上放寬 (升階候選值，例如 RST 100 → 200 → 500 ms)
///    再確認，所以「需要更長等待」的解也找得到；放寬到底仍讀不到才視為「不穩定」，
///    不參與後面的搜尋並維持原設定 (通常是卡片沒放好或線路問題)。
/// 3. 掃描階段：依序對 `rstSettleMs`、`antennaSettleMs`、`reqaTimeoutMs`、
///    `reqaAttempts` 由起點往小試。每顆讀卡機各自有自己的候選值與進度，
///    但同一輪掃描裡七顆各測各的，所以每顆各自搜尋不需要七倍時間。
///    每個候選值跑 N 輪，全中才往下一個更小的值走；取最小可過的值之後再往上
///    加 [RfidOptimizerOptions.marginSteps] 階當安全餘裕 (不超過起點)。
/// 4. 驗證階段：用最終值跑 M 輪，任何一顆漏讀就把它的四個參數各放寬一階重驗；
///    重驗仍失敗的讀卡機退回原設定並標記。
///
/// 量測時 (確認、掃描、驗證) 每顆都額外覆寫 `linkCheckTimeoutMs: 0`、`readerRetries: 0`
/// ([RfidOptimizer.measuringOverrides])，太小的候選值才不會被連線檢查的保險等待或
/// 重新上電重讀「救回來」而量到假的門檻；命中只算「沒有重讀就讀到卡片」的那一輪。
/// 輸出的設定保留 base 原有的每顆覆寫 (含不穩定的讀卡機與沒掃描的欄位)，
/// 只把掃描過的四個參數蓋上去，最終設定裡的兩個量測用欄位也還原成 base 的值。
///
/// `interReaderGapMs` 不在搜尋範圍：它只是前一顆 RST 拉低到下一顆 RST 拉高之間的一段
/// `Future.delayed`，預設 1 ms、往下只有 0 可選，七顆一輪最多省 7 ms，比單次掃描的
/// 時間抖動還小；它保護的時間窗跟下一顆的 `rstSettleMs` 是同一段，顆間若真有干擾
/// 會表現成下一顆偵測失敗，每顆的掃描已經抓得到。要調可以在設定頁或 CLI 手動改。
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

  /// 確認階段在起點值讀不到卡片時，往上放寬用的候選值 (由小到大，都比一般候選值大)。
  /// 只有讀不到卡的讀卡機會用到，正常情況不花時間。空清單代表不放寬。
  final List<int> rstEscalation;
  final List<int> antennaEscalation;
  final List<int> reqaTimeoutEscalation;
  final List<int> reqaAttemptEscalation;

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
    this.rstEscalation = const [100, 200, 500],
    this.antennaEscalation = const [50, 100, 200],
    this.reqaTimeoutEscalation = const [50, 100],
    this.reqaAttemptEscalation = const [3, 4],
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

  /// 某個參數的升階候選值 (由小到大)
  List<int> escalationOf(String parameter) {
    switch (parameter) {
      case 'rstSettleMs':
        return rstEscalation;
      case 'antennaSettleMs':
        return antennaEscalation;
      case 'reqaTimeoutMs':
        return reqaTimeoutEscalation;
      case 'reqaAttempts':
        return reqaAttemptEscalation;
      default:
        throw ArgumentError.value(parameter, 'parameter');
    }
  }

  /// 確認階段最多放寬幾次 (升階清單最長的那個)
  int get maxEscalationSteps {
    var steps = 0;
    for (final parameter in sweepOrder) {
      final length = escalationOf(parameter).length;
      if (length > steps) steps = length;
    }
    return steps;
  }

  RfidOptimizerOptions copyWith({
    List<int>? spiSpeeds,
    int? linkSamples,
    List<int>? rstCandidates,
    List<int>? antennaCandidates,
    List<int>? reqaTimeoutCandidates,
    List<int>? reqaAttemptCandidates,
    List<int>? rstEscalation,
    List<int>? antennaEscalation,
    List<int>? reqaTimeoutEscalation,
    List<int>? reqaAttemptEscalation,
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
      rstEscalation: rstEscalation ?? this.rstEscalation,
      antennaEscalation: antennaEscalation ?? this.antennaEscalation,
      reqaTimeoutEscalation:
          reqaTimeoutEscalation ?? this.reqaTimeoutEscalation,
      reqaAttemptEscalation:
          reqaAttemptEscalation ?? this.reqaAttemptEscalation,
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

  /// 升階值去重、由小到大排序；空清單是合法的 (不放寬)
  static List<int> _ascending(List<int> values, {int minimum = 0}) =>
      values.where((v) => v >= minimum).toSet().toList()..sort();

  /// 候選值去重、由大到小排序，升階值由小到大；輪數至少 1
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
      rstEscalation: _ascending(rstEscalation),
      antennaEscalation: _ascending(antennaEscalation),
      reqaTimeoutEscalation: _ascending(reqaTimeoutEscalation, minimum: 1),
      reqaAttemptEscalation: _ascending(reqaAttemptEscalation, minimum: 1),
      sweepRounds: sweepRounds < 1 ? 1 : sweepRounds,
      verifyRounds: verifyRounds < 1 ? 1 : verifyRounds,
      marginSteps: marginSteps < 0 ? 0 : marginSteps,
      maxVerifyRetries: maxVerifyRetries < 0 ? 0 : maxVerifyRetries,
      skipLinkStage: skipLinkStage,
    );
  }

  /// 掃描階段從一般候選值的最大值往下走完最多要跑幾輪 (不含升階；
  /// 進度估算與對話框的時間預估用，實際跑完確認階段後會依每顆的起點重算)
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
        'rstEscalation': rstEscalation,
        'antennaEscalation': antennaEscalation,
        'reqaTimeoutEscalation': reqaTimeoutEscalation,
        'reqaAttemptEscalation': reqaAttemptEscalation,
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
      rstEscalation: ints('rstEscalation', d.rstEscalation),
      antennaEscalation: ints('antennaEscalation', d.antennaEscalation),
      reqaTimeoutEscalation:
          ints('reqaTimeoutEscalation', d.reqaTimeoutEscalation),
      reqaAttemptEscalation:
          ints('reqaAttemptEscalation', d.reqaAttemptEscalation),
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

  /// 量測時 (確認、掃描、驗證) 對每顆額外套用的覆寫：關掉連線檢查的保險等待與
  /// 重新上電重讀，太小的候選值才不會被這兩個隱藏的等待「救回來」而量到假的門檻。
  /// 最終輸出的設定不帶這兩個欄位，會還原成 base 的值。
  static const Map<String, int> measuringOverrides = {
    'linkCheckTimeoutMs': 0,
    'readerRetries': 0,
  };

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
    final verifyUnits = options.verifyRounds * (1 + options.maxVerifyRetries);
    // 先用一般候選值估總進度，確認階段結束、知道每顆的起點之後再重算
    var overallTotal =
        linkUnits + options.sweepRounds + options.maxSweepRounds + verifyUnits;

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

    /// 某顆某個參數的候選值 (由大到小) 與搜尋起點的索引。
    /// 起點 = max(目前生效的值, 一般候選值的最大值)；起點之上是升階值 (只在確認階段
    /// 讀不到卡時用到)，起點之下是一般候選值。rstSettleMs 另外不低於就緒時間推出的下限。
    (List<int>, int) candidatesFor(String id, String parameter) {
      final normal = options.candidatesOf(parameter);
      final current = base.forReader(id).valueOf(parameter);
      final start = current > normal.first ? current : normal.first;

      var floor = 0;
      if (parameter == 'rstSettleMs') {
        floor = RfidCalibration.minRstSettleMs;
        final ready = readyMs[id];
        if (ready != null) {
          final suggested = ready * RfidCalibration.rstSettleMultiplier +
              RfidCalibration.rstSettleMarginMs;
          if (suggested > floor) floor = suggested;
        }
      }

      final all = <int>{
        ...options.escalationOf(parameter).where((v) => v > start),
        start,
        ...normal.where((v) => v < start),
      }.where((v) => v >= floor).toList()
        ..sort((a, b) => b.compareTo(a));
      if (all.isEmpty) return ([floor], 0);
      final startIndex = all.indexOf(start);
      // 起點低於下限時，從下限以上最小的值開始
      return (all, startIndex < 0 ? all.length - 1 : startIndex);
    }

    final candidates = <String, Map<String, List<int>>>{};
    final startIndex = <String, Map<String, int>>{};
    for (final id in ids) {
      candidates[id] = {};
      startIndex[id] = {};
      for (final parameter in RfidOptimizerOptions.sweepOrder) {
        final (list, start) = candidatesFor(id, parameter);
        candidates[id]![parameter] = list;
        startIndex[id]![parameter] = start;
      }
    }

    // 每顆的目前值：從起點開始
    final values = <String, Map<String, int>>{
      for (final id in ids)
        id: {
          for (final parameter in RfidOptimizerOptions.sweepOrder)
            parameter: candidates[id]![parameter]![startIndex[id]![parameter]!],
        },
    };

    String describeValues(Map<String, int> v) =>
        'RST ${v['rstSettleMs']} / 天線 ${v['antennaSettleMs']} / '
        'REQA ${v['reqaTimeoutMs']} ms × ${v['reqaAttempts']} 次';

    /// 用每顆目前的候選值組出設定。base 既有的覆寫 (不參與搜尋的讀卡機、沒掃描的欄位)
    /// 全部保留，掃描中的四個參數蓋在上面；[measuring] 時再套上 [measuringOverrides]。
    RfidTimingConfig configFor(
      Map<String, Map<String, int>> perReader, {
      bool measuring = false,
    }) {
      return base.copyWith(
        spiSpeedHz: speed,
        readerOverrides: {
          for (final entry in base.readerOverrides.entries)
            entry.key: Map<String, int>.from(entry.value),
          for (final id in ids)
            if (!unstable.containsKey(id))
              id: {
                ...?base.readerOverrides[id],
                ...perReader[id]!,
                if (measuring) ...measuringOverrides,
              },
        },
      );
    }

    /// 跑 [rounds] 輪，回傳每顆「沒有重讀就讀到卡片」的次數；取消時提早結束
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
          final result = cycle.readers[id];
          if (result != null && result.hasCard && result.rereads == 0) {
            hits[id] = hits[id]! + 1;
          }
        }
      }
      return hits;
    }

    await runner.openSession(speed);
    try {
      // ---- 2. 確認階段 ----
      var pending = ids.where((id) => !unstable.containsKey(id)).toList();
      if (pending.isEmpty) {
        return unchanged(
          cancelledFlag: false,
          note: '所有讀卡機在連線檢測都失敗，沒有進行最佳化',
        );
      }

      var escalations = 0;
      while (true) {
        final hits = await runRounds(
          configFor(values, measuring: true),
          options.sweepRounds,
          stage: OptimizerStage.sanity,
          message: escalations == 0
              ? '用起點值確認每顆都讀得到卡片'
              : '讀不到的讀卡機放寬後再確認 (第 $escalations 次)',
          parameter: escalations == 0 ? null : 'rstSettleMs',
          candidates: escalations == 0
              ? const {}
              : {for (final id in pending) id: values[id]!['rstSettleMs']!},
        );
        if (cancelled()) return unchanged(cancelledFlag: true, note: '已取消');

        final failing =
            pending.where((id) => hits[id]! < options.sweepRounds).toList();
        if (failing.isEmpty) break;

        // 讀不到的讀卡機：四個參數各往上放寬一階再試；已經沒得放寬的標為不穩定
        final escalated = <String>[];
        for (final id in failing) {
          var moved = false;
          for (final parameter in RfidOptimizerOptions.sweepOrder) {
            final index = startIndex[id]![parameter]!;
            if (index == 0) continue;
            startIndex[id]![parameter] = index - 1;
            values[id]![parameter] = candidates[id]![parameter]![index - 1];
            moved = true;
          }
          if (moved) {
            escalated.add(id);
          } else {
            unstable[id] = '放寬到 ${describeValues(values[id]!)} 仍讀不到卡片 '
                '(${hits[id]}/${options.sweepRounds})，請確認卡片有放好';
          }
        }
        if (escalated.isEmpty) break;
        escalations++;
        notes.add('讀卡機 ${escalated.join('、')} 在起點值讀不到卡片，'
            '放寬後再確認 (第 $escalations 次)');
        pending = escalated;
      }
      if (ids.every(unstable.containsKey)) {
        return unchanged(
          cancelledFlag: false,
          note: '所有讀卡機都讀不到卡片，請確認卡片放好後再試',
        );
      }

      // 知道每顆的起點之後重算總進度：同一輪裡七顆各測各的，
      // 一個參數要跑的輪數是「還能往下走最多階的那顆」的階數 × 每階輪數
      int sweepBudget(String parameter) {
        var steps = 0;
        for (final id in ids) {
          if (unstable.containsKey(id)) continue;
          final remaining = candidates[id]![parameter]!.length -
              1 -
              startIndex[id]![parameter]!;
          if (remaining > steps) steps = remaining;
        }
        return steps * options.sweepRounds;
      }

      overallTotal = overallDone + verifyUnits;
      for (final parameter in RfidOptimizerOptions.sweepOrder) {
        overallTotal += sweepBudget(parameter);
      }

      // ---- 3. 掃描階段 ----
      var budgetDone = overallDone;
      for (final parameter in RfidOptimizerOptions.sweepOrder) {
        final budget = sweepBudget(parameter);
        final index = <String, int>{
          for (final id in ids) id: startIndex[id]![parameter]!,
        };
        final done = <String, bool>{
          for (final id in ids) id: unstable.containsKey(id),
        };

        while (true) {
          final active = ids
              .where((id) =>
                  !done[id]! &&
                  index[id]! + 1 < candidates[id]![parameter]!.length)
              .toList();
          if (active.isEmpty) break;

          final trial = <String, Map<String, int>>{
            for (final id in ids) id: Map<String, int>.from(values[id]!),
          };
          for (final id in active) {
            trial[id]![parameter] = candidates[id]![parameter]![index[id]! + 1];
          }

          final hits = await runRounds(
            configFor(trial, measuring: true),
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
              values[id]![parameter] = candidates[id]![parameter]![index[id]!];
            } else {
              done[id] = true;
            }
          }
        }

        // 安全餘裕：往上加幾階，但不超過起點 (起點已在確認階段證明讀得到；
        // 次數類的 reqaAttempts 不加)
        if (parameter != 'reqaAttempts' && options.marginSteps > 0) {
          for (final id in ids) {
            if (unstable.containsKey(id)) continue;
            var i = index[id]! - options.marginSteps;
            final start = startIndex[id]![parameter]!;
            if (i < start) i = start;
            values[id]![parameter] = candidates[id]![parameter]![i];
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
          configFor(values, measuring: true),
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
          _stepUp(id, values, candidates[id]!);
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

  /// 把某顆的四個參數各往上放寬一階 (候選值由大到小，往上就是索引減一)
  static void _stepUp(
    String id,
    Map<String, Map<String, int>> values,
    Map<String, List<int>> candidates,
  ) {
    for (final parameter in RfidOptimizerOptions.sweepOrder) {
      final list = candidates[parameter]!;
      final current = values[id]![parameter]!;
      final position = list.indexOf(current);
      if (position > 0) {
        values[id]![parameter] = list[position - 1];
      } else if (position < 0) {
        values[id]![parameter] = list.first;
      }
    }
  }

  static Map<String, int> _baseValues(RfidTimingConfig timing) => {
        for (final parameter in RfidOptimizerOptions.sweepOrder)
          parameter: timing.valueOf(parameter),
      };
}
