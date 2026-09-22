/// 輪巡時序設定：設定頁的卡片、編輯對話框、連線檢測、自動最佳化
///
/// 所有硬體操作都透過 [RFIDReaderProvider] 交給 adapter 在 background isolate 執行，
/// 這裡只負責顯示與收集輸入。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../provider/rfid_reader_provider.dart';
import '../services/rfid_calibration.dart';
import '../services/rfid_optimizer.dart';
import '../services/rfid_timing_config.dart';
import '../services/simple_mfrc522.dart';

/// 設定頁左欄的「輪巡時序設定」卡片
class RfidTimingSettingsCard extends StatelessWidget {
  final RFIDReaderProvider provider;

  const RfidTimingSettingsCard({super.key, required this.provider});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final load = provider.timingLoad;
    final config = load?.config;
    final scanMs = provider.lastScanDuration?.inMilliseconds;
    final deviceIds = provider.readers.map((r) => r.deviceId).toList();
    final busy = provider.isScanning || provider.isCalibrating;
    final supported = provider.supportsCalibration;

    final String summary;
    if (!supported) {
      summary = '模擬讀卡機，沒有硬體時序設定';
    } else if (config == null) {
      summary = '尚未載入設定 (第一次掃描或按「編輯設定」時載入)';
    } else {
      final overrides = config.hasReaderOverrides
          ? '，${config.overriddenReaderIds.length} 顆有個別覆寫'
          : '';
      summary = 'SPI ${config.spiSpeedHz} Hz，RST 後 ${config.rstSettleMs} ms，'
          '天線後 ${config.antennaSettleMs} ms，'
          'REQA ${config.reqaTimeoutMs} ms × ${config.reqaAttempts} 次$overrides';
    }

    String? estimate;
    if (config != null && deviceIds.isNotEmpty) {
      estimate = '估計一輪：全部沒卡約 ${config.estimateNoCardScanMsFor(deviceIds)} ms，'
          '七顆都有卡約 ${config.estimateAllCardsScanMsFor(deviceIds)} ms'
          '${scanMs != null ? '，上次實測 $scanMs ms' : ''}';
    } else if (scanMs != null) {
      estimate = '上次掃描耗時 $scanMs ms';
    }

