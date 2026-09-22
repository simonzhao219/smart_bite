/// RC522 輪巡校正工具 (在 Raspberry Pi 上執行)
///
/// 執行前請先關閉 Smart Bite app，否則 GPIO 會顯示 busy。
///
/// 用法：
///   dart run scripts/rfid_calibrate.dart show
///   dart run scripts/rfid_calibrate.dart link [--speeds 1000000,500000,250000] [--samples 200] [--readers 1,2,3]
///   dart run scripts/rfid_calibrate.dart bench [--rounds 10] [--verbose]
///   dart run scripts/rfid_calibrate.dart sweep [--rst 5,10,20,50] [--antenna 0,2,5,10] [--rounds 5]
///   dart run scripts/rfid_calibrate.dart recommend [--write] [--speeds ...] [--samples N]
///   dart run scripts/rfid_calibrate.dart optimize [--write [--force]] [--sweep-rounds 8] [--verify-rounds 60] [--margin 1] [--skip-link] [--sweep-attempts]
///   dart run scripts/rfid_calibrate.dart set key=value [01.key=value ...] [01.clear] [clear]
///
/// 共同選項：
///   --file <path>   設定檔路徑。預設看 RFID_TIMING_FILE 環境變數，再來是 ~/Documents/rfid_timing.json
///                   (跟 app 用同一個函式決定，兩邊讀寫同一個檔案)
///   --readers 1,2,7 只測某幾顆 (link / bench / sweep / optimize 都支援)；
///                   沒選到的讀卡機 RST 仍會拉低，bus 上不會有別顆醒著。
///                   沒給時，設定檔的 enabledReaders 有值就只測那幾顆
///   --verbose       顯示每顆讀卡機的細節
///
/// 說明文件：documents/RFID_TIMING_TUNING.md
library;

import 'dart:io';

import 'package:dart_periphery/dart_periphery.dart';
import 'package:smart_bite/models/rfid_models.dart';
import 'package:smart_bite/services/mfrc522.dart';
import 'package:smart_bite/services/rfid_calibration.dart';
import 'package:smart_bite/services/rfid_optimizer.dart';
import 'package:smart_bite/services/rfid_polling_service.dart';
import 'package:smart_bite/services/rfid_timing_config.dart';
import 'package:smart_bite/services/simple_mfrc522.dart';

// ignore_for_file: avoid_print

const List<int> defaultSpeeds = [1000000, 500000, 250000];

Future<void> main(List<String> args) async {
  final _Options options;
  try {
    options = _Options.parse(args);
  } catch (e) {
    print('❌ 參數錯誤: $e');
    print('用 --help 看用法。');
    exit(1);
  }
  if (options.help || options.command == null) {
    _printHelp();
    exit(options.help ? 0 : 1);
  }

  try {
    switch (options.command) {
      case 'show':
        await _show(options);
      case 'link':
        await _link(options);
      case 'bench':
        await _bench(options);
      case 'sweep':
        await _sweep(options);
      case 'recommend':
        await _recommend(options);
      case 'optimize':
        await _optimize(options);
      case 'set':
        await _set(options);
      default:
        print('未知的指令: ${options.command}');
        _printHelp();
        exit(1);
    }
  } catch (e, stackTrace) {
    print('');
    print('❌ 執行失敗: $e');
    if (options.verbose) print(stackTrace);
    print('提示：請確認 app 已關閉、SPI 已啟用 (ls /dev/spidev*)，必要時用 sudo 執行。');
    exit(1);
  }
}

// ---------------------------------------------------------------------------
// 指令
// ---------------------------------------------------------------------------

Future<void> _show(_Options options) async {
  final load = await _loadTiming(options);
  _printTiming(load);
}

Future<void> _link(_Options options) async {
  final load = await _loadTiming(options);
  _printTiming(load);
  print('');
  print('▶ 連線品質量測 (每個時脈、每顆讀卡機各做 ${options.samples} 次讀寫檢查)');
  final measurements = await _measureLinks(options, load.config);
  print('');
  print(RfidCalibration.formatLinkTable(measurements));
  print('「就緒 ms」是 RST 拉高後 VersionReg 變成可讀的時間，rstSettleMs 只要比它大一些就夠。');
  print('「錯誤/樣本」不是 0 代表這個時脈下 SPI 線路不可靠，請降速或改善走線。');
}

