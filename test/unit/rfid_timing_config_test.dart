import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/services/rfid_timing_config.dart';

void main() {
  group('RfidTimingConfig defaults', () {
    test('保守預設值符合 datasheet / Arduino library', () {
      const config = RfidTimingConfig.defaults;
      expect(config.spiSpeedHz, 1000000);
      expect(config.rstSettleMs, 50);
      expect(config.linkCheckTimeoutMs, 50);
      expect(config.antennaSettleMs, 5);
      expect(config.reqaTimeoutMs, 25);
      expect(config.reqaAttempts, 2);
      expect(config.commDeadlineMs, 36);
      expect(config.interReaderGapMs, 1);
      expect(config.postScanSettleMs, 0);
      expect(config.scanTimeoutSec, 10);
    });

    test('keys、ranges、labels 三者一致', () {
      expect(RfidTimingConfig.ranges.keys, containsAll(RfidTimingConfig.keys));
      expect(RfidTimingConfig.labels.keys, containsAll(RfidTimingConfig.keys));
      expect(RfidTimingConfig.defaults.toJson().keys,
          containsAll(RfidTimingConfig.keys));
    });

    test('effectiveCommDeadlineMs 至少比 REQA 逾時多 10 ms', () {
      expect(RfidTimingConfig.defaults.effectiveCommDeadlineMs, 36);
      const slow = RfidTimingConfig(reqaTimeoutMs: 100, commDeadlineMs: 36);
      expect(slow.effectiveCommDeadlineMs, 110);
    });

    test('整輪逾時至少是最壞情況的兩倍', () {
      const config = RfidTimingConfig.defaults;
      // 最壞情況每顆: 50 + 50 + 5 + 36×2 + 1 + 4 = 182 ms
      expect(config.estimateWorstCaseScanMs(1), 182);
      expect(config.scanTimeoutFor(7), const Duration(seconds: 10));

      const slow = RfidTimingConfig(
        rstSettleMs: 1000,
        reqaTimeoutMs: 1000,
        reqaAttempts: 10,
        scanTimeoutSec: 10,
      );
      expect(slow.scanTimeoutFor(7).inSeconds, greaterThan(10));
      expect(
        slow.scanTimeoutFor(7).inMilliseconds,
        slow.estimateWorstCaseScanMs(7) * 2,
      );
    });

    test('估計無卡一輪時間隨讀卡機數量線性成長', () {
      const config = RfidTimingConfig.defaults;
      final one = config.estimateNoCardScanMs(1);
      final seven = config.estimateNoCardScanMs(7);
      expect(seven, one * 7);
      // 50 + 5 + 25×2 + 1 + 4 = 110 ms/顆
      expect(one, 110);
      expect(seven, lessThan(1000));
    });
  });

  group('RfidTimingConfig JSON', () {
    test('toJson / fromJson 往返不變', () {
      const original = RfidTimingConfig(
        spiSpeedHz: 500000,
        rstSettleMs: 20,
        antennaSettleMs: 3,
        reqaAttempts: 3,
      );
      final restored = RfidTimingConfig.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.hashCode, original.hashCode);
    });

    test('fromJson 容忍字串、小數、未知欄位與缺欄位', () {
      final config = RfidTimingConfig.fromJson({
        'spiSpeedHz': '250000',
        'rstSettleMs': 12.7,
        'unknownKey': 42,
        'reqaAttempts': null,
      });
      expect(config.spiSpeedHz, 250000);
      expect(config.rstSettleMs, 12);
      expect(config.reqaAttempts, RfidTimingConfig.defaults.reqaAttempts);
      expect(config.antennaSettleMs, RfidTimingConfig.defaults.antennaSettleMs);
    });

    test('toPrettyJson 可被 jsonDecode 還原', () {
      const config = RfidTimingConfig(rstSettleMs: 30);
      final decoded = jsonDecode(config.toPrettyJson()) as Map<String, dynamic>;
      expect(decoded['rstSettleMs'], 30);
      expect(decoded.keys, containsAll(RfidTimingConfig.keys));
    });

    test('withValue 改單一欄位，未知欄位拋錯', () {
      final changed = RfidTimingConfig.defaults.withValue('antennaSettleMs', 9);
      expect(changed.antennaSettleMs, 9);
      expect(changed.rstSettleMs, RfidTimingConfig.defaults.rstSettleMs);
      expect(
        () => RfidTimingConfig.defaults.withValue('nope', 1),
        throwsArgumentError,
      );
      expect(changed.valueOf('antennaSettleMs'), 9);
      expect(() => changed.valueOf('nope'), throwsArgumentError);
    });
  });

  group('RfidTimingConfig validation', () {
    test('validated 把超出範圍的值夾回邊界', () {
      const wild = RfidTimingConfig(
        spiSpeedHz: 1,
        rstSettleMs: 99999,
        reqaAttempts: 0,
        scanTimeoutSec: 0,
        antennaSettleMs: -5,
      );
      final fixed = wild.validated();
      expect(fixed.spiSpeedHz, 50000);
      expect(fixed.rstSettleMs, 1000);
      expect(fixed.reqaAttempts, 1);
      expect(fixed.scanTimeoutSec, 1);
      expect(fixed.antennaSettleMs, 0);
      // 合理值不變
      expect(fixed.reqaTimeoutMs, wild.reqaTimeoutMs);
    });

    test('預設值本身就在範圍內', () {
      expect(RfidTimingConfig.defaults.validated(), RfidTimingConfig.defaults);
    });
  });

  group('RfidTimingConfig environment overrides', () {
    test('envKeyFor 把 camelCase 轉成 RFID_UPPER_SNAKE', () {
      expect(RfidTimingConfig.envKeyFor('spiSpeedHz'), 'RFID_SPI_SPEED_HZ');
      expect(RfidTimingConfig.envKeyFor('rstSettleMs'), 'RFID_RST_SETTLE_MS');
      expect(RfidTimingConfig.envKeyFor('reqaAttempts'), 'RFID_REQA_ATTEMPTS');
    });

    test('applyEnvironment 只覆寫有給且是整數的欄位', () {
      final applied = <String>[];
      final config = RfidTimingConfig.defaults.applyEnvironment(
        {
          'RFID_SPI_SPEED_HZ': '500000',
          'RFID_RST_SETTLE_MS': 'abc',
          'RFID_REQA_ATTEMPTS': ' 3 ',
          'UNRELATED': '1',
        },
        applied: applied,
      );
      expect(config.spiSpeedHz, 500000);
      expect(config.rstSettleMs, RfidTimingConfig.defaults.rstSettleMs);
      expect(config.reqaAttempts, 3);
      expect(applied, ['spiSpeedHz', 'reqaAttempts']);
    });
  });

  group('RfidTimingConfig.load', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('rfid_timing_test');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('沒有設定檔時用預設值並回報路徑', () async {
      final path = '${tempDir.path}/rfid_timing.json';
      final result = await RfidTimingConfig.load(
        filePath: path,
        environment: const {},
      );
      expect(result.config, RfidTimingConfig.defaults);
      expect(result.fileFound, isFalse);
      expect(result.filePath, path);
      expect(result.error, isNull);
      expect(result.sourceDescription, contains('預設值'));
    });

    test('讀取設定檔，環境變數再覆寫，最後做範圍檢查', () async {
      final path = '${tempDir.path}/rfid_timing.json';
      await File(path).writeAsString(jsonEncode({
        'spiSpeedHz': 500000,
        'rstSettleMs': 20,
        'reqaAttempts': 99,
      }));

      final result = await RfidTimingConfig.load(
        filePath: path,
        environment: const {'RFID_ANTENNA_SETTLE_MS': '8'},
      );
      expect(result.fileFound, isTrue);
      expect(result.config.spiSpeedHz, 500000);
      expect(result.config.rstSettleMs, 20);
      expect(result.config.antennaSettleMs, 8);
      // 99 超出範圍被夾回 10
      expect(result.config.reqaAttempts, 10);
      expect(result.envOverrides, ['antennaSettleMs']);
      expect(result.sourceDescription, contains(path));
      expect(result.sourceDescription, contains('antennaSettleMs'));
    });

    test('RFID_TIMING_FILE 環境變數優先於呼叫端路徑', () async {
      final envPath = '${tempDir.path}/from_env.json';
      final argPath = '${tempDir.path}/from_arg.json';
      await File(envPath).writeAsString(jsonEncode({'rstSettleMs': 15}));
      await File(argPath).writeAsString(jsonEncode({'rstSettleMs': 40}));

      final result = await RfidTimingConfig.load(
        filePath: argPath,
        environment: {RfidTimingConfig.fileEnvKey: envPath},
      );
      expect(result.filePath, envPath);
      expect(result.config.rstSettleMs, 15);
    });

    test('設定檔壞掉時回報錯誤並退回預設值', () async {
      final path = '${tempDir.path}/rfid_timing.json';
      await File(path).writeAsString('{not json');

      final result = await RfidTimingConfig.load(
        filePath: path,
        environment: const {},
      );
      expect(result.config, RfidTimingConfig.defaults);
      expect(result.fileFound, isFalse);
      expect(result.error, isNotNull);
      expect(result.sourceDescription, contains('讀取失敗'));
    });

    test('saveTo 會建立目錄並寫出可再讀回的 JSON', () async {
      final path = '${tempDir.path}/nested/dir/rfid_timing.json';
      const config = RfidTimingConfig(rstSettleMs: 25, spiSpeedHz: 250000);
      await config.saveTo(path);

      final result = await RfidTimingConfig.load(
        filePath: path,
        environment: const {},
      );
      expect(result.fileFound, isTrue);
      expect(result.config, config);
    });

    test('defaultFilePath 放在 HOME/Documents 底下', () {
      final path = RfidTimingConfig.defaultFilePath(
        environment: const {'HOME': '/home/pi'},
      );
      expect(path, contains('/home/pi'));
      expect(path, contains('Documents'));
      expect(path, endsWith(RfidTimingConfig.defaultFileName));
    });
  });
}
