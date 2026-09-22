/// Platform-Specific Settings Screen
///
/// Displays different configuration options based on the platform:
/// - Serial: Port addresses, baud rate, scan timeout
/// - GPIO/SPI: Pin configurations, SPI settings
/// - Mock: Test scenario selection
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:provider/provider.dart';

import '../provider/rfid_reader_provider.dart';
import '../provider/data_provider.dart';
import '../interfaces/rfid_reader.dart';
import '../utils/platform_detector.dart';
import '../services/data_persistence_service.dart';
import '../services/meal_identification_service.dart';
import '../services/pdf_generation_service.dart';
import '../services/printer_service.dart';
import 'printer_selection_dialog.dart';
import 'rfid_timing_settings.dart';

class SettingPage extends StatelessWidget {
  const SettingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '設定',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Row(
          children: [
            // Left column: RFID Reader Settings
            Expanded(
              flex: 3,
              child: _buildReaderSettingsColumn(context),
            ),
            const SizedBox(width: 16),
            // Right column: Printer and Other Settings
            Expanded(
              flex: 2,
              child: _buildPrinterSettingsColumn(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReaderSettingsColumn(BuildContext context) {
    final rfidProvider = context.watch<RFIDReaderProvider>();

    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Platform Info
        _buildPlatformInfo(context),
        const SizedBox(height: 16),

        // 輪巡時序設定 (預設收合，展開才佔空間)
        _buildTimingInfo(context, rfidProvider),
        const SizedBox(height: 16),

        // Reader Status Cards
        Expanded(
          child: _buildReaderStatusSection(context, rfidProvider),
        ),
        const SizedBox(height: 16),

        // Refresh Button
        _buildRefreshButton(context, rfidProvider),
      ],
    );
  }

  Widget _buildPlatformInfo(BuildContext context) {
    final platform = PlatformDetector.detectPlatform();
    final platformName = PlatformDetector.getPlatformName(platform);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '平台資訊',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  _getPlatformIcon(platform),
                  color: Theme.of(context).colorScheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Text(
                  platformName,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _getPlatformIcon(PlatformType platform) {
    switch (platform) {
      case PlatformType.raspberryPi:
        return Icons.developer_board;
      case PlatformType.mock:
        return Icons.science;
      case PlatformType.unknown:
        return Icons.help_outline;
    }
  }

  /// 輪巡時序設定：編輯、連線檢測、自動最佳化 (見 rfid_timing_settings.dart)
  Widget _buildTimingInfo(BuildContext context, RFIDReaderProvider provider) {
    return RfidTimingSettingsCard(provider: provider);
  }

  Widget _buildReaderStatusSection(
    BuildContext context,
    RFIDReaderProvider provider,
  ) {
    // Create meal identification service instance
    final mealService = MealIdentificationService();
    final now = DateTime.now();
    final lastUpdate = provider.lastUpdateTime ?? now;
    final minutesAgo = now.difference(lastUpdate).inMinutes;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section header
            Text(
              'RFID 讀卡機狀態',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),

            // Statistics
            _buildReaderStats(context, provider),

            const SizedBox(height: 8),

            // Last update timestamp and duration
            Text(
              '最後掃描: ${minutesAgo == 0 ? "剛剛" : "$minutesAgo 分鐘前"}'
              '${provider.lastScanDuration != null ? "，耗時 ${provider.lastScanDuration!.inMilliseconds} ms" : ""}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),

            const SizedBox(height: 16),

            // Reader cards
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: provider.readers.map((reader) {
                    final reading = provider.getReading(reader.deviceId);
                    final rfidId = reading?.rfid ?? '';
                    final dishName = rfidId.isNotEmpty
                        ? mealService.identifyMeal(rfidId)
                        : null;

                    // Use reading status if available, fallback to reader status
                    final displayStatus = reading?.status ?? reader.status;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ReaderStatusRow(
                        deviceId: reader.deviceId,
                        status: displayStatus,
                        address: reader.address,
                        rfidId: rfidId,
                        dishName: dishName,
                        // 只顯示錯誤訊息；工程師用的摘要在時序卡片的「詳細診斷」
                        detail: reading?.errorMessage,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReaderStats(
    BuildContext context,
    RFIDReaderProvider provider,
  ) {
    final statusSummary = provider.getReaderStatusSummary();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatItem(
            label: '總計',
            value: provider.readerCount.toString(),
            icon: Icons.devices,
          ),
          _StatItem(
            label: '正常',
            value: (statusSummary['ok'] ?? 0).toString(),
            icon: Icons.check_circle,
            color: Colors.green,
          ),
          _StatItem(
            label: '錯誤',
            value: (statusSummary['error'] ?? 0).toString(),
            icon: Icons.error,
            color: Colors.red,
          ),
          _StatItem(
            label: '已識別',
            value: provider.validCardCount.toString(),
            icon: Icons.credit_card,
            color: Colors.blue,
          ),
        ],
      ),
    );
  }

  Widget _buildRefreshButton(
    BuildContext context,
    RFIDReaderProvider provider,
  ) {
    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: provider.isScanning
            ? null
            : () async {
                await provider.updateReaders();
              },
        icon: provider.isScanning
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.refresh),
        label: Text(provider.isScanning ? '掃描中...' : '掃描 RFID 讀卡機'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildPrinterSettingsColumn(BuildContext context) {
    final dataProvider = context.watch<DataProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Printer selection card
        Card(
          elevation: 2,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '列印設定',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(Icons.print, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '目前印表機',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            dataProvider.printerName.isEmpty
                                ? '未選擇印表機'
                                : dataProvider.printerName,
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w500,
                                      color: dataProvider.printerName.isEmpty
                                          ? Colors.red
                                          : null,
                                    ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _handleSelectPrinter(context),
                    icon: const Icon(Icons.edit),
                    label: const Text('選擇印表機'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Card(
          elevation: 2,
          child: SwitchListTile(
            title: Text(
              '包含三章一Q頁面',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            subtitle: const Text('列印營養報告時包含三章一Q資訊'),
            value: context.watch<DataProvider>().includeLabelPage,
            onChanged: (value) async {
              context.read<DataProvider>().includeLabelPage = value;
              // Save preference immediately
              await DataPersistenceService.saveIncludeLabelPage(value);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('設定已儲存 ✓'),
                    duration: Duration(seconds: 1),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 24),
        // Printing test button
        SizedBox(
          height: 48,
          width: double.infinity,
          child: FilledButton.tonal(
            onPressed: () => _handlePrintingTest(context),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.print),
                SizedBox(width: 8),
                Text('列印測試'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Close app button
        SizedBox(
          height: 48,
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _handleCloseApp(context),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              foregroundColor: Colors.red[700],
              side: BorderSide(color: Colors.red[700]!),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.close),
                SizedBox(width: 8),
                Text('關閉應用程式'),
              ],
            ),
          ),
        ),
        const Spacer(),
      ],
    );
  }

  /// Handles printer selection action
  Future<void> _handleSelectPrinter(BuildContext context) async {
    final dataProvider = context.read<DataProvider>();

    final selectedPrinterUrl = await showPrinterSelectionDialog(
      context,
      currentPrinterName: dataProvider.printerName,
    );

    if (selectedPrinterUrl != null) {
      // Update the printer name in the provider
      dataProvider.printerName = selectedPrinterUrl;

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('印表機已更新: $selectedPrinterUrl'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Handles the printing test action
  Future<void> _handlePrintingTest(BuildContext context) async {
    final dataProvider = context.read<DataProvider>();
    final printerName = dataProvider.printerName;

    // Show loading dialog
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('正在產生測試 PDF...'),
                ],
              ),
            ),
          ),
        ),
      );
    }

    try {
      // Check printer availability
      final printerAvailable =
          await PrinterService.isPrinterAvailable(printerName);

      if (!printerAvailable) {
        if (context.mounted) {
          Navigator.of(context).pop(); // Close loading dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('找不到印表機 "$printerName"'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Generate and print test PDF
      final format = PdfPageFormat.a4.landscape;
      final includeLabelPage = dataProvider.includeLabelPage;
      await PrinterService.printPdf(
        printerName: printerName,
        format: format,
        onLayout: (format) => PDFGenerationService.generateTestPdf(
          format: format,
          includeLabelPage: includeLabelPage,
        ),
        usePrinterSettings: true,
      );

      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('測試列印工作已成功送出'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('列印測試失敗: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  /// Handles the close app action
  Future<void> _handleCloseApp(BuildContext context) async {
    // Show confirmation dialog
    final shouldClose = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('關閉應用程式'),
        content: const Text('確定要關閉應用程式嗎?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('關閉'),
          ),
        ],
      ),
    );

    if (shouldClose == true) {
      // Exit the application
      exit(0);
    }
  }
}

/// Widget for displaying individual reader status in row layout
class _ReaderStatusRow extends StatelessWidget {
  final String deviceId;
  final ReaderStatus status;
  final String address;
  final String rfidId;
  final String? dishName;

  /// 錯誤訊息，顯示在卡片資訊區
  final String? detail;

  const _ReaderStatusRow({
    required this.deviceId,
    required this.status,
    required this.address,
    required this.rfidId,
    this.dishName,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final bool hasCard = rfidId.isNotEmpty && status == ReaderStatus.ok;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            // Status Icon
            Icon(
              _getStatusIcon(),
              color: status.color,
              size: 32,
            ),
            const SizedBox(width: 16),

            // Reader Info
            Expanded(
              flex: 2,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '讀卡機 $deviceId',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: status.color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: status.color.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          status.displayName,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: status.color,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _getShortAddress(),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(width: 16),

            // Card Detection Info
            Expanded(
              flex: 3,
              child: hasCard
                  ? _buildCardDetectedInfo(context)
                  : _buildNoCardInfo(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardDetectedInfo(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.green[200]!, width: 1.5),
      ),
      child: Row(
        children: [
          // RFID Icon
          Icon(
            Icons.credit_card,
            color: Colors.green[700],
            size: 24,
          ),
          const SizedBox(width: 12),

          // RFID Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        rfidId,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              color: Colors.green[900],
                            ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    InkWell(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: rfidId));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已複製 RFID'),
                            duration: Duration(seconds: 1),
                            backgroundColor: Colors.green,
                          ),
                        );
                      },
                      child: Icon(
                        Icons.copy,
                        size: 18,
                        color: Colors.grey[700],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  dishName ?? '未知料理',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: dishName != null
                            ? Colors.green[900]
                            : Colors.orange[900],
                        fontWeight: FontWeight.w600,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoCardInfo(BuildContext context) {
    final isError = status == ReaderStatus.error;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? Colors.red[50] : Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isError ? Colors.red[200]! : Colors.grey[300]!,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.link_off : Icons.credit_card_off,
            size: 24,
            color: isError ? Colors.red[700] : Colors.grey[500],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isError ? '線路異常，請檢查接線' : '未偵測到卡片',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: isError ? Colors.red[900] : Colors.grey[600],
                        fontWeight: isError ? FontWeight.w600 : null,
                      ),
                ),
                if (detail != null && detail!.isNotEmpty)
                  Text(
                    detail!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _getStatusIcon() {
    switch (status) {
      case ReaderStatus.ok:
        return Icons.check_circle;
      case ReaderStatus.error:
        return Icons.error;
      case ReaderStatus.updating:
        return Icons.refresh;
      case ReaderStatus.init:
        return Icons.radio_button_unchecked;
      case ReaderStatus.disconnected:
        return Icons.cloud_off;
    }
  }

  String _getShortAddress() {
    // Shorten address for display
    if (address.contains('/dev/')) {
      return address.split('/').last;
    }
    if (address.contains('MOCK')) {
      return 'Mock';
    }
    if (address.contains('GPIO')) {
      // Extract GPIO pin number from format like "SPI0.0/GPIO22"
      final match = RegExp(r'GPIO(\d+)').firstMatch(address);
      if (match != null) {
        return 'RST GPIO ${match.group(1)}';
      }
      return 'GPIO';
    }
    return address;
  }
}

/// Stat item widget
class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  const _StatItem({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color ?? Colors.grey[700], size: 24),
        const SizedBox(height: 6),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