Future<void> _bench(_Options options) async {
  final load = await _loadTiming(options);
  _printTiming(load);
  print('');
  final configs = _selectedConfigs(options, load.config);
  print('▶ 以目前設定跑 ${options.rounds} 輪完整掃描 (${configs.length} 顆)');
  final service = RFIDPollingService(
    timing: load.config,
    log: options.verbose ? print : null,
  );
  final parked = _parkUnselected(configs);
  try {
    final cycles =
        await _runRounds(service, configs, options.rounds, options.verbose);
    print('');
    print(RfidCalibration.formatBenchSummary(cycles));
  } finally {
    _releaseLines(parked);
  }
}

Future<void> _sweep(_Options options) async {
  final load = await _loadTiming(options);
  final base = load.config;
  final rstList = options.rst ?? [base.rstSettleMs];
  final antennaList = options.antenna ?? [base.antennaSettleMs];
  final configs = _selectedConfigs(options, base);

  _printTiming(load);
  print('');
  print('▶ 掃描不同的 rstSettleMs × antennaSettleMs 組合，每組跑 ${options.rounds} 輪');
  print('  請先把卡片放在要測試的讀卡機上；「有卡」欄位要等於輪數才算穩定。');
  print('');
  print(
    '${'rst ms'.padLeft(7)} ${'天線 ms'.padLeft(7)} ${'平均一輪 ms'.padLeft(11)}  '
    '各讀卡機有卡次數 (共 ${options.rounds} 輪)',
  );

  final parked = _parkUnselected(configs);
  try {
    for (final rst in rstList) {
      for (final antenna in antennaList) {
        final timing =
            base.copyWith(rstSettleMs: rst, antennaSettleMs: antenna);
        final service = RFIDPollingService(timing: timing);
        final cycles =
            await _runRounds(service, configs, options.rounds, false);
        final avg = cycles.map((c) => c.totalMs).reduce((a, b) => a + b) /
            cycles.length;
        final readerIds = <String>{for (final c in cycles) ...c.readers.keys}
            .toList()
          ..sort();
        final counts = readerIds.map((id) {
          final hits =
              cycles.where((c) => c.readers[id]?.hasCard == true).length;
          return '$id:$hits';
        }).join(' ');
        print(
          '${rst.toString().padLeft(7)} ${antenna.toString().padLeft(7)} '
          '${avg.toStringAsFixed(0).padLeft(11)}  $counts',
        );
      }
    }
  } finally {
    _releaseLines(parked);
  }
  print('');
  print('選最小但每顆都穩定讀到的組合，再用 set 指令寫入，例如：');
  print(
      '  dart run scripts/rfid_calibrate.dart set rstSettleMs=20 antennaSettleMs=5');
}

Future<void> _recommend(_Options options) async {
  final load = await _loadTiming(options);
  _printTiming(load);
  print('');
  print('▶ 連線品質量測');
  final measurements = await _measureLinks(options, load.config);
  print('');
  print(RfidCalibration.formatLinkTable(measurements));

  final recommendation = RfidCalibration.recommend(
    base: load.config,
    measurements: measurements,
  );
  print('▶ 建議');
  for (final note in recommendation.notes) {
    print('  • $note');
  }
  print('');
  print('建議設定：');
  print(recommendation.config.toPrettyJson());
  print('估計無卡一輪約 '
      '${recommendation.config.estimateNoCardScanMs(defaultReaderConfigs.length)} ms'
      ' (目前設定約 ${load.config.estimateNoCardScanMs(defaultReaderConfigs.length)} ms)');

  if (!options.write) {
    print('');
    print('加上 --write 會把 spiSpeedHz 與 rstSettleMs 寫入設定檔。');
    return;
  }

  final path = _configPath(options);
  final fileConfig = await _loadFileConfig(path);
  final merged = fileConfig.copyWith(
    spiSpeedHz: recommendation.config.spiSpeedHz,
    rstSettleMs: recommendation.config.rstSettleMs,
  );
  await merged.saveTo(path);
  print('');
  print('✓ 已寫入 $path');
  print('  app 下次掃描或按「重新載入設定檔」後生效。');
}

