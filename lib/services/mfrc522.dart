/// MFRC522 低階驅動 (純 Dart，不依賴 Flutter，CLI 校正工具也共用)
///
/// 暫存器讀寫透過 [Mfrc522Transport] 抽象：正式環境用 SPI，
/// 單元測試用假物件模擬晶片行為。
///
/// 跟舊版最大的差別：等待 IRQ 的迴圈改用「牆鐘時間」當上限，
/// 而不是固定讀 2000 次暫存器。線路不好時舊版會把 2000 次讀完
/// (每次都是一個 SPI ioctl，一次約 0.1 到 0.2 秒)，掃描時間因此隨線長浮動。
library;

import 'dart:typed_data';

import 'package:dart_periphery/dart_periphery.dart';

import 'mfrc522_constants.dart';

/// 暫存器讀寫介面
abstract class Mfrc522Transport {
  int readRegister(int register);
  void writeRegister(int register, int value);
}

/// 透過 dart_periphery 的 SPI 讀寫暫存器。多顆 RC522 共用同一個 [SPI] 物件。
class SpiMfrc522Transport implements Mfrc522Transport {
  final SPI spi;

  SpiMfrc522Transport(this.spi);

  @override
  int readRegister(int register) {
    // 位址格式：bit7 = 1 讀取，bit6..1 = 位址，bit0 = 0
    final frame = Uint8List.fromList([((register << 1) & 0x7E) | 0x80, 0x00]);
    final response = spi.transfer(frame, true);
    return response[1] & 0xFF;
  }

  @override
  void writeRegister(int register, int value) {
    final frame = Uint8List.fromList([(register << 1) & 0x7E, value & 0xFF]);
    spi.transfer(frame, true);
  }
}

/// communicate() 的回傳值
typedef Mfrc522Reply = ({int status, List<int> backData, int backLen});

/// MFRC522 暫存器層級的操作
class MFRC522 {
  final Mfrc522Transport bus;

  /// 軟體端等待 IRQ 的牆鐘上限 (ms)，要比晶片 timer 逾時再長一些
  final int commDeadlineMs;

  MFRC522(this.bus, {this.commDeadlineMs = 36});

  int readRegister(int register) => bus.readRegister(register);

  void writeRegister(int register, int value) =>
      bus.writeRegister(register, value);

  void setBitMask(int register, int mask) {
    final current = readRegister(register);
    writeRegister(register, current | mask);
  }

  void clearBitMask(int register, int mask) {
    final current = readRegister(register);
    writeRegister(register, current & (~mask) & 0xFF);
  }

  /// 讀 VersionReg。正常為 0x91 或 0x92；0x00 / 0xFF 代表 MISO 沒接到晶片。
  int readVersion() => readRegister(MFRC522Registers.versionReg);

  /// 連續讀兩次 VersionReg，都合理且一致才算連線正常
  bool get isLinkAlive {
    final version = readVersion();
    return MFRC522Version.isPlausible(version) && readVersion() == version;
  }

  /// 寫入一個值再讀回，用來測 MOSI 與 MISO 雙向是否可靠。
  /// 用 TReloadRegL：timer 沒在跑時改它沒有副作用，[configure] 會再設定一次。
  bool writeReadBack(int value) {
    writeRegister(MFRC522Registers.tReloadRegL, value & 0xFF);
    return readRegister(MFRC522Registers.tReloadRegL) == (value & 0xFF);
  }

  /// 軟體 reset。走 RST 腳做硬體 reset 時不需要再呼叫。
  void softReset() {
    writeRegister(MFRC522Registers.commandReg, MFRC522Commands.softReset);
  }

  /// 硬體 reset 之後的暫存器設定，順序與 Arduino MFRC522 library 的 PCD_Init 相同。
  void configure({int reqaTimeoutMs = 25}) {
    writeRegister(MFRC522Registers.txModeReg, 0x00);
    writeRegister(MFRC522Registers.rxModeReg, 0x00);
    writeRegister(MFRC522Registers.modWidthReg, 0x26);
    setTimerTimeout(reqaTimeoutMs);
    // 強制 100% ASK 調變
    writeRegister(MFRC522Registers.txASKReg, 0x40);
    // CRC 預設值 0x6363
    writeRegister(MFRC522Registers.modeReg, 0x3D);
    antennaOn();
  }

  /// 設定晶片內部 timer 的逾時，傳送結束後自動起算 (TAuto=1)。
  ///
  /// TPrescaler = 0x0A9 = 169 → f_timer = 13.56 MHz / (2×169+1) ≈ 40 kHz，
  /// 每個 tick 25 µs，所以 ticks = ms × 40。上限 0xFFFF ≈ 1638 ms。
  void setTimerTimeout(int milliseconds) {
    final ticks = (milliseconds * 40).clamp(1, 0xFFFF);
    writeRegister(MFRC522Registers.tModeReg, 0x80);
    writeRegister(MFRC522Registers.tPrescalerReg, 0xA9);
    writeRegister(MFRC522Registers.tReloadRegH, (ticks >> 8) & 0xFF);
    writeRegister(MFRC522Registers.tReloadRegL, ticks & 0xFF);
  }

