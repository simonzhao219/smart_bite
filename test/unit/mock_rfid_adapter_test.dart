import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/adapters/mock_rfid_adapter.dart';
import 'package:smart_bite/interfaces/rfid_reader.dart';

void main() {
  group('MockRFIDAdapter', () {
    test('should return valid RFID reading when card present', () async {
      final adapter = MockRFIDAdapter(
        deviceId: '01',
        mockRfidSequence: ['A22038F6'],
        scanDelay: const Duration(milliseconds: 10),
      );

      await adapter.connect();
      final reading = await adapter.scan();

      expect(reading.deviceId, '01');
      expect(reading.status, ReaderStatus.ok);
      expect(reading.rfid, 'A22038F6');
      expect(reading.hasCard, true);
    });

    test('should return reading with empty RFID when no card present', () async {
      final adapter = MockRFIDAdapter(
        deviceId: '02',
        mockRfidSequence: [],
        scanDelay: const Duration(milliseconds: 10),
      );

      await adapter.connect();
      final reading = await adapter.scan();

      expect(reading.deviceId, '02');
      expect(reading.status, ReaderStatus.ok);
      expect(reading.rfid, ''); // Empty RFID
      expect(reading.hasCard, false);
    });

    test('should cycle through multiple RFIDs', () async {
      final adapter = MockRFIDAdapter(
        deviceId: '03',
        mockRfidSequence: ['RFID001', 'RFID002', 'RFID003'],
        scanDelay: const Duration(milliseconds: 10),
      );

      await adapter.connect();
      
      final reading1 = await adapter.scan();
      expect(reading1.rfid, 'RFID001');

      final reading2 = await adapter.scan();
      expect(reading2.rfid, 'RFID002');

      final reading3 = await adapter.scan();
      expect(reading3.rfid, 'RFID003');

      // Should cycle back to first
      final reading4 = await adapter.scan();
      expect(reading4.rfid, 'RFID001');
    });

    test('should report connected status', () async {
      final adapter = MockRFIDAdapter(deviceId: '05');
      
      expect(adapter.isConnected, false);
      await adapter.connect();
      expect(adapter.isConnected, true);
      await adapter.disconnect();
      expect(adapter.isConnected, false);
    });
  });

  group('MockRFIDReaderManager', () {
    test('full_meal scenario should return 7 readers with valid RFIDs', () async {
      final manager = MockRFIDReaderManager(scenario: 'full_meal');

      await manager.discoverReaders();
      expect(manager.readers.length, 7);

      final readings = await manager.scanAll();
      expect(readings.length, 7);
      expect(readings.every((r) => r.status == ReaderStatus.ok), true);
      expect(readings.every((r) => r.hasCard), true);
    });

    test('partial scenario should return mix of cards and empty', () async {
      final manager = MockRFIDReaderManager(scenario: 'partial');

      await manager.discoverReaders();
      final readings = await manager.scanAll();

      final validReadings = readings.where((r) => r.hasCard).toList();
      final emptyReadings = readings.where((r) => !r.hasCard).toList();

      expect(validReadings.length, greaterThan(0));
      expect(emptyReadings.length, greaterThan(0));
      expect(validReadings.length + emptyReadings.length, readings.length);
    });

    test('errors scenario should not crash', () async {
      final manager = MockRFIDReaderManager(scenario: 'errors');

      await manager.discoverReaders();
      final readings = await manager.scanAll();

      // Manager should work without crashing
      expect(readings, isNotNull);
      expect(manager.readers, isNotEmpty);
    }, skip: 'Mock adapter error scenario needs implementation');

    test('empty scenario should discover no readers and scan no cards',
        () async {
      final manager = MockRFIDReaderManager(scenario: 'empty');

      await manager.discoverReaders();
      expect(manager.readers.length, 0);

      // scanAll() pads the list to 7 readers (like the GPIO adapter), so the
      // empty scenario yields 7 readings, none of which has a card.
      final readings = await manager.scanAll();
      expect(readings.length, 7);
      expect(readings.any((r) => r.hasCard), isFalse);
    });

    test('should provide valid readings accessor', () async {
      final manager = MockRFIDReaderManager(scenario: 'partial');

      await manager.discoverReaders();
      await manager.scanAll();

      final validReadings = manager.validReadings;
      expect(validReadings.every((r) => r.hasCard), true);
    });
  });
}