Future<void> _optimize(_Options options) async {
  final load = await _loadTiming(options);
  _printTiming(load);
  print('');
  final configs = _selectedConfigs(options, load.config);
  print('▶ 自動最佳化：請先在要測的 ${configs.length} 個感應器都放上卡片。');
  if (stdin.hasTerminal) {
    stdout.write('放好後按 Enter 開始 (Ctrl+C 取消)… ');
    stdin.readLineSync();
  }

  final optimizerOptions = RfidOptimizerOptions.defaults.copyWith(
    spiSpeeds: options.speeds,
    linkSamples: options.samples,
    sweepRounds: options.sweepRounds,
    verifyRounds: options.verifyRounds,
    marginSteps: options.margin,
    skipLinkStage: options.skipLink,
    sweepReqaAttempts: options.sweepAttempts,
  );
  final runner = HardwareOptimizerRunner(
    configs: configs,
    base: load.config,
    log: options.verbose ? print : null,
  );

  String? lastLine;
  final optimizer = RfidOptimizer(
    runner,
    options: optimizerOptions,
    onProgress: (progress) {
      final buffer = StringBuffer(
        '[${(progress.fraction * 100).toStringAsFixed(0).padLeft(3)}%] '
        '${progress.stage.label}: ${progress.message}',
      );
      if (progress.totalRounds > 0) {
        buffer.write(' (${progress.round}/${progress.totalRounds})');
      }
      if (progress.candidates.isNotEmpty) {
        final ids = progress.candidates.keys.toList()..sort();
        buffer.write(
          '  ${ids.map((id) => '$id:${progress.candidates[id]}').join(' ')}',
        );
      }
      final line = buffer.toString();
      if (line != lastLine) {
        print(line);
        lastLine = line;
      }
    },
  );

  final parked = _parkUnselected(configs);
  final OptimizationResult result;
  try {
    result = await optimizer.run(base: load.config);
  } finally {
    _releaseLines(parked);
  }

  print('');
  print('▶ 結果 (共 ${result.roundsRun} 輪，'
      '${(result.elapsedMs / 1000).toStringAsFixed(0)} 秒)');
  for (final note in result.notes) {
    print('  • $note');
  }
  print('');
  print(
    '${'讀卡機'.padRight(6)} ${'就緒'.padLeft(5)} ${'RST'.padLeft(5)} '
    '${'天線'.padLeft(5)} ${'REQA'.padLeft(5)} ${'次數'.padLeft(4)} '
    '${'驗證'.padLeft(7)} 狀態',
  );
  for (final id in result.deviceIds) {
    final r = result.readers[id]!;
    String value(String key) => r.values[key]?.toString() ?? '-';
    print(
      '${id.padRight(6)} ${(r.timeToReadyMs?.toString() ?? '-').padLeft(5)} '
      '${value('rstSettleMs').padLeft(5)} ${value('antennaSettleMs').padLeft(5)} '
      '${value('reqaTimeoutMs').padLeft(5)} ${value('reqaAttempts').padLeft(4)} '
      '${'${r.verifyHits}/${r.verifyRounds}'.padLeft(7)} '
      '${r.stable ? '穩定' : '不穩定：${r.note ?? ''}'}',
    );
  }
  print('');
  print('建議設定：');
  print(result.config.toPrettyJson());

  if (result.cancelled) return;
  if (!options.write) {
    print('');
    print('加上 --write 會把 SPI 時脈與穩定讀卡機的覆寫值寫入設定檔 (其他覆寫不動)。');
    return;
  }
  if (!result.allStable && !options.force) {
    print('');
    print('⚠ 讀卡機 ${result.unstableReaderIds.join('、')} 不穩定，沒有寫入。');
    print('  確認卡片放好後重跑；只想寫入穩定那幾顆的值請加 --force。');
    exitCode = 1;
    return;
  }

  final path = _configPath(options);
  final fileConfig = await _loadFileConfig(path);
  // 逐顆合併：只蓋掉穩定讀卡機掃描過的四個參數，檔案裡其他讀卡機與其他欄位的覆寫維持不變
  var merged = fileConfig.copyWith(spiSpeedHz: result.config.spiSpeedHz);
  final updated = <String>[];
  final kept = <String>[];
  for (final id in result.deviceIds) {
    final summary = result.readers[id]!;
    if (!summary.stable) {
      kept.add(id);
      continue;
    }
    merged = merged.withReaderOverrides(id, summary.values);
    updated.add(id);
  }
  await merged.saveTo(path);
  print('');
  print('✓ 已寫入 $path');
  if (fileConfig.spiSpeedHz != merged.spiSpeedHz) {
    print('  SPI 時脈 ${fileConfig.spiSpeedHz} → ${merged.spiSpeedHz} Hz');
  }
  if (updated.isNotEmpty) print('  更新覆寫: ${updated.join('、')}');
  if (kept.isNotEmpty) print('  維持原設定 (不穩定): ${kept.join('、')}');
  print('  其他讀卡機與欄位的覆寫維持不變。app 下次掃描或按「重新載入設定檔」後生效。');
}

