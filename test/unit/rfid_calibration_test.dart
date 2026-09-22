import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/services/rfid_calibration.dart';
import 'package:smart_bite/services/rfid_polling_service.dart';
import 'package:smart_bite/services/rfid_timing_config.dart';
import 'package:smart_bite/services/simple_mfrc522.dart';

LinkMeasurement measure({
  required String deviceId,
  required int speed,
  int? readyMs,
  int mismatches = 0,
  int samples = 400,
  int version = 0x92,
}) =>
    LinkMeasurement(
      spiSpeedHz: speed,
      probe: LinkProbeResult(
        deviceId: deviceId,
        timeToReadyMs: readyMs,
        version: version,
        samples: readyMs == null ? 0 : samples,
        mismatches: mismatches,
        elapsedMs: 50,
      ),
    );

void main() {
  group('RfidCalibration.recommend', () {
    test('選所有讀卡機都零錯誤的最高時脈，並下修 rstSettleMs', () {
      final measurements = [
        measure(deviceId: '01', speed: 1000000, readyMs: 2, mismatches: 3),
        measure(deviceId: '02', speed: 1000000, readyMs: 3),
        measure(deviceId: '01', speed: 500000, readyMs: 2),
        measure(deviceId: '02', speed: 500000, readyMs: 4),
        measure(deviceId: '01', speed: 250000, readyMs: 2),
        measure(deviceId: '02', speed: 250000, readyMs: 3),
      ];

      final rec = RfidCalibration.recommend(
        base: RfidTimingConfig.defaults,
        measurements: measurements,
      );

      expect(rec.config.spiSpeedHz, 500000);
      // 最慢 4 ms 就緒 → 4×2+5 = 13 ms
      expect(rec.config.rstSettleMs, 13);
      expect(rec.allReadersReady, isTrue);
      expect(rec.notes.join('\n'), contains('500000'));
      expect(rec.notes.join('\n'), contains('下修'));
      // 其他欄位不動
      expect(rec.config.antennaSettleMs,
          RfidTimingConfig.defaults.antennaSettleMs);
    });

    test('rstSettleMs 不低於 10 ms，也不高於目前值', () {
      final fast = RfidCalibration.recommend(
        base: RfidTimingConfig.defaults,
        measurements: [measure(deviceId: '01', speed: 1000000, readyMs: 0)],
      );
      expect(fast.config.rstSettleMs, RfidCalibration.minRstSettleMs);

      final slow = RfidCalibration.recommend(
        base: const RfidTimingConfig(rstSettleMs: 20),
        measurements: [measure(deviceId: '01', speed: 1000000, readyMs: 40)],
      );
      expect(slow.config.rstSettleMs, 20);
      expect(slow.notes.join('\n'), contains('維持'));
    });

    test('沒有全乾淨的時脈：取錯誤最少的，並提醒檢查走線', () {
      final measurements = [
        measure(deviceId: '01', speed: 1000000, readyMs: 2, mismatches: 10),
        measure(deviceId: '01', speed: 500000, readyMs: 2, mismatches: 2),
        measure(deviceId: '01', speed: 250000, readyMs: 2, mismatches: 5),
      ];
      final rec = RfidCalibration.recommend(
        base: RfidTimingConfig.defaults,
        measurements: measurements,
      );
      expect(rec.config.spiSpeedHz, 500000);
      expect(rec.notes.join('\n'), contains('走線'));
    });

    test('某顆在所有時脈都未就緒：記在 notes，其餘讀卡機照常推薦', () {
      final measurements = [
        measure(deviceId: '01', speed: 1000000, readyMs: 2),
        measure(deviceId: '07', speed: 1000000, readyMs: null, version: 0x00),
        measure(deviceId: '01', speed: 500000, readyMs: 2),
        measure(deviceId: '07', speed: 500000, readyMs: null, version: 0x00),
      ];
      final rec = RfidCalibration.recommend(
        base: RfidTimingConfig.defaults,
        measurements: measurements,
      );
      expect(rec.allReadersReady, isFalse);
      expect(rec.notes.join('\n'), contains('07'));
      // 未就緒的那顆不算乾淨，所以沒有全乾淨的時脈；兩個時脈就緒數與錯誤數都相同，
      // 同分取較高時脈
      expect(rec.config.spiSpeedHz, 1000000);
    });

    test('退路計分：就緒的讀卡機越多越優先，「完全讀不到」不能贏過「就緒但有錯」', () {
      // 07 在 1 MHz 完全讀不到 VersionReg，在 500 kHz 就緒但有 2 個位元錯誤；
      // 舊的計分把未就緒算成 1 個錯誤，會反過來選 1 MHz
      final measurements = [
        measure(deviceId: '01', speed: 1000000, readyMs: 2),
        measure(deviceId: '07', speed: 1000000, readyMs: null, version: 0x00),
        measure(deviceId: '01', speed: 500000, readyMs: 2),
        measure(deviceId: '07', speed: 500000, readyMs: 3, mismatches: 2),
      ];
      final rec = RfidCalibration.recommend(
        base: RfidTimingConfig.defaults,
        measurements: measurements,
      );
      expect(rec.config.spiSpeedHz, 500000);
      expect(rec.allReadersReady, isTrue);
      expect(rec.notes.join('\n'), contains('就緒'));
      expect(rec.notes.join('\n'), contains('走線'));
    });

    test('沒有量測資料時維持原設定', () {
      const base = RfidTimingConfig(rstSettleMs: 30);
      final rec = RfidCalibration.recommend(base: base, measurements: const []);
      expect(rec.config, base);
      expect(rec.allReadersReady, isFalse);
    });
  });

  group('RfidCalibration formatting', () {
    test('formatLinkTable 列出每顆與時脈', () {
      final table = RfidCalibration.formatLinkTable([
        measure(deviceId: '01', speed: 1000000, readyMs: 2),
        measure(deviceId: '02', speed: 1000000, readyMs: null, version: 0xFF),
        measure(deviceId: '01', speed: 500000, readyMs: 2, mismatches: 4),
      ]);
      expect(table, contains('1000000'));
      expect(table, contains('500000'));
      expect(table, contains('OK'));
      expect(table, contains('未就緒'));
      expect(table, contains('錯誤率'));
      expect(table, contains('0x92'));
      expect(table, contains('0xFF'));
    });

    test('formatBenchSummary 統計輪數與每顆狀態', () {
      final cycles = [
        const ScanCycleResult(totalMs: 600, readers: {
          '01': ReaderScanResult(
            deviceId: '01',
            status: ReaderScanStatus.card,
            tagId: 'A22038F6',
            elapsedMs: 40,
          ),
          '02': ReaderScanResult(
            deviceId: '02',
            status: ReaderScanStatus.linkError,
            elapsedMs: 100,
          ),
        }),
        const ScanCycleResult(totalMs: 700, readers: {
          '01': ReaderScanResult(
            deviceId: '01',
            status: ReaderScanStatus.noCard,
            elapsedMs: 80,
          ),
          '02': ReaderScanResult(
            deviceId: '02',
            status: ReaderScanStatus.commTimeout,
            elapsedMs: 120,
          ),
        }),
      ];
      final summary = RfidCalibration.formatBenchSummary(cycles);
      expect(summary, contains('共 2 輪'));
      expect(summary, contains('平均 650 ms'));
      expect(summary, contains('最快 600 ms'));
      expect(summary, contains('最慢 700 ms'));
      expect(summary, contains('01'));
      expect(summary, contains('02'));
    });

    test('空資料不會拋錯', () {
      expect(RfidCalibration.formatLinkTable(const []), isNotEmpty);
      expect(RfidCalibration.formatBenchSummary(const []), isNotEmpty);
    });
  });

  group('ScanCycleResult', () {
    test('JSON 往返與錯誤讀卡機清單', () {
      const cycle = ScanCycleResult(totalMs: 512, readers: {
        '01': ReaderScanResult(
          deviceId: '01',
          status: ReaderScanStatus.card,
          tagId: 'A22038F6',
          elapsedMs: 40,
        ),
        '03': ReaderScanResult(
          deviceId: '03',
          status: ReaderScanStatus.linkError,
          version: 0,
          elapsedMs: 100,
          error: 'VersionReg=0x00',
        ),
        '02': ReaderScanResult(
          deviceId: '02',
          status: ReaderScanStatus.noCard,
          elapsedMs: 60,
        ),
      });

      final restored = ScanCycleResult.fromJson(cycle.toJson());
      expect(restored.totalMs, 512);
      expect(restored.cardCount, 1);
      expect(restored.errorReaderIds, ['03']);
      expect(restored.readers['01']!.tagId, 'A22038F6');
      expect(restored.readers['03']!.error, 'VersionReg=0x00');
      expect(restored.toString(), contains('512ms'));
    });
  });

  group('LinkMeasurement JSON', () {
    test('往返', () {
      final measurement = measure(
        deviceId: '04',
        speed: 500000,
        readyMs: 3,
        mismatches: 2,
        version: 0x91,
      );
      final restored = LinkMeasurement.fromJson(measurement.toJson());
      expect(restored.spiSpeedHz, 500000);
      expect(restored.probe.deviceId, '04');
      expect(restored.probe.timeToReadyMs, 3);
      expect(restored.probe.mismatches, 2);
      expect(restored.probe.samples, 400);
      expect(restored.probe.version, 0x91);
      expect(restored.probe.clean, isFalse);
    });
  });
}
