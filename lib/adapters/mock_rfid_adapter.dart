/// Mock RFID Adapter
///
/// Provides a mock implementation of the RFIDReader interface for testing
/// without requiring physical hardware. Useful for:
/// - Unit testing business logic
/// - UI development and testing
/// - Demonstrations without hardware
/// - Regression testing
library;

import 'dart:async';

import 'package:flutter/material.dart';
import '../interfaces/rfid_reader.dart';

/// Mock RFID reader that simulates reading behavior
class MockRFIDAdapter implements RFIDReader {
  final String _deviceId;
  final String _address;
  final List<String> _mockRfidSequence;
  final Duration _scanDelay;

  ReaderStatus _status = ReaderStatus.init;
  int _currentIndex = 0;

  final StreamController<RFIDReading> _readingsController =
      StreamController<RFIDReading>.broadcast();

  /// Create a mock RFID reader
  ///
  /// [deviceId] - Unique identifier (e.g., "01", "02")
  /// [address] - Mock address (e.g., "MOCK_01")
  /// [mockRfidSequence] - List of RFID UIDs to return in sequence (cycles through)
  /// [scanDelay] - Simulated delay for scanning operations
  MockRFIDAdapter({
    required String deviceId,
    String? address,
    List<String>? mockRfidSequence,
    Duration scanDelay = const Duration(milliseconds: 500),
  })  : _deviceId = deviceId,
        _address = address ?? 'MOCK_$deviceId',
        _mockRfidSequence = mockRfidSequence ?? [],
        _scanDelay = scanDelay;

  @override
  String get deviceId => _deviceId;

  @override
  String get address => _address;

  @override
  ReaderStatus get status => _status;

  @override
  Stream<RFIDReading> get readings => _readingsController.stream;

  @override
  bool get isConnected =>
      _status != ReaderStatus.init && _status != ReaderStatus.disconnected;

  @override
  Future<void> connect() async {
    await Future.delayed(const Duration(milliseconds: 100));
    _status = ReaderStatus.ok;
    debugPrint('[$_address] Mock reader connected');
  }

  @override
  Future<void> disconnect() async {
    _status = ReaderStatus.disconnected;
    // Protect against double-dispose
    if (!_readingsController.isClosed) {
      await _readingsController.close();
    }
    debugPrint('[$_address] Mock reader disconnected');
  }

  @override
  Future<RFIDReading> scan() async {
    _status = ReaderStatus.updating;

    // Simulate scanning delay
    await Future.delayed(_scanDelay);

    RFIDReading reading;

    if (_mockRfidSequence.isEmpty) {
      // No cards configured
      reading = RFIDReading(
        deviceId: _deviceId,
        status: ReaderStatus.ok,
        rfid: '',
        timestamp: DateTime.now(),
        rawData: 'MOCK_NO_CARD',
      );
    } else {
      // Return next RFID in sequence (cycle through)
      final rfid = _mockRfidSequence[_currentIndex];
      _currentIndex = (_currentIndex + 1) % _mockRfidSequence.length;

      reading = RFIDReading.success(_deviceId, rfid);
    }

    _status = ReaderStatus.ok;
    _readingsController.add(reading);

    debugPrint('[$_address] Mock scan result: ${reading.rfid}');
    return reading;
  }

  /// Add an RFID to the mock sequence
  void addMockRfid(String rfid) {
    _mockRfidSequence.add(rfid);
  }

  /// Clear all mock RFIDs
  void clearMockRfids() {
    _mockRfidSequence.clear();
    _currentIndex = 0;
  }

  /// Simulate an error on next scan
  Future<RFIDReading> simulateError(String errorMessage) async {
    _status = ReaderStatus.updating;
    await Future.delayed(_scanDelay);

    final reading = RFIDReading.error(_deviceId, errorMessage);
    _status = ReaderStatus.error;
    _readingsController.add(reading);

    return reading;
  }
}