Future<void> _set(_Options options) async {
  if (options.assignments.isEmpty) {
    print('用法: set key=value [01.key=value ...] [01.clear] [clear]');
    print('全域欄位: ${RfidTimingConfig.keys.join(', ')}');
    print('可對單顆覆寫的欄位: ${RfidTimingConfig.perReaderKeys.join(', ')}');
    print('啟用清單: enabledReaders=1,2 或 enabledReaders=all');
    exit(1);
  }

  final path = _configPath(options);
  var config = await _loadFileConfig(path);
  for (final assignment in options.assignments) {
    if (assignment == 'clear') {
      config = config.clearReaderOverrides();
      continue;
    }
    if (assignment.endsWith('.clear')) {
      config = config.clearReaderOverrides(_normalizeDeviceId(
        assignment.substring(0, assignment.length - '.clear'.length),
      ));
      continue;
    }
    final parts = assignment.split('=');
    if (parts.length != 2) {
      throw ArgumentError('格式錯誤: $assignment (應為 key=value 或 01.key=value)');
    }
    var key = parts[0].trim();
    if (key == RfidTimingConfig.enabledReadersKey) {
      // 啟用清單：enabledReaders=1,2 或 enabledReaders=all
      final raw = parts[1].trim();
      final numbers = raw == 'all'
          ? const <int>[]
          : RfidTimingConfig.parseReaderNumbers(raw);
      if (numbers == null) {
        throw ArgumentError(
          'enabledReaders 要是逗號分隔的讀卡機編號或 all: $assignment',
        );
      }
      config = config.copyWith(enabledReaders: numbers);
      continue;
    }
    final value = RfidTimingConfig.parseIntValue(parts[1]);
    if (value == null) {
      throw ArgumentError('不是整數: $assignment');
    }
    final dot = key.indexOf('.');
    if (dot > 0) {
      final deviceId = _normalizeDeviceId(key.substring(0, dot));
      key = key.substring(dot + 1);
      if (!RfidTimingConfig.perReaderKeys.contains(key)) {
        throw ArgumentError(
          '欄位 $key 不能對單顆覆寫 (可用: ${RfidTimingConfig.perReaderKeys.join(', ')})',
        );
      }
      config = config.withReaderOverride(deviceId, key, value);
    } else {
      if (!RfidTimingConfig.keys.contains(key)) {
        throw ArgumentError(
          '未知欄位: $key (可用: ${RfidTimingConfig.keys.join(', ')})',
        );
      }
      config = config.withValue(key, value);
    }
  }

  final validated = config.validated();
  if (validated != config) {
    print('⚠ 部分值超出允許範圍，已夾回邊界。');
  }
  await validated.saveTo(path);
  print('✓ 已寫入 $path');
  print(validated.toPrettyJson());
}

// ---------------------------------------------------------------------------
// 共用
// ---------------------------------------------------------------------------

