/// MFRC522 低階驅動 (純 Dart，不依賴 Flutter，CLI 校正工具也共用)
///
/// 暫存器讀寫透過 [Mfrc522Transport] 抽象：正式環境用 SPI，
/// 單元測試用假物件模擬晶片行為。
///
/// 跟舊版最大的差別：
/// - 等待 IRQ 的迴圈改用「牆鐘時間」當上限，而不是固定讀 2000 次暫存器。
///   線路不好時舊版會把 2000 次讀完 (每次都是一個 SPI ioctl，一次約 0.1 到 0.2 秒)，
///   掃描時間因此隨線長浮動。
/// - 關鍵暫存器寫入後會讀回驗證，不符就重寫 ([writeRegisterVerified])。
///   長線造成的偶發位元錯誤因此只會多花幾十微秒，而不是讓整顆讀卡機這一輪讀不到。
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

  /// 軟體端等待 IRQ 的牆鐘上限 (ms)，要比晶片 timer 逾時再長一些。
  /// 每次讀取前可以依當次生效的時序設定重新指定。
  int commDeadlineMs;

  /// 關鍵暫存器寫入後讀回不符時，最多重寫幾次。
  /// 0 代表只寫不驗證 (舊版行為)，相容晶片讀回行為不同時可以關掉。
  int writeVerifyRetries;

  /// 累計的重寫次數 (診斷用)，由呼叫端在每次讀卡前歸零
  int verifyRetries = 0;

  MFRC522(
    this.bus, {
    this.commDeadlineMs = 50,
    this.writeVerifyRetries = 2,
  });

  /// 硬體 reset 後 TxControlReg 的值 (0x80) 加上 Tx1RFEn / Tx2RFEn
  static const int txControlAntennaOn = 0x83;

  /// 各暫存器讀回驗證時要比對的位元：保留位元讀回值不保證跟寫入相同，必須排除
  static const Map<int, int> verifyMasks = {
    MFRC522Registers.commandReg: 0x3F, // bit 7..6 保留
    MFRC522Registers.comIEnReg: 0xFF,
    MFRC522Registers.bitFramingReg: 0x77, // bit 7 StartSend 自清、bit 3 保留
    MFRC522Registers.modeReg: 0xAB, // bit 6、4、2 保留
    MFRC522Registers.txModeReg: 0xF8, // bit 2..0 保留
    MFRC522Registers.rxModeReg: 0xFC, // bit 1..0 保留
    MFRC522Registers.txControlReg: 0x03, // 只驗證 Tx1RFEn / Tx2RFEn
    MFRC522Registers.txASKReg: 0x40, // 只有 Force100ASK 有定義
    MFRC522Registers.modWidthReg: 0xFF,
    MFRC522Registers.tModeReg: 0xFF,
    MFRC522Registers.tPrescalerReg: 0xFF,
    MFRC522Registers.tReloadRegH: 0xFF,
    MFRC522Registers.tReloadRegL: 0xFF,
  };

  bool get _verifyEnabled => writeVerifyRetries > 0;

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

  /// 寫入後讀回驗證，只比對 [mask] 的位元 (不給就用 [verifyMasks])。
  /// 不符就重寫，最多 [writeVerifyRetries] 次；最後仍不符回 false。
  /// [writeVerifyRetries] 為 0 時只寫不讀回，永遠回 true。
  bool writeRegisterVerified(int register, int value, {int? mask}) {
    if (!_verifyEnabled) {
      writeRegister(register, value);
      return true;
    }
    final bits = mask ?? verifyMasks[register] ?? 0xFF;
    for (var attempt = 0;; attempt++) {
      writeRegister(register, value);
      if ((readRegister(register) & bits) == (value & bits)) return true;
      if (attempt >= writeVerifyRetries) return false;
      verifyRetries++;
    }
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
  /// 每個寫入都讀回驗證；回 false 代表有暫存器重寫之後仍然不符 (線路很差)。
  bool configure({int reqaTimeoutMs = 25}) {
    var ok = writeRegisterVerified(MFRC522Registers.txModeReg, 0x00);
    ok = writeRegisterVerified(MFRC522Registers.rxModeReg, 0x00) && ok;
    ok = writeRegisterVerified(MFRC522Registers.modWidthReg, 0x26) && ok;
    ok = setTimerTimeout(reqaTimeoutMs) && ok;
    // 強制 100% ASK 調變
    ok = writeRegisterVerified(MFRC522Registers.txASKReg, 0x40) && ok;
    // CRC 預設值 0x6363
    ok = writeRegisterVerified(MFRC522Registers.modeReg, 0x3D) && ok;
    ok = antennaOn() && ok;
    return ok;
  }

  /// 設定晶片內部 timer 的逾時，傳送結束後自動起算 (TAuto=1)。
  ///
  /// TPrescaler = 0x0A9 = 169 → f_timer = 13.56 MHz / (2×169+1) ≈ 40 kHz，
  /// 每個 tick 25 µs，所以 ticks = ms × 40。上限 0xFFFF ≈ 1638 ms。
  bool setTimerTimeout(int milliseconds) {
    final ticks = (milliseconds * 40).clamp(1, 0xFFFF);
    var ok = writeRegisterVerified(MFRC522Registers.tModeReg, 0x80);
    ok = writeRegisterVerified(MFRC522Registers.tPrescalerReg, 0xA9) && ok;
    ok = writeRegisterVerified(
          MFRC522Registers.tReloadRegH,
          (ticks >> 8) & 0xFF,
        ) &&
        ok;
    ok =
        writeRegisterVerified(MFRC522Registers.tReloadRegL, ticks & 0xFF) && ok;
    return ok;
  }

  /// 開天線並確認 Tx1RFEn / Tx2RFEn 真的有設上。
  /// 直接寫 reset 值加上兩個致能位元，不做 read-modify-write，
  /// 讀回被干擾成 0xFF 之類的值時才不會把錯的位元一起寫進去。
  bool antennaOn() {
    return writeRegisterVerified(
      MFRC522Registers.txControlReg,
      txControlAntennaOn,
      mask: 0x03,
    );
  }

  void antennaOff() {
    writeRegister(
      MFRC522Registers.txControlReg,
      txControlAntennaOn & ~0x03 & 0xFF,
    );
  }

  /// FlushBuffer 之後 FIFOLevel 應為 0
  bool _flushFifoVerified() {
    if (!_verifyEnabled) {
      writeRegister(MFRC522Registers.fifoLevelReg, 0x80);
      return true;
    }
    for (var attempt = 0;; attempt++) {
      writeRegister(MFRC522Registers.fifoLevelReg, 0x80);
      if ((readRegister(MFRC522Registers.fifoLevelReg) & 0x7F) == 0) {
        return true;
      }
      if (attempt >= writeVerifyRetries) return false;
      verifyRetries++;
    }
  }

  /// 把要送的資料寫進 FIFO，並確認 FIFOLevel 等於送出的 byte 數
  bool _loadFifoVerified(List<int> sendData) {
    if (!_verifyEnabled) {
      for (final byte in sendData) {
        writeRegister(MFRC522Registers.fifoDataReg, byte & 0xFF);
      }
      return true;
    }
    for (var attempt = 0;; attempt++) {
      for (final byte in sendData) {
        writeRegister(MFRC522Registers.fifoDataReg, byte & 0xFF);
      }
      if ((readRegister(MFRC522Registers.fifoLevelReg) & 0x7F) ==
          sendData.length) {
        return true;
      }
      if (attempt >= writeVerifyRetries) return false;
      verifyRetries++;
      if (!_flushFifoVerified()) return false;
    }
  }

  /// 送指令給晶片並等待完成。
  ///
  /// [bitFraming] 是 BitFramingReg 的值 (REQA 用 0x07 只送 7 個 bit)，
  /// StartSend 用直接寫入 `bitFraming | 0x80`，不做 read-modify-write。
  ///
  /// 回傳的 status：
  /// - [MFRC522Status.ok]：有收到卡片回應
  /// - [MFRC522Status.notag]：晶片 timer 逾時，代表晶片正常但場內沒有卡
  /// - [MFRC522Status.timeout]：牆鐘上限內晶片連 timer IRQ 都沒舉起，
  ///   通常是 SPI 線路或供電問題
  /// - [MFRC522Status.spiError]：準備階段的暫存器寫入重寫後仍讀回不符
  /// - [MFRC522Status.error]：ErrIRq 舉起或 ErrorReg 有錯誤位元
  Mfrc522Reply communicate(
    int command,
    List<int> sendData, {
    int bitFraming = 0x00,
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

    const failed = (
      status: MFRC522Status.spiError,
      backData: <int>[],
      backLen: 0,
    );
    const errorReply = (
      status: MFRC522Status.error,
      backData: <int>[],
      backLen: 0,
    );

    // 準備階段的寫入都讀回驗證；重寫後仍不符就不要啟動指令
    if (!writeRegisterVerified(MFRC522Registers.comIEnReg, irqEn | 0x80)) {
      return failed;
    }
    // Set1 = 0 且其餘位元為 1：清掉全部七個 IRQ 旗標 (寫入語意特殊，不讀回驗證)
    writeRegister(MFRC522Registers.comIrqReg, 0x7F);
    if (!_flushFifoVerified()) return failed;
    if (!writeRegisterVerified(
      MFRC522Registers.commandReg,
      MFRC522Commands.idle,
    )) {
      return failed;
    }
    if (!_loadFifoVerified(sendData)) return failed;
    final framing = bitFraming & 0x7F;
    if (!writeRegisterVerified(MFRC522Registers.bitFramingReg, framing)) {
      return failed;
    }
    if (!writeRegisterVerified(MFRC522Registers.commandReg, command)) {
      return failed;
    }
    if (command == MFRC522Commands.transceive) {
      // StartSend：直接寫已知值，不讀回 (StartSend 會自清)
      writeRegister(MFRC522Registers.bitFramingReg, framing | 0x80);
    }

    // 等 IRQ：成功旗標、ErrIRq 或 TimerIRq 任一舉起就離開；
    // 期限到了之後再讀最後一次，系統卡頓時才不會把已經完成的結果當成無回應。
    final deadline = deadlineMs ?? commDeadlineMs;
    final stopwatch = Stopwatch()..start();
    var completed = false;
    var errorFired = false;
    var timerFired = false;
    var finalRead = false;
    while (true) {
      final irq = readRegister(MFRC522Registers.comIrqReg);
      if ((irq & waitIRq) != 0) {
        completed = true;
        break;
      }
      if ((irq & 0x02) != 0) {
        errorFired = true;
        break;
      }
      if ((irq & 0x01) != 0) {
        timerFired = true;
        break;
      }
      if (stopwatch.elapsedMilliseconds >= deadline) {
        if (finalRead) break;
        finalRead = true;
      }
    }

    writeRegister(MFRC522Registers.bitFramingReg, framing);

    if (errorFired) return errorReply;
    if (!completed) {
      return (
        status: timerFired ? MFRC522Status.notag : MFRC522Status.timeout,
        backData: const <int>[],
        backLen: 0,
      );
    }

    // BufferOvfl / CollErr / ParityErr / ProtocolErr
    if ((readRegister(MFRC522Registers.errorReg) & 0x1B) != 0) {
      return errorReply;
    }

    if (command != MFRC522Commands.transceive) {
      return (status: MFRC522Status.ok, backData: const <int>[], backLen: 0);
    }

    var count = readRegister(MFRC522Registers.fifoLevelReg) & 0x7F;
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
    final reply = communicate(
      MFRC522Commands.transceive,
      [reqMode],
      bitFraming: 0x07,
    );

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
    final reply = communicate(
      MFRC522Commands.transceive,
      [PICCCommands.anticoll, 0x20],
      bitFraming: 0x00,
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
