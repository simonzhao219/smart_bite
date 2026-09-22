import 'package:flutter_test/flutter_test.dart';
import 'package:smart_bite/services/mfrc522.dart';
import 'package:smart_bite/services/mfrc522_constants.dart';
import 'package:smart_bite/services/rfid_timing_config.dart';
import 'package:smart_bite/services/simple_mfrc522.dart';

/// 一次 transceive 的模擬回應
class FakeExchange {
  /// ComIrqReg 依序回傳的值；用完後重複最後一個
  final List<int> irqReads;

  /// 卡片回應放進 FIFO 的 bytes
  final List<int> fifo;

  /// ErrorReg 的值
  final int error;

  const FakeExchange({
    required this.irqReads,
    this.fifo = const [],
    this.error = 0,
  });

  /// 卡片正常回應
  const FakeExchange.ok(List<int> fifo)
      : this(irqReads: const [0x30], fifo: fifo);

  /// 晶片 timer 逾時 (沒有卡)
  const FakeExchange.noTag() : this(irqReads: const [0x01]);

  /// 晶片完全沒反應 (IRQ 永遠是 0)
  const FakeExchange.dead() : this(irqReads: const [0x00]);
}

/// 模擬 MFRC522 暫存器行為的假 transport
class FakeMfrc522Transport implements Mfrc522Transport {
  int version;

  /// 每次 transceive 依序取用的回應；用完後重複最後一個
  final List<FakeExchange> exchanges;

  /// true 時所有讀取都回 0x00，模擬 MISO 斷線
  bool corruptReads = false;

  /// 每第 N 次讀取回傳 0x00，模擬偶發的線路錯誤
  int? corruptEveryNthRead;

  final Map<int, int> registers = {};
  final List<(int, int)> writes = [];
  int reads = 0;

  int _exchangeIndex = -1;
  int _irqIndex = 0;
  List<int> _fifo = [];

  FakeMfrc522Transport({
    this.version = MFRC522Version.v2,
    this.exchanges = const [FakeExchange.noTag()],
  });

  FakeExchange get _exchange => exchanges[
      _exchangeIndex < 0 ? 0 : _exchangeIndex.clamp(0, exchanges.length - 1)];

  @override
  int readRegister(int register) {
    reads++;
    if (corruptReads) return 0x00;
    final nth = corruptEveryNthRead;
    if (nth != null && reads % nth == 0) return 0x00;

    switch (register) {
      case MFRC522Registers.versionReg:
        return version;
      case MFRC522Registers.comIrqReg:
        final irqReads = _exchange.irqReads;
        final value = irqReads[_irqIndex.clamp(0, irqReads.length - 1)];
        _irqIndex++;
        return value;
      case MFRC522Registers.errorReg:
        return _exchange.error;
      case MFRC522Registers.fifoLevelReg:
        return _fifo.length;
      case MFRC522Registers.fifoDataReg:
        return _fifo.isEmpty ? 0 : _fifo.removeAt(0);
      case MFRC522Registers.controlReg:
        return 0;
      default:
        return registers[register] ?? 0;
    }
  }

  @override
  void writeRegister(int register, int value) {
    writes.add((register, value));
    registers[register] = value;
    if (register == MFRC522Registers.commandReg &&
        value == MFRC522Commands.transceive) {
      _exchangeIndex++;
      _irqIndex = 0;
      _fifo = List<int>.from(_exchange.fifo);
    }
  }

  bool wrote(int register, int value) =>
      writes.any((w) => w.$1 == register && w.$2 == value);

  int get transceiveCount => writes
      .where((w) =>
          w.$1 == MFRC522Registers.commandReg &&
          w.$2 == MFRC522Commands.transceive)
      .length;
}

class FakeResetLine implements ResetLine {
  final List<String> events = [];
  bool isHigh = false;

  @override
  void open() => events.add('open');

  @override
  void high() {
    isHigh = true;
    events.add('high');
  }

  @override
  void low() {
    isHigh = false;
    events.add('low');
  }

  @override
  void dispose() => events.add('dispose');
}

/// 測試用的快速時序：等待值都很短，效果跟真實設定一樣
const fastTiming = RfidTimingConfig(
  rstSettleMs: 1,
  linkCheckTimeoutMs: 2,
  antennaSettleMs: 0,
  reqaTimeoutMs: 1,
  reqaAttempts: 2,
  commDeadlineMs: 5,
  interReaderGapMs: 0,
);