/// Mock RFID Reader Manager with predefined test data
class MockRFIDReaderManager extends ChangeNotifier
    implements RFIDReaderManager {
  List<MockRFIDAdapter> _readers = [];
  final Map<String, RFIDReading> _latestReadings = {};
  Duration? _lastScanDuration;

  /// Create a manager with predefined test scenario
  ///
  /// [scenario] options:
  /// - 'empty': No readers
  /// - 'full_meal': 7 readers with valid meal RFIDs
  /// - 'partial': Some readers with cards, some without
  /// - 'errors': Some readers in error state
  MockRFIDReaderManager({String scenario = 'full_meal'}) {
    _initializeScenario(scenario);
  }

  void _initializeScenario(String scenario) {
    switch (scenario) {
      case 'empty':
        _readers = [];
        break;

      case 'full_meal':
        // 7 readers, each with a different valid meal RFID
        _readers = [
          MockRFIDAdapter(
              deviceId: '01', mockRfidSequence: ['A22038F6']), // 八寶良糧粥
          MockRFIDAdapter(
              deviceId: '02', mockRfidSequence: ['A22438F6']), // 三杯鬼頭刀魚
          MockRFIDAdapter(
              deviceId: '03', mockRfidSequence: ['F25838F6']), // 上海菜飯
          MockRFIDAdapter(
              deviceId: '04', mockRfidSequence: ['92F231F6']), // 五目飯
          MockRFIDAdapter(
              deviceId: '05', mockRfidSequence: ['727338F6']), // 火龍果
          MockRFIDAdapter(
              deviceId: '06', mockRfidSequence: ['32E136F6']), // 牛蒡蓮子養生湯
          MockRFIDAdapter(
              deviceId: '07', mockRfidSequence: ['E2AE2FF6']), // 冬至南瓜
        ];
        break;

      case 'partial':
        // Mix of readers with and without cards
        _readers = [
          MockRFIDAdapter(deviceId: '01', mockRfidSequence: ['A22038F6']),
          MockRFIDAdapter(deviceId: '02', mockRfidSequence: []), // No card
          MockRFIDAdapter(deviceId: '03', mockRfidSequence: ['F25838F6']),
          MockRFIDAdapter(deviceId: '04', mockRfidSequence: []), // No card
          MockRFIDAdapter(deviceId: '05', mockRfidSequence: ['727338F6']),
        ];
        break;

      case 'errors':
        // Some readers in error state
        _readers = [
          MockRFIDAdapter(deviceId: '01', mockRfidSequence: ['A22038F6']),
          MockRFIDAdapter(deviceId: '02', mockRfidSequence: ['A22438F6']),
        ];
        break;

      default:
        _readers = [];
    }
  }

  @override
  List<RFIDReader> get readers => _readers;

  @override
  Future<void> discoverReaders() async {
    // Mock discovery - readers already initialized
    await Future.delayed(const Duration(milliseconds: 200));
    debugPrint('Mock discovered ${_readers.length} readers');
    notifyListeners();
  }

  @override
  Future<List<RFIDReading>> scanAll() async {
    // Ensure we have all 7 readers for consistency with GPIO adapter
    while (_readers.length < 7) {
      final deviceId = (_readers.length + 1).toString().padLeft(2, '0');
      _readers.add(MockRFIDAdapter(deviceId: deviceId, mockRfidSequence: []));
    }

    final stopwatch = Stopwatch()..start();
    final readings = await Future.wait(
      _readers.map((reader) => reader.scan()),
    );
    _lastScanDuration = stopwatch.elapsed;

    // Update latest readings cache
    for (final reading in readings) {
      _latestReadings[reading.deviceId] = reading;
    }

    notifyListeners();
    return readings;
  }

  @override
  Duration? get lastScanDuration => _lastScanDuration;

  @override
  Map<String, String> get diagnostics => const {'模式': 'Mock (模擬讀卡機，無硬體時序設定)'};

  @override
  Future<void> reloadSettings() async {
    // Mock 沒有可重新載入的設定
  }

  @override
  RFIDReading? getReading(String deviceId) {
    return _latestReadings[deviceId];
  }

  @override
  List<RFIDReading> get validReadings {
    return _latestReadings.values.where((reading) => reading.hasCard).toList();
  }

  @override
  void dispose() {
    for (final reader in _readers) {
      reader.disconnect();
    }
    _readers.clear();
    _latestReadings.clear();
    super.dispose();
  }

  /// Add a custom mock reader
  void addReader(MockRFIDAdapter reader) {
    _readers.add(reader);
    notifyListeners();
  }

  /// Remove all readers with proper disposal
  Future<void> clearReaders() async {
    // Dispose all readers before clearing to prevent resource leaks
    for (final reader in _readers) {
      await reader.disconnect();
    }
    _readers.clear();
    _latestReadings.clear();
    notifyListeners();
  }
}