  void antennaOn() {
    final current = readRegister(MFRC522Registers.txControlReg);
    if ((current & 0x03) != 0x03) {
      writeRegister(MFRC522Registers.txControlReg, current | 0x03);
    }
  }

  void antennaOff() {
    clearBitMask(MFRC522Registers.txControlReg, 0x03);
  }

  /// 送指令給晶片並等待完成。
  ///
  /// 回傳的 status：
  /// - [MFRC522Status.ok]：有收到卡片回應
  /// - [MFRC522Status.notag]：晶片 timer 逾時，代表晶片正常但場內沒有卡
  /// - [MFRC522Status.timeout]：牆鐘上限內晶片連 timer IRQ 都沒舉起，
  ///   通常是 SPI 線路或供電問題
  /// - [MFRC522Status.error]：ErrorReg 有 BufferOvfl / CollErr / ParityErr / ProtocolErr
  Mfrc522Reply communicate(
    int command,
    List<int> sendData, {
    int? deadlineMs,
  }) {
    var irqEn = 0x00;
    var waitIRq = 0x00;
    if (command == MFRC522Commands.mfAuthent) {
      irqEn = 0x12;
      waitIRq = 0x10;
    } else if (command == MFRC522Commands.transceive) {
      irqEn = 0x77;
      waitIRq = 0x30;
    }

    writeRegister(MFRC522Registers.comIEnReg, irqEn | 0x80);
    // Set1 = 0 且其餘位元為 1：清掉全部七個 IRQ 旗標
    writeRegister(MFRC522Registers.comIrqReg, 0x7F);
    // FlushBuffer
    writeRegister(MFRC522Registers.fifoLevelReg, 0x80);
    writeRegister(MFRC522Registers.commandReg, MFRC522Commands.idle);

    for (final byte in sendData) {
      writeRegister(MFRC522Registers.fifoDataReg, byte & 0xFF);
    }

    writeRegister(MFRC522Registers.commandReg, command);
    if (command == MFRC522Commands.transceive) {
      // StartSend
      setBitMask(MFRC522Registers.bitFramingReg, 0x80);
    }

    final deadline = deadlineMs ?? commDeadlineMs;
    final stopwatch = Stopwatch()..start();
    var completed = false;
    var timerFired = false;
    do {
      final irq = readRegister(MFRC522Registers.comIrqReg);
      if ((irq & waitIRq) != 0) {
        completed = true;
        break;
      }
      if ((irq & 0x01) != 0) {
        timerFired = true;
        break;
      }
    } while (stopwatch.elapsedMilliseconds < deadline);

    clearBitMask(MFRC522Registers.bitFramingReg, 0x80);

    if (!completed) {
      return (
        status: timerFired ? MFRC522Status.notag : MFRC522Status.timeout,
        backData: const <int>[],
        backLen: 0,
      );
    }

    // BufferOvfl / CollErr / ParityErr / ProtocolErr
    if ((readRegister(MFRC522Registers.errorReg) & 0x1B) != 0) {
      return (status: MFRC522Status.error, backData: const <int>[], backLen: 0);
    }

    if (command != MFRC522Commands.transceive) {
      return (status: MFRC522Status.ok, backData: const <int>[], backLen: 0);
    }

    var count = readRegister(MFRC522Registers.fifoLevelReg);
    final lastBits = readRegister(MFRC522Registers.controlReg) & 0x07;
    final backLen = lastBits != 0 ? (count - 1) * 8 + lastBits : count * 8;
    if (count == 0) count = 1;
    if (count > 16) count = 16;
    final backData = List<int>.generate(
      count,
      (_) => readRegister(MFRC522Registers.fifoDataReg),
    );

    return (status: MFRC522Status.ok, backData: backData, backLen: backLen);
  }

  /// REQA / WUPA：找場內的卡片，成功會收到 2 bytes ATQA (16 bits)
  ({int status, List<int> backBits}) request(int reqMode) {
    // 只送 7 個 bit
    writeRegister(MFRC522Registers.bitFramingReg, 0x07);
    final reply = communicate(MFRC522Commands.transceive, [reqMode]);

    if (reply.status != MFRC522Status.ok) {
      return (status: reply.status, backBits: const <int>[]);
    }
    if (reply.backLen != 0x10) {
      return (status: MFRC522Status.error, backBits: const <int>[]);
    }
    return (status: MFRC522Status.ok, backBits: reply.backData);
  }

  /// Anti-collision (cascade level 1)：取得 4 bytes UID 加 1 byte BCC
  ({int status, List<int> uid}) anticoll() {
    writeRegister(MFRC522Registers.bitFramingReg, 0x00);
    final reply = communicate(
      MFRC522Commands.transceive,
      [PICCCommands.anticoll, 0x20],
    );

    if (reply.status != MFRC522Status.ok) {
      return (status: reply.status, uid: const <int>[]);
    }
    if (reply.backData.length != 5) {
      return (status: MFRC522Status.error, uid: const <int>[]);
    }

    var checksum = 0;
    for (var i = 0; i < 4; i++) {
      checksum ^= reply.backData[i];
    }
    if (checksum != reply.backData[4]) {
      return (status: MFRC522Status.error, uid: const <int>[]);
    }
    return (status: MFRC522Status.ok, uid: reply.backData);
  }
}