const cardUid = [0xA2, 0x20, 0x38, 0xF6];
const cardBcc = 0xA2 ^ 0x20 ^ 0x38 ^ 0xF6;

void main() {
  group('MFRC522.communicate', () {
    test('IRQ 永遠不來時在牆鐘期限內回 timeout，而不是讀滿固定次數', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [FakeExchange.dead()],
      );
      final chip = MFRC522(bus, commDeadlineMs: 20);

      final stopwatch = Stopwatch()..start();
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      stopwatch.stop();

      expect(reply.status, MFRC522Status.timeout);
      expect(reply.backData, isEmpty);
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(20));
      expect(stopwatch.elapsedMilliseconds, lessThan(200));
    });

    test('晶片 timer 逾時回 notag', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [FakeExchange.noTag()],
      );
      final chip = MFRC522(bus);
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.notag);
    });

    test('稍後才完成的回應也能收到', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange(irqReads: [0x00, 0x00, 0x00, 0x30], fifo: [0x04, 0x00]),
        ],
      );
      final chip = MFRC522(bus);
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.ok);
      expect(reply.backData, [0x04, 0x00]);
      expect(reply.backLen, 16);
    });

    test('ErrorReg 有錯誤位元時回 error', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange(irqReads: [0x30], fifo: [0x04, 0x00], error: 0x08),
        ],
      );
      final chip = MFRC522(bus);
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.error);
    });

    test('送出前會清 IRQ、清 FIFO、寫入資料並啟動傳送', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00])
        ],
      );
      MFRC522(bus).communicate(MFRC522Commands.transceive, [0x26]);
      expect(bus.wrote(MFRC522Registers.comIrqReg, 0x7F), isTrue);
      expect(bus.wrote(MFRC522Registers.fifoLevelReg, 0x80), isTrue);
      expect(bus.wrote(MFRC522Registers.fifoDataReg, 0x26), isTrue);
      expect(bus.wrote(MFRC522Registers.commandReg, MFRC522Commands.transceive),
          isTrue);
      // StartSend 設定後又清掉
      expect(bus.wrote(MFRC522Registers.bitFramingReg, 0x80), isTrue);
      expect(bus.writes.last.$1, MFRC522Registers.bitFramingReg);
      expect(bus.writes.last.$2 & 0x80, 0);
    });
  });

  group('MFRC522 register helpers', () {
    test('setTimerTimeout 換算成 25 µs 的 tick 數', () {
      final bus = FakeMfrc522Transport();
      MFRC522(bus).setTimerTimeout(25);
      // 25 ms × 40 = 1000 = 0x03E8
      expect(bus.wrote(MFRC522Registers.tModeReg, 0x80), isTrue);
      expect(bus.wrote(MFRC522Registers.tPrescalerReg, 0xA9), isTrue);
      expect(bus.wrote(MFRC522Registers.tReloadRegH, 0x03), isTrue);
      expect(bus.wrote(MFRC522Registers.tReloadRegL, 0xE8), isTrue);
    });

    test('setTimerTimeout 超過 16 bit 會夾在 0xFFFF', () {
      final bus = FakeMfrc522Transport();
      MFRC522(bus).setTimerTimeout(5000);
      expect(bus.wrote(MFRC522Registers.tReloadRegH, 0xFF), isTrue);
      expect(bus.wrote(MFRC522Registers.tReloadRegL, 0xFF), isTrue);
    });

    test('configure 會設定 ASK、CRC 預設值並開天線', () {
      final bus = FakeMfrc522Transport();
      MFRC522(bus).configure(reqaTimeoutMs: 25);
      expect(bus.wrote(MFRC522Registers.txASKReg, 0x40), isTrue);
      expect(bus.wrote(MFRC522Registers.modeReg, 0x3D), isTrue);
      expect(bus.registers[MFRC522Registers.txControlReg]! & 0x03, 0x03);
    });

    test('antennaOff 清掉 TX1/TX2', () {
      final bus = FakeMfrc522Transport();
      bus.registers[MFRC522Registers.txControlReg] = 0x83;
      MFRC522(bus).antennaOff();
      expect(bus.registers[MFRC522Registers.txControlReg], 0x80);
    });

    test('isLinkAlive 與 writeReadBack', () {
      final bus = FakeMfrc522Transport(version: MFRC522Version.v1);
      final chip = MFRC522(bus);
      expect(chip.isLinkAlive, isTrue);
      expect(chip.writeReadBack(0x5A), isTrue);

      bus.corruptReads = true;
      expect(chip.isLinkAlive, isFalse);
      expect(chip.writeReadBack(0x5A), isFalse);
    });

    test('request 需要 16 bit 的 ATQA', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04])
        ],
      );
      final result = MFRC522(bus).request(PICCCommands.reqidl);
      expect(result.status, MFRC522Status.error);
    });

    test('anticoll 驗證 BCC', () {
      final good = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([...cardUid, cardBcc])
        ],
      );
      expect(MFRC522(good).anticoll().uid, [...cardUid, cardBcc]);

      final bad = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([...cardUid, 0x00])
        ],
      );
      expect(MFRC522(bad).anticoll().status, MFRC522Status.error);
    });
  });

  group('SimpleMFRC522.scanOnce', () {
    test('讀到卡片：回 UID、RST 有拉高再拉低、天線關閉', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final reset = FakeResetLine();
      final reader = SimpleMFRC522(
        deviceNum: 3,
        resetLine: reset,
        transport: bus,
        timing: fastTiming,
      );

      final result = await reader.scanOnce();

      expect(result.deviceId, '03');
      expect(result.status, ReaderScanStatus.card);
      expect(result.hasCard, isTrue);
      expect(result.linkOk, isTrue);
      expect(result.tagId, 'A22038F6');
      expect(result.version, MFRC522Version.v2);
      expect(result.attempts, 1);
      expect(result.timeToReadyMs, isNotNull);
      expect(reset.events, ['high', 'low']);
      expect(reset.isHigh, isFalse);
      // 離開前天線關閉
      expect(bus.registers[MFRC522Registers.txControlReg]! & 0x03, 0);
      expect(result.summary, contains('A22038F6'));
    });

    test('沒有卡片：REQA 會重試到設定的次數', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [FakeExchange.noTag()],
      );
      final reader = SimpleMFRC522(
        deviceNum: 1,
        resetLine: FakeResetLine(),
        transport: bus,
        timing: fastTiming,
      );

      final result = await reader.scanOnce();

      expect(result.status, ReaderScanStatus.noCard);
      expect(result.hasCard, isFalse);
      expect(result.linkOk, isTrue);
      expect(result.attempts, fastTiming.reqaAttempts);
      expect(bus.transceiveCount, fastTiming.reqaAttempts);
      expect(result.error, isNull);
    });

    test('第二次 REQA 才成功', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.noTag(),
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final reader = SimpleMFRC522(
        deviceNum: 1,
        resetLine: FakeResetLine(),
        transport: bus,
        timing: fastTiming,
      );

      final result = await reader.scanOnce();
      expect(result.status, ReaderScanStatus.card);
      expect(result.attempts, 2);
    });

    test('VersionReg 讀不到：直接回線路異常，不送 REQA，RST 仍會拉低', () async {
      final bus = FakeMfrc522Transport(version: 0x00);
      final reset = FakeResetLine();
      final reader = SimpleMFRC522(
        deviceNum: 7,
        resetLine: reset,
        transport: bus,
        timing: fastTiming,
      );

      final result = await reader.scanOnce();

      expect(result.status, ReaderScanStatus.linkError);
      expect(result.linkOk, isFalse);
      expect(result.hasCard, isFalse);
      expect(result.version, 0x00);
      expect(result.error, contains('VersionReg'));
      expect(bus.transceiveCount, 0);
      expect(reset.events.last, 'low');
      // 有等到 rstSettleMs + linkCheckTimeoutMs 才放棄
      expect(
        result.elapsedMs,
        greaterThanOrEqualTo(
          fastTiming.rstSettleMs + fastTiming.linkCheckTimeoutMs,
        ),
      );
    });

    test('晶片有回應但送指令後沒有任何 IRQ：回 commTimeout 且不重試', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [FakeExchange.dead()],
      );
      final reader = SimpleMFRC522(
        deviceNum: 2,
        resetLine: FakeResetLine(),
        transport: bus,
        timing: fastTiming,
      );

      final stopwatch = Stopwatch()..start();
      final result = await reader.scanOnce();
      stopwatch.stop();

      expect(result.status, ReaderScanStatus.commTimeout);
      expect(result.linkOk, isFalse);
      expect(result.attempts, 1);
      expect(result.error, contains('comm_timeout'));
      // 期限 = max(commDeadlineMs, reqaTimeoutMs + 10) = 11 ms，整體遠小於舊版的數百 ms
      expect(stopwatch.elapsedMilliseconds, lessThan(150));
    });

    test('transport 拋例外時回 error 且 RST 拉低', () async {
      final reset = FakeResetLine();
      final reader = SimpleMFRC522(
        deviceNum: 4,
        resetLine: reset,
        transport: _ThrowingTransport(),
        timing: fastTiming,
      );

      final result = await reader.scanOnce();
      expect(result.status, ReaderScanStatus.error);
      expect(result.error, contains('boom'));
      expect(reset.events.last, 'low');
    });

    test('dispose 會拉低並釋放 RST', () async {
      final reset = FakeResetLine();
      final reader = SimpleMFRC522(
        deviceNum: 1,
        resetLine: reset,
        transport: FakeMfrc522Transport(),
      );
      reader.open();
      await reader.dispose();
      expect(reset.events, ['open', 'low', 'dispose']);
    });
  });

  group('SimpleMFRC522.probeLink', () {
    test('線路正常：量到就緒時間且零錯誤', () async {
      final bus = FakeMfrc522Transport(version: MFRC522Version.v1);
      final reset = FakeResetLine();
      final reader = SimpleMFRC522(
        deviceNum: 5,
        resetLine: reset,
        transport: bus,
        timing: fastTiming,
      );

      final probe = await reader.probeLink(samples: 20);

      expect(probe.ready, isTrue);
      expect(probe.clean, isTrue);
      expect(probe.version, MFRC522Version.v1);
      expect(probe.samples, 40);
      expect(probe.mismatches, 0);
      expect(reset.events, ['high', 'low']);
    });

    test('偶發錯誤會被統計出來', () async {
      final bus = FakeMfrc522Transport()..corruptEveryNthRead = 7;
      final reader = SimpleMFRC522(
        deviceNum: 5,
        resetLine: FakeResetLine(),
        transport: bus,
        timing: fastTiming,
      );

      final probe = await reader.probeLink(samples: 50);
      expect(probe.ready, isTrue);
      expect(probe.mismatches, greaterThan(0));
      expect(probe.clean, isFalse);
      expect(probe.errorRate, greaterThan(0));
    });

    test('一直讀不到 VersionReg：未就緒，樣本數為 0', () async {
      final bus = FakeMfrc522Transport(version: 0xFF);
      final reader = SimpleMFRC522(
        deviceNum: 6,
        resetLine: FakeResetLine(),
        transport: bus,
        timing: fastTiming,
      );

      final probe = await reader.probeLink(samples: 10, maxReadyMs: 5);
      expect(probe.ready, isFalse);
      expect(probe.clean, isFalse);
      expect(probe.samples, 0);
      expect(probe.timeToReadyMs, isNull);
    });
  });

  group('ReaderScanResult', () {
    test('JSON 往返', () {
      const original = ReaderScanResult(
        deviceId: '02',
        status: ReaderScanStatus.card,
        tagId: 'F25838F6',
        version: 0x92,
        timeToReadyMs: 3,
        elapsedMs: 41,
        attempts: 1,
      );
      final restored = ReaderScanResult.fromJson(original.toJson());
      expect(restored.deviceId, '02');
      expect(restored.status, ReaderScanStatus.card);
      expect(restored.tagId, 'F25838F6');
      expect(restored.version, 0x92);
      expect(restored.timeToReadyMs, 3);
      expect(restored.elapsedMs, 41);
      expect(restored.attempts, 1);
      expect(restored.hasCard, isTrue);
    });

    test('未知的 status 名稱視為 error', () {
      final result = ReaderScanResult.fromJson({
        'deviceId': '01',
        'status': 'weird',
      });
      expect(result.status, ReaderScanStatus.error);
      expect(result.linkOk, isFalse);
    });
  });
}

class _ThrowingTransport implements Mfrc522Transport {
  @override
  int readRegister(int register) => throw StateError('boom');

  @override
  void writeRegister(int register, int value) {}
}