    // 預設收合：1280×720 時左欄還有平台資訊與讀卡機列表，展開才佔空間
    final diagnostics = provider.diagnostics;
    return Card(
      elevation: 2,
      child: ExpansionTile(
        leading: const Icon(Icons.timer_outlined),
        title: Row(
          children: [
            Text(
              '輪巡時序設定',
              style:
                  textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            if (provider.isCalibrating) ...[
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('校正中', style: textTheme.bodySmall),
            ],
          ],
        ),
        subtitle: Text(
          summary,
          style: textTheme.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (estimate != null)
            Text(
              estimate,
              style: textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          if (load != null)
            Text(
              load.sourceDescription,
              // 設定檔壞掉時 app 會靜默退回預設值，用醒目顏色提醒操作者
              style: textTheme.bodySmall?.copyWith(
                color: load.error != null ? Colors.red : Colors.grey[600],
                fontWeight: load.error != null ? FontWeight.w600 : null,
              ),
              maxLines: load.error != null ? 4 : 2,
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: supported && !busy
                    ? () => showTimingEditDialog(context, provider)
                    : null,
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('編輯設定'),
              ),
              OutlinedButton.icon(
                onPressed: supported && !busy
                    ? () => showLinkCheckDialog(context, provider)
                    : null,
                icon: const Icon(Icons.cable, size: 18),
                label: const Text('連線檢測'),
              ),
              FilledButton.icon(
                onPressed: supported && !busy
                    ? () => showOptimizeDialog(context, provider)
                    : null,
                icon: const Icon(Icons.auto_fix_high, size: 18),
                label: const Text('自動最佳化'),
              ),
              TextButton.icon(
                onPressed:
                    supported && !busy ? () => provider.reloadSettings() : null,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新載入設定檔'),
              ),
            ],
          ),
          if (diagnostics.isNotEmpty) ...[
            const SizedBox(height: 8),
            // 工程師用的細節 (設定來源、每個欄位、每顆的摘要) 收在這裡
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text('詳細診斷', style: textTheme.bodySmall),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in diagnostics.entries)
                  Text(
                    '${entry.key}: ${entry.value}',
                    style:
                        textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// 編輯設定
// -----------------------------------------------------------------------------

/// 先載入目前設定，再開編輯對話框
Future<void> showTimingEditDialog(
  BuildContext context,
  RFIDReaderProvider provider,
) async {
  final load = await provider.loadTiming();
  if (!context.mounted) return;
  final saved = await showDialog<bool>(
    context: context,
    // 點對話框外面會靜默丟掉修改，一律要按「取消」或「儲存」
    barrierDismissible: false,
    builder: (_) => _TimingEditDialog(
      provider: provider,
      initial: load?.config ?? RfidTimingConfig.defaults,
    ),
  );
  if (saved == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('時序設定已儲存 ✓'), backgroundColor: Colors.green),
    );
  }
}

class _TimingEditDialog extends StatefulWidget {
  final RFIDReaderProvider provider;
  final RfidTimingConfig initial;

  const _TimingEditDialog({required this.provider, required this.initial});

  @override
  State<_TimingEditDialog> createState() => _TimingEditDialogState();
}

class _TimingEditDialogState extends State<_TimingEditDialog> {
  static const List<int> _speedChoices = [1000000, 500000, 250000, 125000];

  /// 每個欄位的加減步距 (觸控 kiosk 沒有鍵盤，用按鈕調)
  static const Map<String, int> _steps = {
    'rstSettleMs': 5,
    'linkCheckTimeoutMs': 10,
    'antennaSettleMs': 5,
    'reqaTimeoutMs': 5,
    'reqaAttempts': 1,
    'commDeadlineMs': 5,
    'interReaderGapMs': 5,
    'postScanSettleMs': 50,
    'scanTimeoutSec': 1,
    'writeVerifyRetries': 1,
    'anticollRetries': 1,
    'readerRetries': 1,
    'pollGapMs': 50,
    'stickyRounds': 1,
  };

  late Map<String, int> _values;
  late int _spiSpeedHz;
  late Map<String, Map<String, int>> _overrides;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final json = widget.initial.toBaseJson();
    _values = {
      for (final key in RfidTimingConfig.keys)
        if (key != 'spiSpeedHz') key: json[key]!,
    };
    _spiSpeedHz = widget.initial.spiSpeedHz;
    _overrides = {
      for (final entry in widget.initial.readerOverrides.entries)
        entry.key: Map<String, int>.from(entry.value),
    };
  }

  void _resetToDefaults() {
    final json = RfidTimingConfig.defaults.toBaseJson();
    setState(() {
      for (final key in _values.keys.toList()) {
        _values[key] = json[key]!;
      }
      _spiSpeedHz = RfidTimingConfig.defaults.spiSpeedHz;
      _overrides = {};
      _error = null;
    });
  }

  RfidTimingConfig _buildConfig() {
    final json = <String, dynamic>{'spiSpeedHz': _spiSpeedHz, ..._values};
    json[RfidTimingConfig.readersKey] = _overrides;
    return RfidTimingConfig.fromJson(json).validated();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.provider.saveTiming(_buildConfig());
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '儲存失敗: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final speedItems = {..._speedChoices, _spiSpeedHz}.toList()
      ..sort((a, b) => b.compareTo(a));
    final overriddenIds = _overrides.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList()
      ..sort();

    return AlertDialog(
      title: const Text('編輯輪巡時序設定'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '這些是全域值；有個別覆寫的讀卡機會以覆寫值為準。'
                '不確定的話按「自動最佳化」讓程式量出來。長按加減可以連續調。',
                style: textTheme.bodySmall?.copyWith(color: Colors.grey[700]),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 350,
                    child: DropdownButtonFormField<int>(
                      initialValue: _spiSpeedHz,
                      decoration: InputDecoration(
                        labelText: RfidTimingConfig.labels['spiSpeedHz'],
                        helperText: RfidTimingConfig.hints['spiSpeedHz'],
                        helperMaxLines: 2,
                        border: const OutlineInputBorder(),
                      ),
                      items: [
                        for (final speed in speedItems)
                          DropdownMenuItem(
                            value: speed,
                            child: Text('$speed Hz'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _spiSpeedHz = value);
                        }
                      },
                    ),
                  ),
                  for (final key in _values.keys)
                    SizedBox(
                      width: 350,
                      child: _IntStepper(
                        label: RfidTimingConfig.labels[key] ?? key,
                        hint: RfidTimingConfig.hints[key],
                        value: _values[key]!,
                        min: RfidTimingConfig.ranges[key]!.$1,
                        max: RfidTimingConfig.ranges[key]!.$2,
                        step: _steps[key] ?? 1,
                        enabled: !_saving,
                        onChanged: (value) =>
                            setState(() => _values[key] = value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text(
                    '各讀卡機的個別覆寫',
                    style: textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (overriddenIds.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() => _overrides = {}),
                      icon: const Icon(Icons.clear_all, size: 18),
                      label: const Text('清除全部覆寫'),
                    ),
                ],
              ),
              if (overriddenIds.isEmpty)
                Text(
                  '目前沒有覆寫，所有讀卡機都用上面的全域值。'
                  '自動最佳化會替每顆各自寫入覆寫值。',
                  style: textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    headingRowHeight: 36,
                    dataRowMinHeight: 32,
                    dataRowMaxHeight: 40,
                    columns: [
                      const DataColumn(label: Text('讀卡機')),
                      for (final key in RfidTimingConfig.perReaderKeys)
                        DataColumn(label: Text(_shortLabel(key))),
                      const DataColumn(label: Text('')),
                    ],
                    rows: [
                      for (final id in overriddenIds)
                        DataRow(cells: [
                          DataCell(Text(id)),
                          for (final key in RfidTimingConfig.perReaderKeys)
                            DataCell(Text(
                              _overrides[id]![key]?.toString() ?? '-',
                            )),
                          DataCell(IconButton(
                            tooltip: '清除這顆的覆寫',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () =>
                                setState(() => _overrides.remove(id)),
                          )),
                        ]),
                    ],
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _resetToDefaults,
          child: const Text('還原預設值'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '儲存中…' : '儲存'),
        ),
      ],
    );
  }
}

/// 「− 值 +」的整數步進欄位：觸控 kiosk 沒有螢幕鍵盤時仍能調整。
/// 長按會連續加減，按住越久步距越大。
class _IntStepper extends StatefulWidget {
  final String label;
  final String? hint;
  final int value;
  final int min;
  final int max;
  final int step;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _IntStepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.step,
    required this.onChanged,
    this.hint,
    this.enabled = true,
  });

