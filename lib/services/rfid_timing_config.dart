/// RFID 輪巡時序設定
///
/// 所有跟 RC522 輪巡「速度」與「可靠度」有關的可調參數都集中在這裡，
/// 不需要重新編譯就能用 JSON 檔或環境變數調整。
///
/// 預設值以 MFRC522 datasheet 與 Arduino MFRC522 library 的保守值為準：
/// - RST 拉高後等 50 ms 讓振盪器啟動 (datasheet 8.8.2：晶振啟動時間 + 37.74 µs)
/// - 開天線後等 5 ms 讓卡片上電 (ISO 14443-3 要求卡片在 5 ms 內就緒)
/// - REQA 由晶片 timer 在 25 ms 逾時，軟體端最多等 36 ms
///
/// 載入順序：
/// 1. 程式內建預設值
/// 2. JSON 設定檔 (路徑由 `RFID_TIMING_FILE` 環境變數指定，
///    否則用呼叫端給的路徑，再否則是 `~/Documents/rfid_timing.json`)
/// 3. 環境變數逐項覆寫，例如 `RFID_SPI_SPEED_HZ=500000`
/// 4. 範圍檢查，超出合理範圍的值會被夾回邊界
///
/// 除了全域值，設定檔的 `readers` 區段可以對單顆讀卡機覆寫
/// [perReaderKeys] 裡的欄位，例如線最長的那顆需要比較長的等待：
///
/// ```json
/// {
///   "rstSettleMs": 20,
///   "readers": { "07": { "rstSettleMs": 30, "antennaSettleMs": 10 } }
/// }
/// ```
///
/// 自動最佳化會替每顆讀卡機各自找出最小可靠值並寫進 `readers`。
library;

import 'dart:convert';
import 'dart:io';

/// 載入結果：設定值本身加上「從哪裡來」的資訊，方便設定頁與 CLI 顯示。
class RfidTimingLoadResult {
  final RfidTimingConfig config;

  /// 實際嘗試讀取的設定檔路徑
  final String? filePath;

  /// 設定檔是否存在且成功解析
  final bool fileFound;

  /// 被環境變數覆寫的欄位名稱
  final List<String> envOverrides;

  /// 讀檔或解析失敗時的錯誤訊息
  final String? error;

  const RfidTimingLoadResult({
    required this.config,
    this.filePath,
    this.fileFound = false,
    this.envOverrides = const [],
    this.error,
  });

  /// 給人看的來源說明
  String get sourceDescription {
    final parts = <String>[];
    if (error != null) {
      parts.add('設定檔讀取失敗，改用預設值 ($error)');
    } else if (fileFound) {
      parts.add('設定檔: $filePath');
    } else {
      parts.add('未找到設定檔，使用預設值'
          '${filePath != null ? ' (可建立 $filePath)' : ''}');
    }
    if (envOverrides.isNotEmpty) {
      parts.add('環境變數覆寫: ${envOverrides.join(', ')}');
    }
    return parts.join('；');
  }
}

/// RC522 輪巡的時序參數
class RfidTimingConfig {
  /// 指定設定檔路徑的環境變數
  static const String fileEnvKey = 'RFID_TIMING_FILE';

  /// 預設設定檔名稱
  static const String defaultFileName = 'rfid_timing.json';

  /// 逐項覆寫用的環境變數前綴，例如 `RFID_SPI_SPEED_HZ`
  static const String envPrefix = 'RFID_';

  /// 設定檔裡每顆讀卡機覆寫區段的 key
  static const String readersKey = 'readers';

  /// SPI 時脈 (Hz)。線長、負載重時可降到 500000 或 250000，
  /// 每次傳輸只有 2 bytes，降速對整輪時間影響很小。整條 bus 共用，不能每顆不同。
  final int spiSpeedHz;

  /// RST 拉高後等待振盪器啟動的時間 (ms)。
  /// datasheet 只要求晶振啟動時間 + 37.74 µs，Arduino library 保守取 50 ms。
  /// 校正工具會量出每顆實際需要的時間，可以據此下修。
  final int rstSettleMs;

