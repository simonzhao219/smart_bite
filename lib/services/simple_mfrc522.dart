/// 單顆 RC522 的「RST 選擇式」讀取流程 (純 Dart，不依賴 Flutter)
///
/// 七顆模組共用 SPI bus 與 CE0，只有 RST 各自獨立。
/// 讀某一顆時只把它的 RST 拉高，其餘保持 LOW (hard power-down)，
/// bus 上就只有一顆會回應。
///
/// 每顆的流程：
/// 1. RST 拉高 → 等 [RfidTimingConfig.rstSettleMs] 讓振盪器啟動
/// 2. 讀 VersionReg 確認 SPI 線路真的接到晶片 (線路異常會直接回報，不再假裝「沒有卡」)
/// 3. 設定暫存器、開天線 → 等 [RfidTimingConfig.antennaSettleMs] 讓卡片上電
/// 4. REQA (最多 [RfidTimingConfig.reqaAttempts] 次) → anticoll 取 UID
/// 5. 關天線、RST 拉低 (立即進 power-down，不需要等待)
library;

import 'dart:async';

import 'package:dart_periphery/dart_periphery.dart';

import 'mfrc522.dart';
import 'mfrc522_constants.dart';
import 'rfid_timing_config.dart';

/// RST 腳位抽象，單元測試用假物件
abstract class ResetLine {
  /// 開啟腳位並立刻拉低 (晶片進 hard power-down)
  void open();
  void high();
  void low();
  void dispose();
}

/// 用 dart_periphery GPIO 控制 RST 腳
class GpioResetLine implements ResetLine {
  final int pin;
  GPIO? _gpio;

  GpioResetLine(this.pin);

  bool get isOpen => _gpio != null;

  @override
  void open() {
    _gpio ??= GPIO(pin, GPIOdirection.gpioDirOutLow);
  }

  @override
  void high() {
    _gpio?.write(true);
  }

  @override
  void low() {
    _gpio?.write(false);
  }

  @override
  void dispose() {
    final gpio = _gpio;
    _gpio = null;
    gpio?.dispose();
  }
}

/// 一顆讀卡機一次讀取的結果分類
enum ReaderScanStatus {
  /// 讀到卡片
  card('有卡片'),

  /// 晶片正常，場內沒有卡
  noCard('沒有卡片'),

  /// VersionReg 讀不到合理值：SPI 線路或供電有問題
  linkError('線路異常'),

  /// 晶片一開始有回應，但送指令後在期限內沒有任何 IRQ
  commTimeout('晶片無回應'),

  /// 其他例外 (GPIO 打不開、SPI 失敗…)
  error('錯誤');

  final String label;

  const ReaderScanStatus(this.label);

  static ReaderScanStatus fromName(String? name) => values.firstWhere(
        (value) => value.name == name,
        orElse: () => ReaderScanStatus.error,
      );
}

/// 一顆讀卡機一次讀取的結果與診斷資訊
class ReaderScanResult {
  final String deviceId;
  final ReaderScanStatus status;

  /// 8 碼大寫十六進位 UID，沒有卡片時為 null
  final String? tagId;

  /// VersionReg 讀值，讀不到時為 null
  final int? version;

  /// RST 拉高後到 VersionReg 讀到合理值的時間 (ms)
  final int? timeToReadyMs;

  /// 這顆總共花的時間 (ms)
  final int elapsedMs;

  /// 實際送出的 REQA 次數
  final int attempts;

  /// 錯誤或補充說明
  final String? error;

  const ReaderScanResult({
    required this.deviceId,
    required this.status,
    this.tagId,
    this.version,
    this.timeToReadyMs,
    this.elapsedMs = 0,
    this.attempts = 0,
    this.error,
  });

  bool get hasCard =>
      status == ReaderScanStatus.card && tagId != null && tagId!.isNotEmpty;

  /// SPI 線路是否正常 (有卡或沒卡都算正常)
  bool get linkOk =>
      status == ReaderScanStatus.card || status == ReaderScanStatus.noCard;

  String get versionText =>
      version == null ? '-' : MFRC522Version.describe(version!);

