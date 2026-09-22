import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/adapters/mock_rfid_adapter.dart';
import 'package:smart_bite/interfaces/rfid_reader.dart';
import 'package:smart_bite/provider/rfid_reader_provider.dart';

/// deviceId → 卡片 UID (null 代表沒卡) 的模擬讀卡機
MockRFIDReaderManager _manager(Map<String, String?> cards) {
  final manager = MockRFIDReaderManager(scenario: 'empty');
  for (final entry in cards.entries) {
    final uid = entry.value;
    manager.addReader(MockRFIDAdapter(
      deviceId: entry.key,
      mockRfidSequence: uid == null ? [] : [uid],
      scanDelay: const Duration(milliseconds: 1),
    ));
  }
  return manager;
}

void main() {
  group('RFIDReaderProvider 同一張卡只算一次', () {
    test('單次掃描：多顆讀到相同 UID 只保留編號最小的那顆', () async {
      // 只接一顆、它的 RST 沒被拉低時的症狀：七個位置都讀到同一張卡
      final manager = _manager({
        for (var i = 1; i <= 7; i++) i.toString().padLeft(2, '0'): '88042BEA',
      });
      final provider = RFIDReaderProvider(readerManager: manager);
      await provider.updateReaders();

      expect(provider.orderNames, ['塔香虱目魚']);
      expect(provider.validCardCount, 1);
      expect(provider.duplicateReaderIds, ['02', '03', '04', '05', '06', '07']);
      expect(provider.duplicateOf('03'), '01');
      expect(provider.isDuplicate('01'), isFalse);
      expect(provider.isDuplicate('07'), isTrue);
      // 原始讀取結果不動，設定頁還是看得到每顆讀到什麼
      expect(provider.getReading('07')?.rfid, '88042BEA');
      expect(provider.validReadings.map((r) => r.deviceId), ['01']);
      expect(provider.effectiveReadings.length, 1);
      expect(provider.getStats()['valid'], 1);
      expect(provider.getStats()['identified'], 1);
    });

    test('不同卡片各算一次，只去掉重複的那幾顆', () async {
      final manager = _manager({
        '01': '88042BEA', // 塔香虱目魚
        '02': null,
        '03': 'A22038F6', // 八寶良糧粥
        '04': '88042BEA', // 01 的重複
        '05': 'A22038F6', // 03 的重複
      });
      final provider = RFIDReaderProvider(readerManager: manager);
      await provider.updateReaders();

      expect(provider.orderNames, ['塔香虱目魚', '八寶良糧粥']);
      expect(provider.duplicateReaderIds, ['04', '05']);
      expect(provider.duplicateOf('04'), '01');
      expect(provider.duplicateOf('05'), '03');
      expect(provider.duplicateOf('01'), isNull);
      expect(provider.errorReaderIds, isEmpty);
      // mock 會補到 7 顆，補上的沒卡也不算重複
      expect(provider.readerCount, 7);
      expect(provider.effectiveReadings.length, 5);
    });

    test('沒有重複時不標任何讀卡機', () async {
      final manager = _manager({'01': '88042BEA', '02': 'A22038F6'});
      final provider = RFIDReaderProvider(readerManager: manager);
      await provider.updateReaders();

      expect(provider.orderNames, ['塔香虱目魚', '八寶良糧粥']);
      expect(provider.duplicateReaderIds, isEmpty);
    });

    test('背景輪巡的黏性合併也會去重', () async {
      final manager = _manager({'01': '88042BEA', '02': '88042BEA'});
      final provider = RFIDReaderProvider(readerManager: manager);
      provider.startPolling();
      await provider.waitForFirstRound(timeout: const Duration(seconds: 5));
      await provider.stopPolling();

      expect(provider.pollRounds, greaterThanOrEqualTo(1));
      expect(provider.orderNames, ['塔香虱目魚']);
      expect(provider.duplicateReaderIds, ['02']);
    });
  });

  group('未啟用的讀卡機', () {
    test('RFIDReading.disabled 沒有卡片也不是錯誤', () {
      final reading = RFIDReading.disabled('03');
      expect(reading.status, ReaderStatus.disabled);
      expect(reading.hasCard, isFalse);
      expect(reading.errorMessage, isNull);
      expect(ReaderStatus.disabled.displayName, '未啟用');
    });

    test('狀態摘要有 disabled 欄位，mock 讀卡機全部啟用', () async {
      final manager = _manager({'01': null});
      final provider = RFIDReaderProvider(readerManager: manager);
      await provider.updateReaders();

      expect(provider.getReaderStatusSummary()['disabled'], 0);
      expect(provider.enabledReaderCount, provider.readerCount);
      expect(provider.allReadersOk, isTrue);
    });
  });
}