  /// [rstSettleMs] 之後，若 VersionReg 還讀不到合理值，最多再等多久 (ms)。
  /// 這段是「保險」，線路正常時不會用到。0 表示不額外等。
  final int linkCheckTimeoutMs;

  /// 開天線後等待 RF 場穩定、卡片上電的時間 (ms)。
  final int antennaSettleMs;

  /// 送出 REQA 後晶片內部 timer 的逾時 (ms)。無卡時每次 REQA 會等這麼久。
  final int reqaTimeoutMs;

  /// 每顆讀卡機 REQA 最多嘗試幾次。卡片剛上電時偶爾會漏掉第一次 REQA。
  final int reqaAttempts;

  /// 軟體端等待 IRQ 的牆鐘上限 (ms)。
  /// 會自動提升到至少 [reqaTimeoutMs] + 10，否則晶片 timer 還沒響軟體就先放棄。
  final int commDeadlineMs;

  /// 一顆讀完、RST 拉低之後，到下一顆開始之前的間隔 (ms)。
  final int interReaderGapMs;

  /// 整輪結束後的額外等待 (ms)。舊版程式為 500，新版預設 0。
  final int postScanSettleMs;

  /// 整輪掃描的逾時 (秒)，超過就視為硬體卡死並回報錯誤。
  final int scanTimeoutSec;

  /// 關鍵暫存器寫入後讀回不符時最多重寫幾次。長線的偶發位元錯誤靠這個吃掉。
  final int writeVerifyRetries;

  /// anticoll 校驗失敗 (卡片還在 READY) 時最多直接重送幾次，之後才重做 REQA。
  final int anticollRetries;

  /// 一顆回報線路異常、晶片無回應或 SPI 寫入錯誤時，重新上電再讀幾次。
  final int readerRetries;

  /// 每顆讀卡機的覆寫值：deviceId ("01"…"07") → {欄位: 值}。
  /// 只允許 [perReaderKeys] 裡的欄位，其他會被忽略。
  final Map<String, Map<String, int>> readerOverrides;

  const RfidTimingConfig({
    this.spiSpeedHz = 1000000,
    this.rstSettleMs = 50,
    this.linkCheckTimeoutMs = 50,
    this.antennaSettleMs = 5,
    this.reqaTimeoutMs = 25,
    this.reqaAttempts = 2,
    this.commDeadlineMs = 36,
    this.interReaderGapMs = 1,
    this.postScanSettleMs = 0,
    this.scanTimeoutSec = 10,
    this.writeVerifyRetries = 2,
    this.anticollRetries = 2,
    this.readerRetries = 1,
    this.readerOverrides = const {},
  });

  /// 程式內建預設值
  static const RfidTimingConfig defaults = RfidTimingConfig();

  /// 所有全域欄位的名稱 (同時也是 JSON key)
  static const List<String> keys = [
    'spiSpeedHz',
    'rstSettleMs',
    'linkCheckTimeoutMs',
    'antennaSettleMs',
    'reqaTimeoutMs',
    'reqaAttempts',
    'commDeadlineMs',
    'interReaderGapMs',
    'postScanSettleMs',
    'scanTimeoutSec',
    'writeVerifyRetries',
    'anticollRetries',
    'readerRetries',
  ];

  /// 可以對單顆讀卡機覆寫的欄位
  static const List<String> perReaderKeys = [
    'rstSettleMs',
    'linkCheckTimeoutMs',
    'antennaSettleMs',
    'reqaTimeoutMs',
    'reqaAttempts',
    'commDeadlineMs',
    'writeVerifyRetries',
    'anticollRetries',
    'readerRetries',
  ];

  /// 每個欄位允許的範圍 (含)
  static const Map<String, (int, int)> ranges = {
    'spiSpeedHz': (50000, 10000000),
    'rstSettleMs': (0, 1000),
    'linkCheckTimeoutMs': (0, 1000),
    'antennaSettleMs': (0, 500),
    'reqaTimeoutMs': (1, 1000),
    'reqaAttempts': (1, 10),
    'commDeadlineMs': (1, 2000),
    'interReaderGapMs': (0, 1000),
    'postScanSettleMs': (0, 5000),
    'scanTimeoutSec': (1, 120),
    'writeVerifyRetries': (0, 5),
    'anticollRetries': (0, 5),
    'readerRetries': (0, 3),
  };