  /// 一行摘要，給 log 與 CLI 用
  String get summary {
    final buffer = StringBuffer(status.label);
    if (tagId != null) buffer.write(' $tagId');
    buffer.write(' [');
    buffer.write(version == null
        ? 'v=-'
        : 'v=0x${version!.toRadixString(16).padLeft(2, '0').toUpperCase()}');
    if (timeToReadyMs != null) buffer.write(', ready ${timeToReadyMs}ms');
    if (attempts > 0) buffer.write(', reqa×$attempts');
    buffer.write(', ${elapsedMs}ms]');
    if (error != null) buffer.write(' $error');
    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'status': status.name,
        'tagId': tagId,
        'version': version,
        'timeToReadyMs': timeToReadyMs,
        'elapsedMs': elapsedMs,
        'attempts': attempts,
        'error': error,
      };

  factory ReaderScanResult.fromJson(Map<String, dynamic> json) =>
      ReaderScanResult(
        deviceId: json['deviceId'] as String,
        status: ReaderScanStatus.fromName(json['status'] as String?),
        tagId: json['tagId'] as String?,
        version: (json['version'] as num?)?.toInt(),
        timeToReadyMs: (json['timeToReadyMs'] as num?)?.toInt(),
        elapsedMs: (json['elapsedMs'] as num?)?.toInt() ?? 0,
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
        error: json['error'] as String?,
      );

  @override
  String toString() => 'ReaderScanResult($deviceId: $summary)';
}

/// 校正工具的連線品質量測結果
class LinkProbeResult {
  final String deviceId;

  /// RST 拉高後到 VersionReg 穩定可讀的時間 (ms)；一直讀不到為 null
  final int? timeToReadyMs;

  /// VersionReg 讀值 (未就緒時是最後一次讀到的值)
  final int version;

  /// 總共做了幾次讀寫檢查
  final int samples;

  /// 讀回值跟預期不符的次數
  final int mismatches;

  final int elapsedMs;

  const LinkProbeResult({
    required this.deviceId,
    required this.timeToReadyMs,
    required this.version,
    required this.samples,
    required this.mismatches,
    required this.elapsedMs,
  });

  bool get ready => timeToReadyMs != null;

  /// 就緒而且沒有任何讀寫錯誤
  bool get clean => ready && mismatches == 0;

  double get errorRate => samples == 0 ? 0 : mismatches / samples;

  @override
  String toString() =>
      'LinkProbeResult($deviceId: ready=${timeToReadyMs ?? '-'}ms, '
      'version=${MFRC522Version.describe(version)}, '
      'errors=$mismatches/$samples)';
}

/// 單顆 RC522 (RST 選擇式)
class SimpleMFRC522 {
  final int deviceNum;
  final ResetLine resetLine;
  final MFRC522 chip;
  final RfidTimingConfig timing;

  SimpleMFRC522({
    required this.deviceNum,
    required this.resetLine,
    required Mfrc522Transport transport,
    RfidTimingConfig? timing,
  })  : timing = timing ?? RfidTimingConfig.defaults,
        chip = MFRC522(
          transport,
          commDeadlineMs:
              (timing ?? RfidTimingConfig.defaults).effectiveCommDeadlineMs,
        );

  String get deviceId => deviceNum.toString().padLeft(2, '0');

  /// 開啟 RST 腳並拉低，讓晶片進 hard power-down
  void open() => resetLine.open();

