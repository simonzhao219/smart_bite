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

  /// SPI 時脈 (Hz)。線長、負載重時可降到 500000 或 250000，
  /// 每次傳輸只有 2 bytes，降速對整輪時間影響很小。
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
  });

  /// 程式內建預設值
  static const RfidTimingConfig defaults = RfidTimingConfig();

  /// 所有可調欄位的名稱 (同時也是 JSON key)
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
  };

  /// 軟體等待 IRQ 的實際上限
  int get effectiveCommDeadlineMs =>
      commDeadlineMs < reqaTimeoutMs + 10 ? reqaTimeoutMs + 10 : commDeadlineMs;

  Map<String, int> toJson() => {
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
      };

  /// 從 JSON 建立。缺少或型別不對的欄位沿用 [base] 的值。
  factory RfidTimingConfig.fromJson(
    Map<String, dynamic> json, {
    RfidTimingConfig base = defaults,
  }) {
    int pick(String key, int fallback) => parseIntValue(json[key]) ?? fallback;

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
    );
  }

  /// 把 JSON、環境變數裡的值轉成整數；轉不出來就回 null。
  static int? parseIntValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// 讀取單一欄位
  int valueOf(String key) {
    final value = toJson()[key];
    if (value == null) {
      throw ArgumentError.value(key, 'key', '不是有效的時序欄位');
    }
    return value;
  }

  /// 回傳改了單一欄位的新設定
  RfidTimingConfig withValue(String key, int value) {
    if (!keys.contains(key)) {
      throw ArgumentError.value(key, 'key', '不是有效的時序欄位');
    }
    final json = Map<String, dynamic>.from(toJson());
    json[key] = value;
    return RfidTimingConfig.fromJson(json, base: this);
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
    );
  }

  /// 把每個欄位夾回 [ranges] 定義的範圍
  RfidTimingConfig validated() {
    final json = Map<String, dynamic>.from(toJson());
    for (final key in keys) {
      final (low, high) = ranges[key]!;
      final value = json[key] as int;
      json[key] = value < low ? low : (value > high ? high : value);
    }
    return RfidTimingConfig.fromJson(json, base: this);
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

  /// 套用環境變數覆寫。[applied] 會收到實際被覆寫的欄位名稱。
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
  };

  /// 「中文標籤 → 值」的對照，給 UI 顯示
  Map<String, String> describe() {
    final json = toJson();
    return {
      for (final key in keys) labels[key]!: json[key].toString(),
    };
  }

  /// 估算無卡時一輪掃描的時間 (ms)，給文件與 UI 做參考。
  ///
  /// 每顆約需：RST 等待 + 暫存器設定 (約 2 ms) + 天線等待 +
  /// 每次 REQA 的晶片逾時 × 次數 + 收尾 (約 2 ms) + 讀卡機間隔。
  int estimateNoCardScanMs(int readerCount) {
    const overheadPerReaderMs = 4;
    final perReader = rstSettleMs +
        antennaSettleMs +
        reqaTimeoutMs * reqaAttempts +
        interReaderGapMs +
        overheadPerReaderMs;
    return perReader * readerCount + postScanSettleMs;
  }

  /// 估算最壞情況一輪的時間 (ms)：每顆都用到連線檢查的保險時間、
  /// 每次 REQA 都等到軟體牆鐘上限。整輪逾時會以它的兩倍為下限。
  int estimateWorstCaseScanMs(int readerCount) {
    const overheadPerReaderMs = 4;
    final perReader = rstSettleMs +
        linkCheckTimeoutMs +
        antennaSettleMs +
        effectiveCommDeadlineMs * reqaAttempts +
        interReaderGapMs +
        overheadPerReaderMs;
    return perReader * readerCount + postScanSettleMs;
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
      other.scanTimeoutSec == scanTimeoutSec;

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
      );

  @override
  String toString() => 'RfidTimingConfig(${toJson()})';
}
