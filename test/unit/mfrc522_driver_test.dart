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
///
/// FIFO 跟真晶片一樣只有一個：寫 FIFODataReg 會累積，FlushBuffer 清空，
/// 下 transceive 指令後 FIFO 的內容換成卡片的回應。
class FakeMfrc522Transport implements Mfrc522Transport {
  int version;

  /// 每次 transceive 依序取用的回應；用完後重複最後一個
  final List<FakeExchange> exchanges;

  /// true 時所有讀取都回 0x00，模擬 MISO 斷線
  bool corruptReads = false;

  /// 每第 N 次讀取回傳 0x00，模擬偶發的線路錯誤
  int? corruptEveryNthRead;

  /// 接下來幾次寫入「有送出但沒寫進晶片」，模擬 MOSI 的偶發位元錯誤
  int dropNextWrites = 0;

  /// 這些暫存器的寫入永遠寫不進去
  Set<int> deadRegisters = {};

  /// 每次 transceive 的第一次 ComIrqReg 讀取卡這麼久才回來，
  /// 模擬 isolate 在晶片 timer 已經響了之後才被排程回來
  int stallFirstIrqReadMs = 0;

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
        if (_irqIndex == 0 && stallFirstIrqReadMs > 0) {
          final stall = Stopwatch()..start();
          while (stall.elapsedMilliseconds < stallFirstIrqReadMs) {}
        }
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
    if (deadRegisters.contains(register)) return;
    if (dropNextWrites > 0) {
      dropNextWrites--;
      return;
    }
    switch (register) {
      case MFRC522Registers.fifoDataReg:
        _fifo.add(value);
      case MFRC522Registers.fifoLevelReg:
        if ((value & 0x80) != 0) _fifo.clear();
      case MFRC522Registers.commandReg:
        registers[register] = value;
        if (value == MFRC522Commands.transceive) {
          _exchangeIndex++;
          _irqIndex = 0;
          _fifo = List<int>.from(_exchange.fifo);
        }
      default:
        registers[register] = value;
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
  int highCount = 0;

  /// 每次拉高時呼叫 (第幾次拉高)，測試用來模擬「第二次上電才正常」
  void Function(int highCount)? onHigh;

  @override
  void open() => events.add('open');

  @override
  void high() {
    isHigh = true;
    highCount++;
    events.add('high');
    onHigh?.call(highCount);
  }

  @override
  void low() {
    isHigh = false;
    events.add('low');
  }

  @override
  void dispose() => events.add('dispose');
}

/// 測試用的快速時序：等待值都很短，效果跟真實設定一樣；不重新上電
const fastTiming = RfidTimingConfig(
  rstSettleMs: 1,
  linkCheckTimeoutMs: 2,
  antennaSettleMs: 0,
  reqaTimeoutMs: 1,
  reqaAttempts: 2,
  commDeadlineMs: 5,
  interReaderGapMs: 0,
  readerRetries: 0,
);

const cardUid = [0xA2, 0x20, 0x38, 0xF6];
const cardBcc = 0xA2 ^ 0x20 ^ 0x38 ^ 0xF6;

SimpleMFRC522 reader(
  FakeMfrc522Transport bus, {
  FakeResetLine? reset,
  RfidTimingConfig timing = fastTiming,
  int deviceNum = 1,
}) =>
    SimpleMFRC522(
      deviceNum: deviceNum,
      resetLine: reset ?? FakeResetLine(),
      transport: bus,
      timing: timing,
    );

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