/// 讀取生效中的設定 (檔案 + 環境變數)
Future<RfidTimingLoadResult> _loadTiming(_Options options) {
  if (options.file != null) {
    // --file 優先於 RFID_TIMING_FILE 環境變數
    final env = Map<String, String>.of(Platform.environment)
      ..remove(RfidTimingConfig.fileEnvKey);
    return RfidTimingConfig.load(filePath: options.file, environment: env);
  }
  return RfidTimingConfig.load();
}

/// 只讀設定檔本身 (不套環境變數)，寫回時才不會把環境變數的值寫死進檔案
Future<RfidTimingConfig> _loadFileConfig(String path) async {
  final load = await RfidTimingConfig.load(
    filePath: path,
    environment: const {},
  );
  if (load.error != null) {
    print('⚠ 設定檔讀取失敗 (${load.error})，將以預設值建立新檔');
  }
  return load.config;
}

String _configPath(_Options options) =>
    options.file ??
    Platform.environment[RfidTimingConfig.fileEnvKey] ??
    RfidTimingConfig.defaultFilePath();

/// `7` → `07`：覆寫的 key 是兩位數的 deviceId，寫成 `7.rstSettleMs` 也要能生效
String _normalizeDeviceId(String raw) {
  final number = int.tryParse(raw.trim());
  return number == null ? raw.trim() : number.toString().padLeft(2, '0');
}

/// 把沒被選到的讀卡機 RST 拉低並保持住，bus 上才不會有別顆醒著
/// (Pi 的 GPIO 4 預設是上拉，沒人驅動時那顆 RC522 會醒著搶 MISO)
List<GpioResetLine> _parkUnselected(List<ReaderConfig> selected) {
  final selectedPins = selected.map((c) => c.rstPin).toSet();
  final lines = <GpioResetLine>[];
  try {
    for (final config in defaultReaderConfigs) {
      if (selectedPins.contains(config.rstPin)) continue;
      lines.add(GpioResetLine(config.rstPin)..open());
    }
  } catch (_) {
    _releaseLines(lines);
    rethrow;
  }
  return lines;
}

void _releaseLines(List<GpioResetLine> lines) {
  for (final line in lines) {
    line.low();
    line.dispose();
  }
}

