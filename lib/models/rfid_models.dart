/// 一顆 RC522 的接線設定
class ReaderConfig {
  /// 讀卡機編號 (1 起算)，deviceId 為兩位數字串 ("01"…"07")
  final int deviceNum;

  /// SPI bus 編號，0 代表 /dev/spidev0.0
  final int spiNum;

  /// RST 腳的 BCM GPIO 編號。七顆共用 SPI bus，靠 RST 決定哪一顆醒著。
  final int rstPin;

  const ReaderConfig({
    required this.deviceNum,
    required this.spiNum,
    required this.rstPin,
  });

  String get deviceId => deviceNum.toString().padLeft(2, '0');

  Map<String, int> toJson() => {
        'deviceNum': deviceNum,
        'spiNum': spiNum,
        'rstPin': rstPin,
      };

  factory ReaderConfig.fromJson(Map<String, dynamic> json) => ReaderConfig(
        deviceNum: (json['deviceNum'] as num).toInt(),
        spiNum: (json['spiNum'] as num).toInt(),
        rstPin: (json['rstPin'] as num).toInt(),
      );

  @override
  String toString() =>
      'ReaderConfig(device: $deviceId, spi: $spiNum, rst: GPIO$rstPin)';
}

/// 7 顆 RC522 的預設接線
///
/// 共用 SPI bus /dev/spidev0.0 (MISO=GPIO9, MOSI=GPIO10, SCK=GPIO11, CE0=GPIO8)，
/// 每顆的 RST 各接一支 GPIO。這份表是 Flutter adapter 與 CLI 校正工具共同的來源。
const List<ReaderConfig> defaultReaderConfigs = [
  ReaderConfig(deviceNum: 1, spiNum: 0, rstPin: 22),
  ReaderConfig(deviceNum: 2, spiNum: 0, rstPin: 27),
  ReaderConfig(deviceNum: 3, spiNum: 0, rstPin: 17),
  ReaderConfig(deviceNum: 4, spiNum: 0, rstPin: 4),
  ReaderConfig(deviceNum: 5, spiNum: 0, rstPin: 23),
  ReaderConfig(deviceNum: 6, spiNum: 0, rstPin: 24),
  ReaderConfig(deviceNum: 7, spiNum: 0, rstPin: 25),
];

class RFIDEvent {
  final int readerNum;
  final int? tagId;
  final String? error;
  final DateTime timestamp;

  RFIDEvent({
    required this.readerNum,
    this.tagId,
    this.error,
  }) : timestamp = DateTime.now();

  bool get isError => error != null;
  bool get hasTag => tagId != null;

  @override
  String toString() {
    if (isError) {
      return 'Reader $readerNum Error: $error';
    } else if (hasTag) {
      return 'Reader $readerNum detected tag: $tagId';
    } else {
      return 'Reader $readerNum: No tag detected';
    }
  }
}