    test('期限到了之後會再讀最後一次旗標：系統卡頓不會把空的讀卡機判成無回應', () {
      // 第一次讀 ComIrqReg 卡 30 ms (期限只有 5 ms) 才回 0x00，
      // 晶片其實早就舉起 TimerIRq；最後一次讀取要能看到它並回 notag
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange(irqReads: [0x00, 0x01]),
        ],
      )..stallFirstIrqReadMs = 30;
      final chip = MFRC522(bus, commDeadlineMs: 5);
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.notag);
    });

    test('ErrIRq 舉起就離開並回 error，不等到期限', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange(irqReads: [0x02], error: 0x08),
        ],
      );
      final chip = MFRC522(bus, commDeadlineMs: 200);
      final stopwatch = Stopwatch()..start();
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      stopwatch.stop();
      expect(reply.status, MFRC522Status.error);
      expect(stopwatch.elapsedMilliseconds, lessThan(150));
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

    test('FIFO 寫入一直寫不進去時回 spiError，不啟動指令', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00])
        ],
      )..deadRegisters = {MFRC522Registers.fifoDataReg};
      final chip = MFRC522(bus, writeVerifyRetries: 2);
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.spiError);
      expect(bus.transceiveCount, 0);
      expect(chip.verifyRetries, 2);
    });

    test('偶發一次寫入遺失會重寫後成功', () {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00])
        ],
      )..dropNextWrites = 1;
      final chip = MFRC522(bus);
      final reply = chip.communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.ok);
      expect(chip.verifyRetries, 1);
    });
  });

  group('MFRC522 register helpers', () {
    test('writeRegisterVerified 讀回不符會重寫，超過次數回 false', () {
      final bus = FakeMfrc522Transport()..dropNextWrites = 2;
      final chip = MFRC522(bus, writeVerifyRetries: 2);
      expect(chip.writeRegisterVerified(MFRC522Registers.modWidthReg, 0x26),
          isTrue);
      expect(chip.verifyRetries, 2);

      bus.deadRegisters = {MFRC522Registers.modWidthReg};
      expect(chip.writeRegisterVerified(MFRC522Registers.modWidthReg, 0x27),
          isFalse);
      expect(chip.verifyRetries, 4);
    });

    test('writeRegisterVerified 只比對有定義的位元', () {
      final bus = FakeMfrc522Transport();
      final chip = MFRC522(bus);
      // 模擬保留位元讀回為 0：ModeReg 寫 0x3D，讀回 0x29 也算通過
      bus.registers[MFRC522Registers.modeReg] = 0;
      bus.deadRegisters = {MFRC522Registers.modeReg};
      bus.registers[MFRC522Registers.modeReg] = 0x3D & 0xAB;
      expect(
          chip.writeRegisterVerified(MFRC522Registers.modeReg, 0x3D), isTrue);
      expect(chip.verifyRetries, 0);
    });

    test('setTimerTimeout 換算成 25 µs 的 tick 數', () {
      final bus = FakeMfrc522Transport();
      expect(MFRC522(bus).setTimerTimeout(25), isTrue);
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
      expect(MFRC522(bus).configure(reqaTimeoutMs: 25), isTrue);
      expect(bus.wrote(MFRC522Registers.txASKReg, 0x40), isTrue);
      expect(bus.wrote(MFRC522Registers.modeReg, 0x3D), isTrue);
      expect(bus.registers[MFRC522Registers.txControlReg]! & 0x03, 0x03);
    });

    test('configure 有暫存器寫不進去時回 false', () {
      final bus = FakeMfrc522Transport()
        ..deadRegisters = {MFRC522Registers.txASKReg};
      final chip = MFRC522(bus, writeVerifyRetries: 1);
      expect(chip.configure(reqaTimeoutMs: 25), isFalse);
      expect(chip.verifyRetries, 1);
      // 其他暫存器照常設定
      expect(bus.registers[MFRC522Registers.modeReg], 0x3D);
    });

    test('antennaOn 一律寫 0x83 並驗證，讀回值被干擾也不會跳過', () {
      final bus = FakeMfrc522Transport();
      // 讀回被干擾成 0xFF：舊版會以為天線已經開了而直接 return
      bus.registers[MFRC522Registers.txControlReg] = 0xFF;
      final chip = MFRC522(bus);
      expect(chip.antennaOn(), isTrue);
      expect(bus.wrote(MFRC522Registers.txControlReg, 0x83), isTrue);
      expect(bus.registers[MFRC522Registers.txControlReg], 0x83);
      expect(chip.verifyRetries, 0);

      // 寫不進去時回 false，而不是回報乾淨的「沒有卡片」
      final dead = FakeMfrc522Transport()
        ..deadRegisters = {MFRC522Registers.txControlReg};
      expect(MFRC522(dead, writeVerifyRetries: 1).antennaOn(), isFalse);
    });

    test('writeVerifyRetries = 0 是只寫不驗證，相容晶片讀回不同也不算錯', () {
      final bus = FakeMfrc522Transport()
        ..deadRegisters = {
          MFRC522Registers.txControlReg,
          MFRC522Registers.modeReg,
        };
      final chip = MFRC522(bus, writeVerifyRetries: 0);
      expect(chip.configure(reqaTimeoutMs: 25), isTrue);
      expect(chip.verifyRetries, 0);
      // 有寫、沒讀回
      expect(bus.wrote(MFRC522Registers.txControlReg, 0x83), isTrue);
      expect(bus.reads, 0);
      // 送指令也一樣：FIFO 檢查也關掉
      final reply = MFRC522(
        FakeMfrc522Transport(
          exchanges: const [
            FakeExchange.ok([0x04, 0x00])
          ],
        )..deadRegisters = {MFRC522Registers.bitFramingReg},
        writeVerifyRetries: 0,
      ).communicate(MFRC522Commands.transceive, [0x26]);
      expect(reply.status, MFRC522Status.ok);
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
      final result = await reader(bus, reset: reset, deviceNum: 3).scanOnce();

      expect(result.deviceId, '03');
      expect(result.status, ReaderScanStatus.card);
      expect(result.hasCard, isTrue);
      expect(result.linkOk, isTrue);
      expect(result.tagId, 'A22038F6');
      expect(result.version, MFRC522Version.v2);
      expect(result.attempts, 1);
      expect(result.spiRetries, 0);
      expect(result.rereads, 0);
      expect(result.timeToReadyMs, isNotNull);
      expect(reset.events, ['high', 'low']);
      expect(reset.isHigh, isFalse);
      // 離開前天線關閉
      expect(bus.registers[MFRC522Registers.txControlReg]! & 0x03, 0);
      expect(result.summary, contains('A22038F6'));
      // 第一次用 REQA
      expect(
          bus.wrote(MFRC522Registers.fifoDataReg, PICCCommands.reqidl), isTrue);
    });

    test('沒有卡片：REQA 會重試到設定的次數，一律用 REQA，不做 RF 場重置', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [FakeExchange.noTag()],
      );
      final result = await reader(bus).scanOnce();

      expect(result.status, ReaderScanStatus.noCard);
      expect(result.hasCard, isFalse);
      expect(result.linkOk, isTrue);
      expect(result.attempts, fastTiming.reqaAttempts);
      expect(bus.transceiveCount, fastTiming.reqaAttempts);
      expect(result.error, isNull);
      // 沒送過 HLTA，卡片不會在 HALT，WUPA 沒有意義
      expect(bus.wrote(MFRC522Registers.fifoDataReg, PICCCommands.reqall),
          isFalse);
      // 沒回應的卡片本來就在 IDLE：天線只在 configure 開一次
      expect(_antennaOnCount(bus), 1);
    });

    test('ATQA 壞掉 (卡片已進 READY)：先關掉再打開 RF 場，第二次 REQA 才叫得到', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04]), // ATQA 只有 8 bit → error
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final result = await reader(bus).scanOnce();

      expect(result.status, ReaderScanStatus.card);
      expect(result.tagId, 'A22038F6');
      expect(result.attempts, 2);
      // configure 開一次、場重置再開一次；中間有關過
      expect(_antennaOnCount(bus), 2);
      final writes = bus.writes;
      final firstOn = writes.indexOf((MFRC522Registers.txControlReg, 0x83));
      final off =
          writes.indexOf((MFRC522Registers.txControlReg, 0x80), firstOn);
      final secondOn =
          writes.indexOf((MFRC522Registers.txControlReg, 0x83), off);
      expect(off, greaterThan(firstOn));
      expect(secondOn, greaterThan(off));
      expect(bus.wrote(MFRC522Registers.fifoDataReg, PICCCommands.reqall),
          isFalse);
    });

    test('場重置後天線開不回來：回 spiError', () async {
      final bus = _DieAfterFirstAntennaOn(
        exchanges: const [
          FakeExchange.ok([0x04]),
          FakeExchange.ok([0x04, 0x00]),
        ],
      );
      final result = await reader(bus).scanOnce();
      expect(result.status, ReaderScanStatus.spiError);
      expect(result.attempts, 1);
    });

    test('第二次 REQA 才成功', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.noTag(),
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final result = await reader(bus).scanOnce();
      expect(result.status, ReaderScanStatus.card);
      expect(result.attempts, 2);
    });

    test('anticoll 校驗失敗會直接重送 anticoll，不重做 REQA', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, 0x00]), // BCC 錯
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final result = await reader(bus).scanOnce();
      expect(result.status, ReaderScanStatus.card);
      expect(result.tagId, 'A22038F6');
      expect(result.attempts, 1);
      expect(bus.transceiveCount, 3);
    });

    test('anticollRetries = 0 時先重置 RF 場，再退回外圈重做 REQA', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, 0x00]), // BCC 錯
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final result = await reader(
        bus,
        timing: fastTiming.copyWith(anticollRetries: 0),
      ).scanOnce();
      expect(result.status, ReaderScanStatus.card);
      expect(result.attempts, 2);
      expect(bus.transceiveCount, 4);
      expect(_antennaOnCount(bus), 2);
    });

    test('最後一次 REQA 失敗後不再重置 RF 場', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04])
        ], // 每次 ATQA 都壞
      );
      final result = await reader(bus).scanOnce();
      expect(result.status, ReaderScanStatus.noCard);
      expect(result.attempts, fastTiming.reqaAttempts);
      expect(result.error, contains('error'));
      // 兩次 REQA 之間重置一次，最後一次失敗後不再重置
      expect(_antennaOnCount(bus), fastTiming.reqaAttempts);
    });

    test('VersionReg 讀不到：直接回線路異常，不送 REQA，RST 仍會拉低', () async {
      final bus = FakeMfrc522Transport(version: 0x00);
      final reset = FakeResetLine();
      final result = await reader(bus, reset: reset, deviceNum: 7).scanOnce();

      expect(result.status, ReaderScanStatus.linkError);
      expect(result.linkOk, isFalse);
      expect(result.hasCard, isFalse);
      expect(result.version, 0x00);
      expect(result.error, contains('VersionReg'));
      expect(result.rereads, 0);
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

    test('readerRetries：第一次上電讀不到，重新上電後讀到卡片', () async {
      final bus = FakeMfrc522Transport(
        version: 0x00,
        exchanges: const [
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      );
      final reset = FakeResetLine()
        ..onHigh = (count) {
          if (count == 2) bus.version = MFRC522Version.v2;
        };
      final result = await reader(
        bus,
        reset: reset,
        timing: fastTiming.copyWith(readerRetries: 1),
      ).scanOnce();

      expect(result.status, ReaderScanStatus.card);
      expect(result.rereads, 1);
      expect(reset.highCount, 2);
      expect(reset.events, ['high', 'low', 'high', 'low']);
    });

    test('readerRetries 用完仍失敗就回報最後一次的狀態', () async {
      final bus = FakeMfrc522Transport(version: 0xFF);
      final reset = FakeResetLine();
      final result = await reader(
        bus,
        reset: reset,
        timing: fastTiming.copyWith(readerRetries: 2),
      ).scanOnce();
      expect(result.status, ReaderScanStatus.linkError);
      expect(result.rereads, 2);
      expect(reset.highCount, 3);
    });

    test('晶片有回應但送指令後沒有任何 IRQ：回 commTimeout 且不重試', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [FakeExchange.dead()],
      );
      final stopwatch = Stopwatch()..start();
      final result = await reader(bus, deviceNum: 2).scanOnce();
      stopwatch.stop();

      expect(result.status, ReaderScanStatus.commTimeout);
      expect(result.linkOk, isFalse);
      expect(result.attempts, 1);
      expect(result.error, contains('comm_timeout'));
      // 期限 = max(commDeadlineMs, reqaTimeoutMs + 25) = 26 ms，整體遠小於舊版的數百 ms
      expect(stopwatch.elapsedMilliseconds, lessThan(150));
    });

    test('暫存器一直寫不進去：回 spiError，重新上電也一樣，重寫次數有記錄', () async {
      final bus = FakeMfrc522Transport()
        ..deadRegisters = {MFRC522Registers.txControlReg};
      final reset = FakeResetLine();
      final result = await reader(
        bus,
        reset: reset,
        timing: fastTiming.copyWith(readerRetries: 1),
      ).scanOnce();

      expect(result.status, ReaderScanStatus.spiError);
      expect(result.linkOk, isFalse);
      expect(result.rereads, 1);
      expect(result.spiRetries, greaterThan(0));
      expect(result.error, contains('讀回不符'));
      expect(result.summary, contains('重寫×'));
      expect(bus.transceiveCount, 0);
      expect(reset.events.last, 'low');
    });

    test('偶發的寫入遺失只增加重寫次數，仍讀到卡片', () async {
      final bus = FakeMfrc522Transport(
        exchanges: const [
          FakeExchange.ok([0x04, 0x00]),
          FakeExchange.ok([...cardUid, cardBcc]),
        ],
      )..dropNextWrites = 2;
      // 讓「寫 0 被遺失」也看得出來：先把第一個會寫 0 的暫存器填成 0xFF。
      // 連續遺失 2 次仍在 writeVerifyRetries (2) 的範圍內，第三次寫入成功。
      bus.registers[MFRC522Registers.txModeReg] = 0xFF;
      final result = await reader(bus).scanOnce();
      expect(result.status, ReaderScanStatus.card);
      expect(result.spiRetries, 2);
      expect(result.rereads, 0);
    });

    test('transport 拋例外時回 error 且 RST 拉低，不重新上電', () async {
      final reset = FakeResetLine();
      final result = await SimpleMFRC522(
        deviceNum: 4,
        resetLine: reset,
        transport: _ThrowingTransport(),
        timing: fastTiming.copyWith(readerRetries: 2),
      ).scanOnce();

      expect(result.status, ReaderScanStatus.error);
      expect(result.error, contains('boom'));
      expect(result.rereads, 0);
      expect(reset.events.last, 'low');
      expect(reset.highCount, 1);
    });

    test('dispose 會拉低並釋放 RST', () async {
      final reset = FakeResetLine();
      final r = reader(FakeMfrc522Transport(), reset: reset);
      r.open();
      await r.dispose();
      expect(reset.events, ['open', 'low', 'dispose']);
    });
  });

  group('SimpleMFRC522.probeLink', () {
    test('線路正常：量到就緒時間且零錯誤', () async {
      final bus = FakeMfrc522Transport(version: MFRC522Version.v1);
      final reset = FakeResetLine();
      final probe =
          await reader(bus, reset: reset, deviceNum: 5).probeLink(samples: 20);

      expect(probe.ready, isTrue);
      expect(probe.clean, isTrue);
      expect(probe.version, MFRC522Version.v1);
      expect(probe.samples, 40);
      expect(probe.mismatches, 0);
      expect(reset.events, ['high', 'low']);
    });

    test('偶發錯誤會被統計出來', () async {
      final bus = FakeMfrc522Transport()..corruptEveryNthRead = 7;
      final probe = await reader(bus, deviceNum: 5).probeLink(samples: 50);
      expect(probe.ready, isTrue);
      expect(probe.mismatches, greaterThan(0));
      expect(probe.clean, isFalse);
      expect(probe.errorRate, greaterThan(0));
    });

    test('一直讀不到 VersionReg：未就緒，樣本數為 0', () async {
      final bus = FakeMfrc522Transport(version: 0xFF);
      final probe =
          await reader(bus, deviceNum: 6).probeLink(samples: 10, maxReadyMs: 5);
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
        spiRetries: 2,
        rereads: 1,
      );
      final restored = ReaderScanResult.fromJson(original.toJson());
      expect(restored.deviceId, '02');
      expect(restored.status, ReaderScanStatus.card);
      expect(restored.tagId, 'F25838F6');
      expect(restored.version, 0x92);
      expect(restored.timeToReadyMs, 3);
      expect(restored.elapsedMs, 41);
      expect(restored.attempts, 1);
      expect(restored.spiRetries, 2);
      expect(restored.rereads, 1);
      expect(restored.hasCard, isTrue);
      expect(restored.summary, contains('重讀×1'));
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

/// TxControlReg 寫成 0x83 (開天線) 的次數
int _antennaOnCount(FakeMfrc522Transport bus) => bus.writes
    .where((w) => w.$1 == MFRC522Registers.txControlReg && w.$2 == 0x83)
    .length;

/// 第一次開天線正常，之後 TxControlReg 就寫不進去 (模擬場重置時線路出錯)
class _DieAfterFirstAntennaOn extends FakeMfrc522Transport {
  int _antennaOns = 0;

  _DieAfterFirstAntennaOn({required super.exchanges});

  @override
  void writeRegister(int register, int value) {
    if (register == MFRC522Registers.txControlReg && value == 0x83) {
      _antennaOns++;
      if (_antennaOns > 1) {
        writes.add((register, value));
        return;
      }
    }
    super.writeRegister(register, value);
  }
}

class _ThrowingTransport implements Mfrc522Transport {
  @override
  int readRegister(int register) => throw StateError('boom');

  @override
  void writeRegister(int register, int value) {}
}