  /// 每個欄位的中文說明，給設定頁與 CLI 用
  static const Map<String, String> labels = {
    'spiSpeedHz': 'SPI 時脈 (Hz)',
    'rstSettleMs': 'RST 拉高後等待 (ms)',
    'linkCheckTimeoutMs': '連線檢查最多再等 (ms)',
    'antennaSettleMs': '天線開啟後等待 (ms)',
    'reqaTimeoutMs': 'REQA 晶片逾時 (ms)',
    'reqaAttempts': 'REQA 嘗試次數',
    'commDeadlineMs': '通訊牆鐘上限 (ms)',
    'interReaderGapMs': '讀卡機之間間隔 (ms)',
    'postScanSettleMs': '整輪結束後等待 (ms)',
    'scanTimeoutSec': '整輪逾時 (秒)',
    'writeVerifyRetries': '暫存器重寫次數',
    'anticollRetries': 'anticoll 重送次數',
    'readerRetries': '重新上電再讀次數',
  };

  /// 每個欄位的一句話說明，給設定頁的編輯表單用
  static const Map<String, String> hints = {
    'spiSpeedHz': '整條 bus 共用。線長或負載重時降到 500000 / 250000。',
    'rstSettleMs': 'RST 拉高後等振盪器啟動。datasheet 只需幾 ms，50 是保守值。',
    'linkCheckTimeoutMs': 'VersionReg 讀不到時最多再等多久，正常時用不到。',
    'antennaSettleMs': '天線開啟後讓卡片上電。ISO 14443 要求 5 ms 內就緒。',
    'reqaTimeoutMs': '沒卡時每次 REQA 要等這麼久才放棄。',
    'reqaAttempts': '每顆 REQA 最多試幾次。',
    'commDeadlineMs': '軟體端等 IRQ 的上限，會自動 ≥ REQA 逾時 + 10。',
    'interReaderGapMs': '兩顆之間的間隔。',
    'postScanSettleMs': '整輪結束後的額外等待。',
    'scanTimeoutSec': '整輪超過這個時間視為硬體卡死。會自動 ≥ 最壞情況 × 2。',
    'writeVerifyRetries': '寫入後讀回不符就重寫，吃掉長線的偶發位元錯誤。0 = 不驗證重寫。',
    'anticollRetries': 'UID 校驗失敗時直接重送 anticoll 的次數，之後才重做 REQA。',
    'readerRetries': '線路異常、無回應或 SPI 錯誤時，重新上電再讀的次數。',
  };

  /// 軟體等待 IRQ 的實際上限
  int get effectiveCommDeadlineMs =>
      commDeadlineMs < reqaTimeoutMs + 10 ? reqaTimeoutMs + 10 : commDeadlineMs;

  /// 是否有任何一顆讀卡機有覆寫值
  bool get hasReaderOverrides =>
      readerOverrides.values.any((values) => values.isNotEmpty);

  /// 有覆寫值的讀卡機 deviceId (已排序)
  List<String> get overriddenReaderIds => readerOverrides.entries
      .where((entry) => entry.value.isNotEmpty)
      .map((entry) => entry.key)
      .toList()
    ..sort();

  /// 只含全域欄位的 JSON
  Map<String, int> toBaseJson() => {
        'spiSpeedHz': spiSpeedHz,
        'rstSettleMs': rstSettleMs,
        'linkCheckTimeoutMs': linkCheckTimeoutMs,
        'antennaSettleMs': antennaSettleMs,
        'reqaTimeoutMs': reqaTimeoutMs,
        'reqaAttempts': reqaAttempts,
        'commDeadlineMs': commDeadlineMs,
        'interReaderGapMs': interReaderGapMs,
        'postScanSettleMs': postScanSettleMs,
        'scanTimeoutSec': scanTimeoutSec,
        'writeVerifyRetries': writeVerifyRetries,
        'anticollRetries': anticollRetries,
        'readerRetries': readerRetries,
      };