void _printTiming(RfidTimingLoadResult load) {
  print('設定來源: ${load.sourceDescription}');
  final json = load.config.toJson();
  for (final key in RfidTimingConfig.keys) {
    print('  ${key.padRight(20)} = ${json[key].toString().padLeft(8)}'
        '   ${RfidTimingConfig.labels[key]}');
  }
  for (final id in load.config.overriddenReaderIds) {
    final values = load.config.readerOverrides[id]!;
    print('  讀卡機 $id 覆寫: '
        '${values.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
  }
  final enabledCount = load.config
      .enabledDeviceIds(defaultReaderConfigs.map((c) => c.deviceId))
      .length;
  print('  ${RfidTimingConfig.enabledReadersLabel}: '
      '${load.config.enabledReadersText}');
  print('  估計無卡一輪約 ${load.config.estimateNoCardScanMs(enabledCount)} ms');
}

/// 要測的讀卡機：`--readers` 優先，沒給時看設定檔的 `enabledReaders`，再沒有就是全部。
/// 沒選到的讀卡機由呼叫端用 [_parkUnselected] 把 RST 拉低。
List<ReaderConfig> _selectedConfigs(_Options options, RfidTimingConfig config) {
  var selected = options.readers;
  if (selected == null || selected.isEmpty) {
    if (config.allReadersEnabled) return defaultReaderConfigs;
    selected = config.enabledReaders;
    print('  設定檔只啟用讀卡機 ${config.enabledReadersText}，其餘 RST 拉低不測'
        ' (要測全部請加 --readers 1,2,3,4,5,6,7)');
  }
  final configs = defaultReaderConfigs
      .where((config) => selected!.contains(config.deviceNum))
      .toList();
  if (configs.isEmpty) {
    throw ArgumentError('沒有符合的讀卡機編號: $selected');
  }
  return configs;
}

/// 每個時脈、每顆讀卡機各做一次連線品質量測
Future<List<LinkMeasurement>> _measureLinks(
  _Options options,
  RfidTimingConfig timing,
) async {
  final configs = _selectedConfigs(options, timing);
  final measurements = <LinkMeasurement>[];
  final lines = <int, GpioResetLine>{};

  try {
    // 所有 RST 先拉低 (包含沒被選到的)，bus 上才不會有別顆醒著
    for (final config in defaultReaderConfigs) {
      lines[config.deviceNum] = GpioResetLine(config.rstPin)..open();
    }

    for (final speed in options.speeds) {
      print('  SPI $speed Hz');
      final buses = <int, SPI>{};
      try {
        for (final config in configs) {
          final spi = buses.putIfAbsent(
            config.spiNum,
            () => SPI(config.spiNum, 0, SPImode.mode0, speed),
          );
          final reader = SimpleMFRC522(
            deviceNum: config.deviceNum,
            resetLine: lines[config.deviceNum]!,
            transport: SpiMfrc522Transport(spi),
            timing: timing.copyWith(spiSpeedHz: speed),
          );
          final probe = await reader.probeLink(samples: options.samples);
          measurements.add(LinkMeasurement(spiSpeedHz: speed, probe: probe));
          if (options.verbose) print('    $probe');
        }
      } finally {
        for (final spi in buses.values) {
          spi.dispose();
        }
      }
    }
  } finally {
    for (final line in lines.values) {
      line.low();
      line.dispose();
    }
  }
  return measurements;
}

Future<List<ScanCycleResult>> _runRounds(
  RFIDPollingService service,
  List<ReaderConfig> configs,
  int rounds,
  bool verbose,
) async {
  final cycles = <ScanCycleResult>[];
  for (var i = 1; i <= rounds; i++) {
    final cycle = await service.performOneLoopCycles(configs);
    cycles.add(cycle);
    if (verbose) {
      print('第 $i 輪: ${cycle.totalMs} ms，卡片 ${cycle.cardCount}，'
          '錯誤 ${cycle.errorReaderIds}');
      for (final result in cycle.readers.values) {
        print('   ${result.deviceId}: ${result.summary}');
      }
    } else {
      stdout.write('.');
    }
  }
  if (!verbose) print('');
  return cycles;
}

// ---------------------------------------------------------------------------
// 參數解析 (不依賴 args 套件)
// ---------------------------------------------------------------------------

class _Options {
  String? command;
  bool help = false;
  bool verbose = false;
  bool write = false;
  bool force = false;
  String? file;
  List<int> speeds = defaultSpeeds;
  int samples = 200;
  int rounds = 10;
  List<int>? readers;
  List<int>? rst;
  List<int>? antenna;
  int? sweepRounds;
  int? verifyRounds;
  int? margin;
  bool skipLink = false;
  bool sweepAttempts = false;
  final List<String> assignments = [];

  static const _flags = {
    'help',
    'h',
    'verbose',
    'v',
    'write',
    'w',
    'force',
    'skip-link',
    'sweep-attempts',
  };

  static _Options parse(List<String> args) {
    final options = _Options();
    var i = 0;
    while (i < args.length) {
      final arg = args[i];
      if (arg.startsWith('--') || (arg.startsWith('-') && arg.length == 2)) {
        var name = arg.replaceFirst(RegExp(r'^-+'), '');
        String? value;
        if (name.contains('=')) {
          final index = name.indexOf('=');
          value = name.substring(index + 1);
          name = name.substring(0, index);
        } else if (!_flags.contains(name) &&
            i + 1 < args.length &&
            !args[i + 1].startsWith('-')) {
          value = args[++i];
        }
        options._apply(name, value);
      } else if (options.command == null) {
        options.command = arg;
      } else {
        options.assignments.add(arg);
      }
      i++;
    }
    return options;
  }

  void _apply(String name, String? value) {
    switch (name) {
      case 'help':
      case 'h':
        help = true;
      case 'verbose':
      case 'v':
        verbose = true;
      case 'write':
      case 'w':
        write = true;
      case 'force':
        force = true;
      case 'file':
        file = _require(name, value);
      case 'speeds':
        speeds = _intList(name, _require(name, value));
      case 'samples':
        samples = _int(name, _require(name, value));
      case 'rounds':
        rounds = _int(name, _require(name, value));
      case 'readers':
        readers = _intList(name, _require(name, value));
      case 'rst':
        rst = _intList(name, _require(name, value));
      case 'antenna':
        antenna = _intList(name, _require(name, value));
      case 'sweep-rounds':
        sweepRounds = _int(name, _require(name, value));
      case 'verify-rounds':
        verifyRounds = _int(name, _require(name, value));
      case 'margin':
        margin = _nonNegative(name, _require(name, value));
      case 'skip-link':
        skipLink = true;
      case 'sweep-attempts':
        sweepAttempts = true;
      default:
        throw ArgumentError('未知的選項: --$name');
    }
  }

  static String _require(String name, String? value) {
    if (value == null || value.isEmpty) {
      throw ArgumentError('--$name 需要一個值');
    }
    return value;
  }

  static int _nonNegative(String name, String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed < 0) {
      throw ArgumentError('--$name 需要 0 或正整數，收到: $value');
    }
    return parsed;
  }

  static int _int(String name, String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == null || parsed <= 0) {
      throw ArgumentError('--$name 需要正整數，收到: $value');
    }
    return parsed;
  }

  static List<int> _intList(String name, String value) {
    final list = value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) {
      final parsed = int.tryParse(s);
      if (parsed == null || parsed < 0) {
        throw ArgumentError('--$name 需要整數清單，收到: $value');
      }
      return parsed;
    }).toList();
    if (list.isEmpty) throw ArgumentError('--$name 清單是空的');
    return list;
  }
}