  @override
  State<_IntStepper> createState() => _IntStepperState();
}

class _IntStepperState extends State<_IntStepper> {
  Timer? _repeat;
  int _repeats = 0;

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _nudge(int direction) {
    // 按住超過 15 下之後步距放大 5 倍，從 5 調到 500 不用等太久
    final multiplier = _repeats >= 15 ? 5 : 1;
    final next = (widget.value + direction * widget.step * multiplier)
        .clamp(widget.min, widget.max);
    if (next != widget.value) widget.onChanged(next);
  }

  void _startRepeat(int direction) {
    _repeats = 0;
    _repeat?.cancel();
    _repeat = Timer.periodic(const Duration(milliseconds: 120), (_) {
      _repeats++;
      _nudge(direction);
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
    _repeats = 0;
  }

  Widget _button(IconData icon, int direction, bool enabled) {
    return GestureDetector(
      onLongPressStart: enabled ? (_) => _startRepeat(direction) : null,
      onLongPressEnd: enabled ? (_) => _stopRepeat() : null,
      onLongPressCancel: enabled ? _stopRepeat : null,
      child: IconButton(
        icon: Icon(icon),
        onPressed: enabled ? () => _nudge(direction) : null,
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final canDecrease = widget.enabled && widget.value > widget.min;
    final canIncrease = widget.enabled && widget.value < widget.max;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.hint,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      child: Row(
        children: [
          _button(Icons.remove, -1, canDecrease),
          Expanded(
            child: Text(
              '${widget.value}',
              textAlign: TextAlign.center,
              style: textTheme.titleMedium,
            ),
          ),
          _button(Icons.add, 1, canIncrease),
        ],
      ),
    );
  }
}

String _shortLabel(String key) {
  switch (key) {
    case 'rstSettleMs':
      return 'RST ms';
    case 'linkCheckTimeoutMs':
      return '連線檢查 ms';
    case 'antennaSettleMs':
      return '天線 ms';
    case 'reqaTimeoutMs':
      return 'REQA ms';
    case 'reqaAttempts':
      return 'REQA 次數';
    case 'commDeadlineMs':
      return '牆鐘 ms';
    case 'writeVerifyRetries':
      return '重寫';
    case 'anticollRetries':
      return 'anticoll 重送';
    case 'readerRetries':
      return '重讀';
    default:
      return key;
  }
}

// -----------------------------------------------------------------------------
// 連線檢測
// -----------------------------------------------------------------------------

Future<void> showLinkCheckDialog(
  BuildContext context,
  RFIDReaderProvider provider,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _LinkCheckDialog(provider: provider),
  );
}

class _LinkCheckDialog extends StatefulWidget {
  final RFIDReaderProvider provider;

  const _LinkCheckDialog({required this.provider});

  @override
  State<_LinkCheckDialog> createState() => _LinkCheckDialogState();
}

class _LinkCheckDialogState extends State<_LinkCheckDialog> {
  String _message = '準備中…';
  List<LinkMeasurement>? _measurements;
  CalibrationRecommendation? _recommendation;

  /// 量測本身失敗 (沒有結果可看)
  String? _error;

  /// 套用建議失敗：結果表要留著，操作者可以再按一次
  String? _applyError;
  bool _applying = false;

  bool get _running => _measurements == null && _error == null;

  @override
  void initState() {
    super.initState();
    // 等第一個 frame 畫完再開始，provider 的通知才不會落在 build 期間
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  Future<void> _start() async {
    try {
      final measurements = await widget.provider.probeLinks(
        onProgress: (message) {
          if (mounted) setState(() => _message = message);
        },
      );
      final base =
          widget.provider.timingLoad?.config ?? RfidTimingConfig.defaults;
      if (!mounted) return;
      setState(() {
        _measurements = measurements;
        _recommendation = RfidCalibration.recommend(
          base: base,
          measurements: measurements,
        );
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _applyRecommendation() async {
    final recommendation = _recommendation;
    if (recommendation == null) return;
    setState(() {
      _applying = true;
      _applyError = null;
    });
    try {
      await widget.provider.saveTiming(recommendation.config);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已套用建議的 SPI 時脈與 RST 等待 ✓'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _applying = false;
          _applyError = '套用失敗: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final measurements = _measurements;

    Widget body;
    if (_error != null) {
      body = Text(_error!, style: const TextStyle(color: Colors.red));
    } else if (measurements == null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(),
          const SizedBox(height: 12),
          Text(_message),
          const SizedBox(height: 4),
          Text(
            '不需要放卡片。每個時脈、每顆讀卡機各做 200 次讀寫檢查，約需幾秒。',
            style: textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
          ),
        ],
      );
    } else {
      final sorted = [...measurements]..sort((a, b) {
          final byId = a.probe.deviceId.compareTo(b.probe.deviceId);
          return byId != 0 ? byId : b.spiSpeedHz.compareTo(a.spiSpeedHz);
        });
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_applyError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _applyError!,
                style: const TextStyle(
                    color: Colors.red, fontWeight: FontWeight.w600),
              ),
            ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 20,
              headingRowHeight: 36,
              dataRowMinHeight: 30,
              dataRowMaxHeight: 36,
              columns: const [
                DataColumn(label: Text('讀卡機')),
                DataColumn(label: Text('SPI Hz')),
                DataColumn(label: Text('就緒 ms')),
                DataColumn(label: Text('VersionReg')),
                DataColumn(label: Text('錯誤/樣本')),
                DataColumn(label: Text('結果')),
              ],
              rows: [
                for (final m in sorted)
                  DataRow(cells: [
                    DataCell(Text(m.probe.deviceId)),
                    DataCell(Text(m.spiSpeedHz.toString())),
                    DataCell(Text(m.probe.timeToReadyMs?.toString() ?? '-')),
                    DataCell(Text(
                      '0x${m.probe.version.toRadixString(16).padLeft(2, '0').toUpperCase()}',
                    )),
                    DataCell(Text('${m.probe.mismatches}/${m.probe.samples}')),
                    DataCell(_verdictChip(m.probe)),
                  ]),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_recommendation != null) ...[
            Text(
              '建議',
              style:
                  textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            for (final note in _recommendation!.notes)
              Text('• $note', style: textTheme.bodySmall),
            Text(
              '→ SPI ${_recommendation!.config.spiSpeedHz} Hz，'
              'RST 後等待 ${_recommendation!.config.rstSettleMs} ms',
              style:
                  textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      );
    }

    return AlertDialog(
      title: const Text('連線檢測'),
      content: SizedBox(width: 720, child: SingleChildScrollView(child: body)),
      actions: [
        if (_recommendation != null)
          FilledButton(
            onPressed: _applying ? null : _applyRecommendation,
            child: Text(_applying ? '套用中…' : '套用建議'),
          ),
        TextButton(
          onPressed:
              _running || _applying ? null : () => Navigator.of(context).pop(),
          child: const Text('關閉'),
        ),
      ],
    );
  }

  Widget _verdictChip(LinkProbeResult probe) {
    final String text;
    final Color color;
    if (!probe.ready) {
      text = '未就緒';
      color = Colors.red;
    } else if (probe.clean) {
      text = 'OK';
      color = Colors.green;
    } else {
      text = '錯誤率 ${(probe.errorRate * 100).toStringAsFixed(1)}%';
      color = Colors.orange;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(text, style: TextStyle(color: color, fontSize: 12)),
    );
  }
}

// -----------------------------------------------------------------------------
// 自動最佳化
// -----------------------------------------------------------------------------

Future<void> showOptimizeDialog(
  BuildContext context,
  RFIDReaderProvider provider,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _OptimizeDialog(provider: provider),
  );
}

enum _OptimizePhase { intro, running, result, error }

class _OptimizeDialog extends StatefulWidget {
  final RFIDReaderProvider provider;

  const _OptimizeDialog({required this.provider});

  @override
  State<_OptimizeDialog> createState() => _OptimizeDialogState();
}

class _OptimizeDialogState extends State<_OptimizeDialog> {
  _OptimizePhase _phase = _OptimizePhase.intro;
  int _sweepRounds = RfidOptimizerOptions.defaults.sweepRounds;
  int _verifyRounds = RfidOptimizerOptions.defaults.verifyRounds;
  int _marginSteps = RfidOptimizerOptions.defaults.marginSteps;
  bool _skipLink = false;
  bool _sweepAttempts = RfidOptimizerOptions.defaults.sweepReqaAttempts;

  OptimizerProgress? _progress;
  OptimizationResult? _result;
  String? _error;
  RfidCancelToken? _cancel;
  bool _applying = false;

  RfidOptimizerOptions get _options => RfidOptimizerOptions.defaults.copyWith(
        sweepRounds: _sweepRounds,
        verifyRounds: _verifyRounds,
        marginSteps: _marginSteps,
        skipLinkStage: _skipLink,
        sweepReqaAttempts: _sweepAttempts,
      );

  /// 粗估：確認階段用目前設定「七顆都有卡」的一輪時間，掃描與驗證階段的值越來越小，
  /// 用一半算；不含往上放寬的情況
  int get _estimatedSeconds {
    final options = _options.validated();
    final ids = widget.provider.readers.map((r) => r.deviceId).toList();
    final config = widget.provider.timing;
    final perRoundMs = ids.isEmpty
        ? config.estimateAllCardsScanMsFor(const ['01'])
        : config.estimateAllCardsScanMsFor(ids);
    final sanityMs = options.sweepRounds * perRoundMs;
    final sweepMs = options.maxSweepRounds * perRoundMs / 2;
    final verifyMs = options.verifyRounds * perRoundMs / 2;
    final linkSeconds =
        options.skipLinkStage ? 0 : options.spiSpeeds.length * 2;
    return ((sanityMs + sweepMs + verifyMs) / 1000 + linkSeconds).round();
  }

  Future<void> _start() async {
    final cancel = RfidCancelToken();
    setState(() {
      _phase = _OptimizePhase.running;
      _cancel = cancel;
      _progress = null;
    });
    try {
      final result = await widget.provider.optimize(
        _options,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
        cancel: cancel,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _phase = _OptimizePhase.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _phase = _OptimizePhase.error;
      });
    }
  }

  Future<void> _apply() async {
    final result = _result;
    if (result == null) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      await widget.provider.saveTiming(result.config);
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('最佳化結果已套用並儲存 ✓'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      // 留在結果畫面：硬體最佳化跑了幾十秒，儲存失敗 (唯讀檔案系統、權限) 不該把結果丟掉，
      // 錯誤顯示在結果表上方，「套用並儲存」維持可按
      if (mounted) {
        setState(() {
          _applying = false;
          _error = '儲存失敗: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _OptimizePhase.intro:
        return _buildIntro(context);
      case _OptimizePhase.running:
        return _buildRunning(context);
      case _OptimizePhase.result:
        return _buildResult(context);
      case _OptimizePhase.error:
        return AlertDialog(
          title: const Text('自動最佳化'),
          content: SizedBox(
            width: 600,
            child: Text(_error ?? '未知錯誤',
                style: const TextStyle(color: Colors.red)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('關閉'),
            ),
          ],
        );
    }
  }

  Widget _buildIntro(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('自動最佳化'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '請先在七個感應器都放上卡片，再按「開始」。',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '程式會先量每顆的連線品質與就緒時間，接著把 RST 等待、天線等待、'
                'REQA 逾時從目前值往小試 (讀不到時會先往上放寬)，每顆讀卡機各自找出'
                '最小可靠值，再加一階安全餘裕並驗證。過程中請不要移動卡片。',
                style: textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _choice<int>(
                    label: '每個候選值跑幾輪',
                    value: _sweepRounds,
                    choices: const [5, 8, 12],
                    onChanged: (v) => setState(() => _sweepRounds = v),
                  ),
                  _choice<int>(
                    label: '最後驗證幾輪',
                    value: _verifyRounds,
                    choices: const [30, 60, 100],
                    onChanged: (v) => setState(() => _verifyRounds = v),
                  ),
                  _choice<int>(
                    label: '安全餘裕 (階)',
                    value: _marginSteps,
                    choices: const [0, 1, 2],
                    onChanged: (v) => setState(() => _marginSteps = v),
                  ),
                  SizedBox(
                    width: 280,
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _skipLink,
                      onChanged: (v) => setState(() => _skipLink = v ?? false),
                      title: const Text('跳過連線檢測，維持目前 SPI 時脈'),
                    ),
                  ),
                  SizedBox(
                    width: 280,
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _sweepAttempts,
                      onChanged: (v) =>
                          setState(() => _sweepAttempts = v ?? false),
                      title: const Text('也把 REQA 次數往下試'),
                      subtitle: const Text('只省沒卡時的時間，少一次重試的保險'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '預計約 $_estimatedSeconds 秒 (有讀卡機需要放寬時會更久)。',
                style: textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _start,
          icon: const Icon(Icons.play_arrow),
          label: const Text('開始'),
        ),
      ],
    );
  }

  Widget _choice<T>({
    required String label,
    required T value,
    required List<T> choices,
    required ValueChanged<T> onChanged,
  }) {
    return SizedBox(
      width: 200,
      child: DropdownButtonFormField<T>(
        initialValue: value,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final choice in choices)
            DropdownMenuItem(value: choice, child: Text('$choice')),
        ],
        onChanged: (v) {
          if (v != null) {
            onChanged(v);
          }
        },
      ),
    );
  }

  Widget _buildRunning(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final progress = _progress;
    final candidates = progress?.candidates ?? const <String, int>{};
    final sortedIds = candidates.keys.toList()..sort();
    return AlertDialog(
      title: const Text('自動最佳化進行中'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: progress?.fraction),
            const SizedBox(height: 12),
            Text(
              progress == null
                  ? '啟動中…'
                  : '${progress.stage.label}：${progress.message}',
              style:
                  textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            if (progress != null && progress.totalRounds > 0)
              Text(
                '第 ${progress.round} / ${progress.totalRounds} 輪'
                '${progress.parameter != null ? '，參數 ${RfidTimingConfig.labels[progress.parameter] ?? progress.parameter}' : ''}',
                style: textTheme.bodySmall,
              ),
            if (progress != null)
              Text(
                '已用 ${(progress.elapsedMs / 1000).toStringAsFixed(0)} 秒，'
                '進度 ${(progress.fraction * 100).toStringAsFixed(0)}%',
                style: textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
              ),
            if (sortedIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('各讀卡機目前在測的值', style: textTheme.bodySmall),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final id in sortedIds)
                    Chip(
                      label: Text('$id: ${candidates[id]}'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancel?.isCancelled == true
              ? null
              : () {
                  _cancel?.cancel();
                  setState(() {});
                },
          child: Text(_cancel?.isCancelled == true ? '取消中…' : '取消'),
        ),
      ],
    );
  }

  Widget _buildResult(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final result = _result!;
    final ids = result.deviceIds;
    final canApply =
        !result.cancelled && result.readers.values.any((r) => r.stable);

    return AlertDialog(
      title: Text(result.cancelled ? '自動最佳化已取消' : '自動最佳化結果'),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                        color: Colors.red, fontWeight: FontWeight.w600),
                  ),
                ),
              if (!result.cancelled) ...[
                Text(
                  'SPI 時脈 ${result.before.spiSpeedHz} → ${result.config.spiSpeedHz} Hz；'
                  '估計一輪 七顆都有卡 ${result.estimatedAllCardsMsBefore} → '
                  '${result.estimatedAllCardsMsAfter} ms，'
                  '全部沒卡 ${result.estimatedNoCardMsBefore} → '
                  '${result.estimatedNoCardMsAfter} ms',
                  style: textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '共跑 ${result.roundsRun} 輪，用時 ${(result.elapsedMs / 1000).toStringAsFixed(0)} 秒',
                  style: textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
                if (result.unstableReaderIds.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '讀卡機 ${result.unstableReaderIds.join('、')} 不穩定，維持原設定；'
                      '請看下方說明。',
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 18,
                    headingRowHeight: 36,
                    dataRowMinHeight: 30,
                    dataRowMaxHeight: 40,
                    columns: const [
                      DataColumn(label: Text('讀卡機')),
                      DataColumn(label: Text('就緒 ms')),
                      DataColumn(label: Text('RST ms')),
                      DataColumn(label: Text('天線 ms')),
                      DataColumn(label: Text('REQA ms')),
                      DataColumn(label: Text('次數')),
                      DataColumn(label: Text('驗證')),
                      DataColumn(label: Text('狀態')),
                    ],
                    rows: [
                      for (final id in ids) _resultRow(result.readers[id]!),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              for (final note in result.notes)
                Text('• $note', style: textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
          child: const Text('關閉'),
        ),
        if (canApply)
          FilledButton(
            onPressed: _applying ? null : _apply,
            child: Text(_applying ? '儲存中…' : '套用並儲存'),
          ),
      ],
    );
  }

  DataRow _resultRow(ReaderOptimizationSummary summary) {
    String value(String key) => summary.values[key]?.toString() ?? '-';
    final statusColor = summary.stable ? Colors.green : Colors.red;
    return DataRow(cells: [
      DataCell(Text(summary.deviceId)),
      DataCell(Text(summary.timeToReadyMs?.toString() ?? '-')),
      DataCell(Text(value('rstSettleMs'))),
      DataCell(Text(value('antennaSettleMs'))),
      DataCell(Text(value('reqaTimeoutMs'))),
      DataCell(Text(value('reqaAttempts'))),
      DataCell(Text('${summary.verifyHits}/${summary.verifyRounds}')),
      DataCell(Tooltip(
        message: summary.note ?? '',
        child: Text(
          summary.stable ? '穩定' : '不穩定',
          style: TextStyle(color: statusColor, fontWeight: FontWeight.w600),
        ),
      )),
    ]);
  }
}