  /// 全域欄位加上 `readers` 區段 (沒有覆寫時省略)
  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{...toBaseJson()};
    if (hasReaderOverrides) {
      json[readersKey] = {
        for (final id in overriddenReaderIds)
          id: Map<String, int>.from(readerOverrides[id]!),
      };
    }
    return json;
  }

  /// 從 JSON 建立。缺少或型別不對的欄位沿用 [base] 的值。
  factory RfidTimingConfig.fromJson(
    Map<String, dynamic> json, {
    RfidTimingConfig base = defaults,
  }) {
    int pick(String key, int fallback) => parseIntValue(json[key]) ?? fallback;

    final overrides = <String, Map<String, int>>{};
    final rawReaders = json[readersKey];
    if (rawReaders is Map) {
      for (final entry in rawReaders.entries) {
        if (entry.value is! Map) continue;
        final values = <String, int>{};
        for (final inner in (entry.value as Map).entries) {
          final key = inner.key.toString();
          final value = parseIntValue(inner.value);
          if (perReaderKeys.contains(key) && value != null) {
            values[key] = value;
          }
        }
        if (values.isNotEmpty) overrides[entry.key.toString()] = values;
      }
    } else if (base.readerOverrides.isNotEmpty) {
      for (final entry in base.readerOverrides.entries) {
        overrides[entry.key] = Map<String, int>.from(entry.value);
      }
    }

    return RfidTimingConfig(
      spiSpeedHz: pick('spiSpeedHz', base.spiSpeedHz),
      rstSettleMs: pick('rstSettleMs', base.rstSettleMs),
      linkCheckTimeoutMs: pick('linkCheckTimeoutMs', base.linkCheckTimeoutMs),
      antennaSettleMs: pick('antennaSettleMs', base.antennaSettleMs),
      reqaTimeoutMs: pick('reqaTimeoutMs', base.reqaTimeoutMs),
      reqaAttempts: pick('reqaAttempts', base.reqaAttempts),
      commDeadlineMs: pick('commDeadlineMs', base.commDeadlineMs),
      interReaderGapMs: pick('interReaderGapMs', base.interReaderGapMs),
      postScanSettleMs: pick('postScanSettleMs', base.postScanSettleMs),
      scanTimeoutSec: pick('scanTimeoutSec', base.scanTimeoutSec),
      writeVerifyRetries: pick('writeVerifyRetries', base.writeVerifyRetries),
      anticollRetries: pick('anticollRetries', base.anticollRetries),
      readerRetries: pick('readerRetries', base.readerRetries),
      readerOverrides: overrides,
    );
  }

  /// 把 JSON、環境變數裡的值轉成整數；轉不出來就回 null。
  static int? parseIntValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// 讀取單一全域欄位
  int valueOf(String key) {
    final value = toBaseJson()[key];
    if (value == null) {
      throw ArgumentError.value(key, 'key', '不是有效的時序欄位');
    }
    return value;
  }

  /// 回傳改了單一全域欄位的新設定
  RfidTimingConfig withValue(String key, int value) {
    if (!keys.contains(key)) {
      throw ArgumentError.value(key, 'key', '不是有效的時序欄位');
    }
    final json = Map<String, dynamic>.from(toBaseJson());
    json[key] = value;
    return RfidTimingConfig.fromJson(json, base: this);
  }

  /// 某顆讀卡機實際生效的設定：全域值套上該顆的覆寫，結果不再帶 [readerOverrides]。
  RfidTimingConfig forReader(String deviceId) {
    final overrides = readerOverrides[deviceId];
    if (overrides == null || overrides.isEmpty) return withoutReaderOverrides();
    final json = Map<String, dynamic>.from(toBaseJson());
    for (final entry in overrides.entries) {
      if (perReaderKeys.contains(entry.key)) json[entry.key] = entry.value;
    }
    return RfidTimingConfig.fromJson(json);
  }

  /// 去掉所有讀卡機覆寫
  RfidTimingConfig withoutReaderOverrides() =>
      copyWith(readerOverrides: const {});

  /// 設定某顆讀卡機的單一覆寫值
  RfidTimingConfig withReaderOverride(String deviceId, String key, int value) {
    if (!perReaderKeys.contains(key)) {
      throw ArgumentError.value(key, 'key', '不是可以對單顆覆寫的欄位');
    }
    return withReaderOverrides(deviceId, {key: value});
  }

  /// 合併某顆讀卡機的覆寫值 (既有的其他欄位保留)
  RfidTimingConfig withReaderOverrides(
    String deviceId,
    Map<String, int> values,
  ) {
    final merged = <String, Map<String, int>>{
      for (final entry in readerOverrides.entries)
        entry.key: Map<String, int>.from(entry.value),
    };
    final target = merged.putIfAbsent(deviceId, () => {});
    for (final entry in values.entries) {
      if (perReaderKeys.contains(entry.key)) target[entry.key] = entry.value;
    }
    return copyWith(readerOverrides: merged);
  }

  /// 清掉某顆 (或全部) 讀卡機的覆寫
  RfidTimingConfig clearReaderOverrides([String? deviceId]) {
    if (deviceId == null) return withoutReaderOverrides();
    final remaining = <String, Map<String, int>>{
      for (final entry in readerOverrides.entries)
        if (entry.key != deviceId)
          entry.key: Map<String, int>.from(entry.value),
    };
    return copyWith(readerOverrides: remaining);
  }

  RfidTimingConfig copyWith({
    int? spiSpeedHz,
    int? rstSettleMs,
    int? linkCheckTimeoutMs,
    int? antennaSettleMs,
    int? reqaTimeoutMs,
    int? reqaAttempts,
    int? commDeadlineMs,
    int? interReaderGapMs,
    int? postScanSettleMs,
    int? scanTimeoutSec,
    int? writeVerifyRetries,
    int? anticollRetries,
    int? readerRetries,
    Map<String, Map<String, int>>? readerOverrides,
  }) {
    return RfidTimingConfig(
      spiSpeedHz: spiSpeedHz ?? this.spiSpeedHz,
      rstSettleMs: rstSettleMs ?? this.rstSettleMs,
      linkCheckTimeoutMs: linkCheckTimeoutMs ?? this.linkCheckTimeoutMs,
      antennaSettleMs: antennaSettleMs ?? this.antennaSettleMs,
      reqaTimeoutMs: reqaTimeoutMs ?? this.reqaTimeoutMs,
      reqaAttempts: reqaAttempts ?? this.reqaAttempts,
      commDeadlineMs: commDeadlineMs ?? this.commDeadlineMs,
      interReaderGapMs: interReaderGapMs ?? this.interReaderGapMs,
      postScanSettleMs: postScanSettleMs ?? this.postScanSettleMs,
      scanTimeoutSec: scanTimeoutSec ?? this.scanTimeoutSec,
      writeVerifyRetries: writeVerifyRetries ?? this.writeVerifyRetries,
      anticollRetries: anticollRetries ?? this.anticollRetries,
      readerRetries: readerRetries ?? this.readerRetries,
      readerOverrides: readerOverrides ?? this.readerOverrides,
    );
  }

  static int _clamp(String key, int value) {
    final (low, high) = ranges[key]!;
    return value < low ? low : (value > high ? high : value);
  }

  /// 把每個欄位 (含讀卡機覆寫) 夾回 [ranges] 定義的範圍
  RfidTimingConfig validated() {
    final json = Map<String, dynamic>.from(toBaseJson());
    for (final key in keys) {
      json[key] = _clamp(key, json[key] as int);
    }
    final overrides = <String, Map<String, int>>{
      for (final entry in readerOverrides.entries)
        if (entry.value.isNotEmpty)
          entry.key: {
            for (final inner in entry.value.entries)
              if (perReaderKeys.contains(inner.key))
                inner.key: _clamp(inner.key, inner.value),
          },
    };
    json[readersKey] = overrides;
    return RfidTimingConfig.fromJson(json);
  }

  /// 欄位名稱對應的環境變數，例如 `spiSpeedHz` → `RFID_SPI_SPEED_HZ`
  static String envKeyFor(String key) {
    final buffer = StringBuffer(envPrefix);
    for (var i = 0; i < key.length; i++) {
      final char = key[i];
      final isUpper = char.toUpperCase() == char && char.toLowerCase() != char;
      if (isUpper && i > 0) buffer.write('_');
      buffer.write(char.toUpperCase());
    }
    return buffer.toString();
  }

  /// 套用環境變數覆寫 (只影響全域欄位)。[applied] 會收到實際被覆寫的欄位名稱。
  RfidTimingConfig applyEnvironment(
    Map<String, String> environment, {
    List<String>? applied,
  }) {
    var result = this;
    for (final key in keys) {
      final raw = environment[envKeyFor(key)];
      if (raw == null) continue;
      final value = parseIntValue(raw);
      if (value == null) continue;
      result = result.withValue(key, value);
      applied?.add(key);
    }
    return result;
  }

  /// 預設設定檔路徑：`$HOME/Documents/rfid_timing.json`
  ///
  /// Raspberry Pi OS 上 path_provider 的 documents 目錄也是這裡，
  /// 所以 CLI 校正工具與 Flutter app 會讀到同一個檔案。
  static String defaultFilePath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null || home.isEmpty) return defaultFileName;
    return '$home${Platform.pathSeparator}Documents'
        '${Platform.pathSeparator}$defaultFileName';
  }

  /// 依「預設值 → 設定檔 → 環境變數 → 範圍檢查」的順序載入。
  ///
  /// [filePath] 是設定檔路徑；若環境變數 `RFID_TIMING_FILE` 有設定會優先。
  static Future<RfidTimingLoadResult> load({
    String? filePath,
    Map<String, String>? environment,
  }) async {
    final env = environment ?? Platform.environment;
    final path =
        env[fileEnvKey] ?? filePath ?? defaultFilePath(environment: env);

    var config = defaults;
    var fileFound = false;
    String? error;

    try {
      final file = File(path);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          config =
              RfidTimingConfig.fromJson(Map<String, dynamic>.from(decoded));
          fileFound = true;
        } else {
          error = '設定檔內容不是 JSON 物件';
        }
      }
    } catch (e) {
      error = e.toString();
      config = defaults;
    }

    final overrides = <String>[];
    config = config.applyEnvironment(env, applied: overrides).validated();

    return RfidTimingLoadResult(
      config: config,
      filePath: path,
      fileFound: fileFound,
      envOverrides: overrides,
      error: error,
    );
  }

  /// 以縮排 JSON 寫入設定檔，目錄不存在會自動建立。
  Future<void> saveTo(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString('${toPrettyJson()}\n');
  }

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 「中文標籤 → 值」的對照，給 UI 顯示；有覆寫的讀卡機各列一行
  Map<String, String> describe() {
    final json = toBaseJson();
    final map = <String, String>{
      for (final key in keys) labels[key]!: json[key].toString(),
    };
    for (final id in overriddenReaderIds) {
      map['讀卡機 $id 覆寫'] = readerOverrides[id]!
          .entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join(', ');
    }
    return map;
  }

  /// 每顆讀卡機不含等待卡片回應的固定開銷 (暫存器設定、收尾等)，估算用
  static const int perReaderOverheadMs = 4;

  /// 無卡時一顆讀卡機的估計時間 (ms)
  static int noCardReaderMs(RfidTimingConfig timing) =>
      timing.rstSettleMs +
      timing.antennaSettleMs +
      timing.reqaTimeoutMs * timing.reqaAttempts +
      timing.interReaderGapMs +
      perReaderOverheadMs;

  /// 有卡時一顆讀卡機的估計時間 (ms)：REQA 幾乎立刻有回應
  static int cardReaderMs(RfidTimingConfig timing) =>
      timing.rstSettleMs +
      timing.antennaSettleMs +
      timing.interReaderGapMs +
      perReaderOverheadMs +
      2;

  /// 最壞情況一顆讀卡機的估計時間 (ms)：用到連線檢查的保險時間、
  /// 每次 REQA 都等到軟體牆鐘上限，而且每次都重新上電重讀到上限
  static int worstCaseReaderMs(RfidTimingConfig timing) {
    final perAttempt = timing.rstSettleMs +
        timing.linkCheckTimeoutMs +
        timing.antennaSettleMs +
        timing.effectiveCommDeadlineMs * timing.reqaAttempts +
        perReaderOverheadMs;
    return perAttempt * (1 + timing.readerRetries) + timing.interReaderGapMs;
  }

  /// 估算無卡時一輪掃描的時間 (ms)，只用全域值 (不看覆寫)
  int estimateNoCardScanMs(int readerCount) =>
      noCardReaderMs(withoutReaderOverrides()) * readerCount + postScanSettleMs;

  /// 估算無卡時一輪掃描的時間 (ms)，每顆用各自生效的值
  int estimateNoCardScanMsFor(Iterable<String> deviceIds) =>
      deviceIds.fold<int>(0, (sum, id) => sum + noCardReaderMs(forReader(id))) +
      postScanSettleMs;

  /// 估算七顆都有卡時一輪掃描的時間 (ms)，每顆用各自生效的值
  int estimateAllCardsScanMsFor(Iterable<String> deviceIds) =>
      deviceIds.fold<int>(0, (sum, id) => sum + cardReaderMs(forReader(id))) +
      postScanSettleMs;

  /// 估算最壞情況一輪的時間 (ms)。有覆寫時每顆取全域值與覆寫值中較大的那個。
  int estimateWorstCaseScanMs(int readerCount) {
    var worst = withoutReaderOverrides();
    for (final values in readerOverrides.values) {
      for (final entry in values.entries) {
        if (entry.value > worst.valueOf(entry.key)) {
          worst = worst.withValue(entry.key, entry.value);
        }
      }
    }
    return worstCaseReaderMs(worst) * readerCount + postScanSettleMs;
  }

  /// 整輪掃描實際使用的逾時：設定值與「最壞情況 × 2」取較大者，
  /// 避免把等待值調大之後整輪還沒跑完就被判定為卡死。
  Duration scanTimeoutFor(int readerCount) {
    final worstCaseMs = estimateWorstCaseScanMs(readerCount) * 2;
    final configuredMs = scanTimeoutSec * 1000;
    return Duration(
      milliseconds: worstCaseMs > configuredMs ? worstCaseMs : configuredMs,
    );
  }

  String _canonicalOverrides() {
    final buffer = StringBuffer();
    for (final id in overriddenReaderIds) {
      final entries = readerOverrides[id]!.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      buffer.write('$id:');
      for (final entry in entries) {
        buffer.write('${entry.key}=${entry.value},');
      }
      buffer.write(';');
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is RfidTimingConfig &&
      other.spiSpeedHz == spiSpeedHz &&
      other.rstSettleMs == rstSettleMs &&
      other.linkCheckTimeoutMs == linkCheckTimeoutMs &&
      other.antennaSettleMs == antennaSettleMs &&
      other.reqaTimeoutMs == reqaTimeoutMs &&
      other.reqaAttempts == reqaAttempts &&
      other.commDeadlineMs == commDeadlineMs &&
      other.interReaderGapMs == interReaderGapMs &&
      other.postScanSettleMs == postScanSettleMs &&
      other.scanTimeoutSec == scanTimeoutSec &&
      other.writeVerifyRetries == writeVerifyRetries &&
      other.anticollRetries == anticollRetries &&
      other.readerRetries == readerRetries &&
      other._canonicalOverrides() == _canonicalOverrides();

  @override
  int get hashCode => Object.hash(
        spiSpeedHz,
        rstSettleMs,
        linkCheckTimeoutMs,
        antennaSettleMs,
        reqaTimeoutMs,
        reqaAttempts,
        commDeadlineMs,
        interReaderGapMs,
        postScanSettleMs,
        scanTimeoutSec,
        writeVerifyRetries,
        anticollRetries,
        readerRetries,
        _canonicalOverrides(),
      );

  @override
  String toString() => 'RfidTimingConfig(${toJson()})';
}