void _printHelp() {
  print('''
RC522 輪巡校正工具 (請先關閉 Smart Bite app 再執行)

用法: dart run scripts/rfid_calibrate.dart <指令> [選項]

指令:
  show                     顯示目前生效的時序設定與來源
  link                     量測每顆讀卡機在各 SPI 時脈下的連線品質
                           選項: --speeds 1000000,500000,250000  --samples 200  --readers 1,2,3
  bench                    以目前設定跑多輪完整掃描，統計每輪耗時與每顆結果
                           選項: --rounds 10  --verbose
  sweep                    掃描不同 rstSettleMs / antennaSettleMs 組合的讀卡成功率 (請先放卡片)
                           選項: --rst 5,10,20,50  --antenna 0,2,5,10  --rounds 5
  recommend                量測後推薦 spiSpeedHz 與 rstSettleMs；加 --write 寫入設定檔
  optimize                 自動最佳化：連線檢測後，每顆讀卡機從目前值 (或候選最大值) 往小找
                           最小可靠值，讀不到時先往上放寬 (七顆都要放卡片)
                           加 --write 只寫入 SPI 時脈與穩定讀卡機的四個參數，其他覆寫不動；
                           有讀卡機不穩定時需要 --force 才寫
                           選項: --sweep-rounds 8  --verify-rounds 60  --margin 1  --skip-link
                                 --sweep-attempts (也掃 reqaAttempts，預設不掃)
  set key=value ...        直接修改設定檔，例如 set rstSettleMs=20 antennaSettleMs=5
                           單顆覆寫: set 07.rstSettleMs=30 07.antennaSettleMs=10 (7. 也可以)
                           清除覆寫: set 07.clear 或 set clear
                           只接了部分讀卡機: set enabledReaders=1,2 (全部: set enabledReaders=all)

共同選項:
  --file <path>            設定檔路徑 (預設: \$RFID_TIMING_FILE 或 ~/Documents/rfid_timing.json，跟 app 相同)
  --readers 1,2,7          只測某幾顆 (link / bench / sweep / optimize)，其餘 RST 仍拉低；
                           沒給時，設定檔的 enabledReaders 有值就只測那幾顆
  --verbose, -v            顯示細節
  --help, -h               顯示這份說明

可調欄位: ${RfidTimingConfig.keys.join(', ')}
可對單顆覆寫: ${RfidTimingConfig.perReaderKeys.join(', ')}
''');
}