  /// 讀一次卡片。不論結果如何，離開時天線關閉、RST 拉低。
  Future<ReaderScanResult> scanOnce() async {
    final stopwatch = Stopwatch()..start();
    int? version;
    int? readyMs;
    var attempts = 0;

    try {
      resetLine.high();
      await _sleep(timing.rstSettleMs);

      // 連線檢查：VersionReg 讀不到合理值就是線路問題，不用再往下做
      final linkDeadline = timing.rstSettleMs + timing.linkCheckTimeoutMs;
      version = chip.readVersion();
      while (!MFRC522Version.isPlausible(version!) &&
          stopwatch.elapsedMilliseconds < linkDeadline) {
        await _sleep(1);
        version = chip.readVersion();
      }
      if (!MFRC522Version.isPlausible(version) ||
          chip.readVersion() != version) {
        return ReaderScanResult(
          deviceId: deviceId,
          status: ReaderScanStatus.linkError,
          version: version,
          elapsedMs: stopwatch.elapsedMilliseconds,
          error: 'VersionReg=${MFRC522Version.describe(version)}',
        );
      }
      readyMs = stopwatch.elapsedMilliseconds;

      chip.configure(reqaTimeoutMs: timing.reqaTimeoutMs);
      await _sleep(timing.antennaSettleMs);

      var lastStatus = MFRC522Status.notag;
      while (attempts < timing.reqaAttempts) {
        attempts++;
        final request = chip.request(PICCCommands.reqidl);
        lastStatus = request.status;
        if (request.status == MFRC522Status.ok) {
          final anticoll = chip.anticoll();
          lastStatus = anticoll.status;
          if (anticoll.status == MFRC522Status.ok) {
            return ReaderScanResult(
              deviceId: deviceId,
              status: ReaderScanStatus.card,
              tagId: uidToHex(anticoll.uid),
              version: version,
              timeToReadyMs: readyMs,
              elapsedMs: stopwatch.elapsedMilliseconds,
              attempts: attempts,
            );
          }
        }
        // 晶片連 timer IRQ 都沒舉起，代表線路出了問題，重試沒有意義
        if (lastStatus == MFRC522Status.timeout) break;
      }

      return ReaderScanResult(
        deviceId: deviceId,
        status: lastStatus == MFRC522Status.timeout
            ? ReaderScanStatus.commTimeout
            : ReaderScanStatus.noCard,
        version: version,
        timeToReadyMs: readyMs,
        elapsedMs: stopwatch.elapsedMilliseconds,
        attempts: attempts,
        error: lastStatus == MFRC522Status.notag
            ? null
            : 'last status: ${MFRC522Status.describe(lastStatus)}',
      );
    } catch (e) {
      return ReaderScanResult(
        deviceId: deviceId,
        status: ReaderScanStatus.error,
        version: version,
        timeToReadyMs: readyMs,
        elapsedMs: stopwatch.elapsedMilliseconds,
        attempts: attempts,
        error: e.toString(),
      );
    } finally {
      try {
        chip.antennaOff();
      } catch (_) {
        // 線路異常時關天線可能失敗，RST 拉低後 RF 場一樣會關閉
      }
      resetLine.low();
    }
  }

  /// 量測這顆的連線品質 (給校正工具用)：
  /// 1. RST 拉高後每 1 ms 讀一次 VersionReg，記錄多久才穩定可讀
  /// 2. 做 [samples] 次「寫入再讀回」與 VersionReg 一致性檢查，統計錯誤次數
  Future<LinkProbeResult> probeLink({
    int samples = 200,
    int maxReadyMs = 300,
  }) async {
    final stopwatch = Stopwatch()..start();
    int? readyMs;
    var version = 0;
    var mismatches = 0;
    var checks = 0;

    try {
      resetLine.high();
      while (stopwatch.elapsedMilliseconds <= maxReadyMs) {
        version = chip.readVersion();
        if (MFRC522Version.isPlausible(version) &&
            chip.readVersion() == version) {
          readyMs = stopwatch.elapsedMilliseconds;
          break;
        }
        await _sleep(1);
      }

      if (readyMs != null) {
        for (var i = 0; i < samples; i++) {
          final pattern = i.isEven ? 0x55 : 0xAA;
          checks += 2;
          if (!chip.writeReadBack(pattern)) mismatches++;
          if (chip.readVersion() != version) mismatches++;
        }
      }

      return LinkProbeResult(
        deviceId: deviceId,
        timeToReadyMs: readyMs,
        version: version,
        samples: checks,
        mismatches: mismatches,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    } finally {
      resetLine.low();
    }
  }

  /// RST 拉低並釋放 GPIO
  Future<void> dispose() async {
    resetLine.low();
    resetLine.dispose();
  }

  /// UID 前 4 bytes 轉成 8 碼大寫十六進位字串，與 Arduino printHex 相同
  /// 例：[0xA2, 0x20, 0x38, 0xF6] → "A22038F6"
  static String uidToHex(List<int> uid) {
    final buffer = StringBuffer();
    for (var i = 0; i < 4 && i < uid.length; i++) {
      buffer.write(uid[i].toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static Future<void> _sleep(int milliseconds) {
    if (milliseconds <= 0) return Future<void>.value();
    return Future<void>.delayed(Duration(milliseconds: milliseconds));
  }
}
