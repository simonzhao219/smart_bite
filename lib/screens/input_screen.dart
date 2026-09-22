import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:smart_bite/data/constant.dart';
import 'package:smart_bite/provider/data_provider.dart';
import 'package:smart_bite/provider/rfid_reader_provider.dart';
import 'package:smart_bite/widgets/setting_page.dart';
import 'package:smart_bite/widgets/printer_not_found_dialog.dart';
import 'package:smart_bite/interfaces/rfid_reader.dart';
import 'package:smart_bite/services/printer_service.dart';
import 'package:smart_bite/services/meal_identification_service.dart';

import 'package:pdf/pdf.dart';

enum Page {
  homePage,
  mealPage,
  activityLevelPage,
  agePage,
  sexPage,
  orderPage,
  confirmPage,
  analyzingPage,
  printingPage,
  initialingPage
}

class InputScreen extends StatefulWidget {
  const InputScreen({super.key});

  @override
  State<InputScreen> createState() => _InputScreenState();
}

class _InputScreenState extends State<InputScreen> {
  late Page _currentPage = Page.homePage;

  @override
  void initState() {
    super.initState();
    _currentPage = Page.homePage;
  }

  @override
  void dispose() {
    // Clean up any local resources and ensure provider listeners are released
    // Provider framework handles listener cleanup automatically, but explicit
    // dispose ensures proper lifecycle management
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    precacheImage(const AssetImage('assets/images/background.png'), context);
    return Scaffold(
      body: Container(
          decoration: _currentPage == Page.homePage
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.onPrimaryContainer)
              : const BoxDecoration(
                  image: DecorationImage(
                    image: AssetImage("assets/images/background.png"),
                    fit: BoxFit.cover,
                  ),
                ),
          child: Center(
            child: Padding(
              padding: _currentPage == Page.homePage
                  ? const EdgeInsets.fromLTRB(102, 120, 108, 80)
                  : const EdgeInsets.fromLTRB(102, 160, 108, 152),
              child: switch (_currentPage) {
                Page.homePage => HomePage(
                    onSubmit: () {
                      setState(() {
                        _currentPage = Page.mealPage;
                      });
                    },
                  ),
                Page.mealPage => MealPage(
                    onGoBack: () {
                      // 回到首頁：背景輪巡停止
                      context.read<RFIDReaderProvider>().stopPolling();
                      setState(() {
                        _currentPage = Page.homePage;
                      });
                    },
                    onSubmit: () {
                      setState(() {
                        _currentPage = Page.sexPage;
                      });
                    },
                  ),
                Page.sexPage => SexPage(
                    onGoBack: () {
                      setState(() {
                        _currentPage = Page.mealPage;
                      });
                    },
                    onSubmit: () {
                      setState(() {
                        _currentPage = Page.agePage;
                      });
                    },
                  ),
                Page.agePage => AgePage(
                    onGoBack: () {
                      setState(() {
                        _currentPage = Page.sexPage;
                      });
                    },
                    onSubmit: () {
                      setState(() {
                        _currentPage = Page.activityLevelPage;
                      });
                    },
                  ),
                Page.activityLevelPage => ActivityLevelPage(
                    onGoBack: () {
                      setState(() {
                        _currentPage = Page.agePage;
                      });
                    },
                    onSubmit: () {
                      setState(() {
                        _currentPage = Page.confirmPage;
                      });
                    },
                  ),
                Page.confirmPage => ConfirmPage(
                    onGoBack: () {
                      setState(() {
                        _currentPage = Page.activityLevelPage;
                      });
                    },
                    onSubmit: () {
                      setState(() {
                        _currentPage = Page.orderPage;
                      });
                    },
                  ),
                Page.orderPage => OrderPage(
                    onGoBack: () {
                      setState(() {
                        _currentPage = Page.confirmPage;
                      });
                    },
                    onSubmit: () async {
                      // Printer was already checked on HomePage, proceed with analysis
                      final dataProvider = context.read<DataProvider>();
                      final printerName = dataProvider.printerName;

                      // 分析與列印期間不輪巡，避免搶 CPU
                      await context.read<RFIDReaderProvider>().stopPolling();
                      if (!context.mounted) return;
                      setState(() {
                        _currentPage = Page.analyzingPage;
                      });

                      await dataProvider.analyze();

                      // Print using the service with error handling
                      try {
                        await PrinterService.printPdf(
                          printerName: printerName,
                          format: PdfPageFormat.a4.landscape,
                          usePrinterSettings: true,
                          onLayout: (PdfPageFormat format) =>
                              dataProvider.includeLabelPage
                                  ? dataProvider.generateCombinedPdf(format)
                                  : dataProvider.generateReportPdf(format),
                        );
                      } catch (e) {
                        debugPrint('❌ Printing error: $e');
                        // If printer fails during printing (e.g., disconnected), show dialog
                        // ignore: use_build_context_synchronously
                        await showPrinterNotFoundDialog(context, printerName);
                        // Return to order page
                        setState(() {
                          _currentPage = Page.orderPage;
                        });
                        return;
                      }

                      // Save data after successful printing
                      // ignore: use_build_context_synchronously
                      await context.read<DataProvider>().saveData();
                      await Future.delayed(const Duration(seconds: 4));

                      setState(() {
                        _currentPage = Page.printingPage;
                      });
                      await Future.delayed(const Duration(seconds: 10));

                      setState(() {
                        // 進入初始化頁面
                        _currentPage = Page.initialingPage;
                      });
                      // ignore: use_build_context_synchronously
                      await context.read<DataProvider>().initialize();
                      await Future.delayed(const Duration(seconds: 4));
                      setState(() {
                        _currentPage = Page.homePage;
                      });
                    },
                  ),
                Page.analyzingPage => const LoadingPage('分析中'),
                Page.printingPage => const LoadingPage('列印中'),
                Page.initialingPage => const LoadingPage('初始化中'),
              },
            ),
          )),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const SettingPage()));
        },
        backgroundColor: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: .1),
        child: Icon(
          Icons.settings,
          color: Theme.of(context)
              .colorScheme
              .onPrimaryContainer
              .withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

class LoadingPage extends StatelessWidget {
  final String hint;

  const LoadingPage(this.hint, {super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _HeadLine(hint),
        const SizedBox(width: 880, child: LinearProgressIndicator()),
      ],
    );
  }
}

/// Order card widget for displaying detected meal
class _OrderCard extends StatelessWidget {
  final ReaderStatus status;
  final String mealName;
  final int? readerNumber; // Reader number (1-7), null for error messages
  final double width;

  const _OrderCard({
    required this.status,
    required this.mealName,
    this.readerNumber,
    this.width = 320,
  });

  @override
  Widget build(BuildContext context) {
    // Define color palette for readers
    final readerColors = [
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.red,
      Colors.teal,
      Colors.pink,
    ];

    // Use reader-specific color if available, otherwise use status color
    final cardColor = readerNumber != null
        ? readerColors[(readerNumber! - 1) % readerColors.length]
        : status.color;

    return Container(
      width: width,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cardColor.withValues(alpha: 0.1),
        border: Border.all(color: cardColor, width: 2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Reader badge and status
          if (readerNumber != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$readerNumber',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  mealName,
                  style: TextStyle(
                    fontSize: readerNumber != null ? 16 : 14,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Refactored OrderPage using RFIDReaderProvider
class OrderPage extends StatelessWidget {
  final void Function() onGoBack;
  final void Function() onSubmit;

  const OrderPage({
    super.key,
    required this.onGoBack,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _HeadLine('6.這是您點的餐：'),

        // Meal display section
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
          child: _buildMealDisplay(context),
        ),

        // Action buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SubmitButton(
              onPressed: onGoBack,
              label: '返回',
            ),
            const SizedBox(width: 22),
            _SubmitButton(
              // 背景輪巡本來就一直在讀；這顆按鈕是「清掉保留的卡片、立刻重讀一次」
              onPressed: context.watch<RFIDReaderProvider>().isScanning
                  ? null
                  : () async {
                      await context.read<RFIDReaderProvider>().updateReaders();
                    },
              label: '重新感應',
            ),
            const SizedBox(width: 22),
            _SubmitButton(
              onPressed: context.watch<RFIDReaderProvider>().isScanning
                  ? null
                  : () async {
                      final provider = context.read<RFIDReaderProvider>();
                      final dataProvider = context.read<DataProvider>();
                      // 先停輪巡，orderNames 才不會在交接的瞬間又變
                      await provider.stopPolling();
                      dataProvider.orderNames = provider.orderNames;
                      onSubmit();
                    },
              label: '分析',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMealDisplay(BuildContext context) {
    // 背景輪巡每輪都會 notify；顯示合併後的狀態，不用 spinner 切換 (會閃爍)。
    // 只有按「重新感應」的單次掃描才顯示 spinner。
    final provider = context.watch<RFIDReaderProvider>();
    if (provider.isScanning) {
      return const CircularProgressIndicator.adaptive();
    }

    // Get all readers and their readings
    final readers = provider.readers;

    if (readers.isEmpty) {
      return const _OrderCard(
        width: 390,
        status: ReaderStatus.init,
        mealName: '沒收到您的點餐，是不知道要吃什麼嗎？可以請服務人員為您推薦！',
        readerNumber: null,
      );
    }

    // Build cards only for readers with detected cards
    final cardsWithMeals = <Widget>[];

    for (var entry in readers.asMap().entries) {
      final index = entry.key;
      final reader = entry.value;
      final readerNum = index + 1;

      // Get the (merged) reading for this reader
      final reading = provider.getReading(reader.deviceId);

      // Only show readers that have cards. 讀到與別顆相同卡片的讀卡機
      // (RST 沒拉低造成的重複) 不顯示，同一道菜才不會出現七次
      if (reading?.hasCard == true && !provider.isDuplicate(reader.deviceId)) {
        // Get meal identification service
        final mealService = MealIdentificationService();
        final mealName = mealService.identifyMeal(reading!.rfid);

        cardsWithMeals.add(_OrderCard(
          status: ReaderStatus.ok,
          mealName: mealName,
          readerNumber: readerNum,
        ));
      }
    }

    // If no cards detected, show message
    final Widget content = cardsWithMeals.isEmpty
        ? const _OrderCard(
            width: 390,
            status: ReaderStatus.init,
            mealName: '沒收到您的點餐，是不知道要吃什麼嗎？可以請服務人員為您推薦！',
            readerNumber: null,
          )
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            direction: Axis.horizontal,
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: cardsWithMeals,
          );

    // 線路異常 (背景輪巡時要連續幾輪都異常才算) 要明確提示，
    // 不能讓客人以為只是沒放餐盤；文字是對客人說的，字級跟頁面其他文字一致
    final errorIds = provider.errorReaderIds;
    if (errorIds.isEmpty) return content;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        content,
        const SizedBox(height: 16),
        Text(
          '第 ${errorIds.map(_readerNumber).join('、')} 號感應區暫時無法使用，請叫服務人員',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.red[700],
                fontWeight: FontWeight.w600,
              ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// "07" → "7"
  static String _readerNumber(String deviceId) =>
      (int.tryParse(deviceId) ?? deviceId).toString();
}

class ConfirmPage extends StatelessWidget {
  final void Function() onGoBack;
  final void Function() onSubmit;

  const ConfirmPage(
      {super.key, required this.onGoBack, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _HeadLine('5.資料確認'),
        Padding(
          padding: const EdgeInsets.fromLTRB(60, 0, 60, 0),
          child: Wrap(
              direction: Axis.horizontal,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Selector<DataProvider, Meal>(
                  selector: (_, provider) => provider.meal,
                  builder: (_, meal, __) => _InfoCard(
                      icon: switch (meal) {
                        Meal.breakfast => Icons.breakfast_dining,
                        Meal.lunch => Icons.lunch_dining,
                        Meal.dinnder => Icons.dinner_dining,
                      },
                      title: getMealLabel(meal),
                      subtitle: '這是哪一餐'),
                ),
                Selector<DataProvider, Sex>(
                  selector: (_, provider) => provider.sex,
                  builder: (_, sex, __) => _InfoCard(
                      icon: switch (sex) {
                        Sex.female => Icons.female,
                        Sex.male => Icons.male,
                      },
                      title: getSexLabel(sex),
                      subtitle: '性別'),
                ),
                Selector<DataProvider, Age>(
                  selector: (_, provider) => provider.age,
                  builder: (_, age, __) => _InfoCard(
                      icon: Icons.numbers,
                      title: getAgeLabel(age),
                      subtitle: '年齡'),
                ),
                Selector<DataProvider, ActivityLevel>(
                  selector: (_, provider) => provider.activityLevel,
                  builder: (_, activityLevel, __) => _InfoCard(
                      icon: Icons.directions_run,
                      title: getActivityLevelLabel(activityLevel),
                      subtitle: '生活活動強度'),
                ),
              ]),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SubmitButton(
              onPressed: onGoBack,
              label: '返回',
            ),
            _SubmitButton(
              onPressed: onSubmit,
              label: '確認',
            )
          ],
        )
      ],
    );
  }
}

class ActivityLevelPage extends StatelessWidget {
  final void Function() onGoBack;
  final void Function() onSubmit;

  const ActivityLevelPage(
      {super.key, required this.onGoBack, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    var getActivityChoices =
        context.select<DataProvider, List<Widget>>((provider) {
      int start = 0;
      int end = ActivityLevel.values.length;
      if (provider.age.index < 3) {
        start = 1;
        end = 3;
      } else if (provider.age.index > 6) {
        start = 0;
        end = 3;
      }
      return List<Widget>.generate(
        ActivityLevel.values.length,
        (int index) {
          return _TileChoiceChip(
            title: getActivityLevelLabel(ActivityLevel.values[index]),
            subtitle: switch (ActivityLevel.values[index]) {
              ActivityLevel.low => '靜態活動，多半坐著或躺著。',
              ActivityLevel.slightlyLow => '站立活動，多半站著但少移動身體。',
              ActivityLevel.miderate => '站立且移動的活動，如打掃、散步等。',
              ActivityLevel.high => '比一般速度更快的活動，如爬樓梯、快走等。',
            },
            selected: provider.activityLevel == ActivityLevel.values[index],
            onSelected: (bool selected) {
              if (selected) {
                provider.activityLevel = ActivityLevel.values[index];
              }
            },
          );
        },
      ).toList().sublist(start, end);
    });

    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _HeadLine('4.活動生活活動強度如何？'),
        Padding(
          padding: const EdgeInsets.fromLTRB(60, 0, 60, 0),
          child: Wrap(
              spacing: 8.0,
              alignment: WrapAlignment.center,
              children: getActivityChoices),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SubmitButton(
              onPressed: onGoBack,
              label: '返回',
            ),
            _SubmitButton(
              onPressed: onSubmit,
              label: '確認',
            )
          ],
        )
      ],
    );
  }
}

class AgePage extends StatelessWidget {
  final void Function() onGoBack;
  final void Function() onSubmit;

  const AgePage({super.key, required this.onGoBack, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    var dataProvider = context.read<DataProvider>();

    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _HeadLine('3.請問您幾歲？'),
        Padding(
          padding: const EdgeInsets.fromLTRB(60, 0, 60, 0),
          child: Wrap(
            spacing: 8.0,
            alignment: WrapAlignment.center,
            children: List<Widget>.generate(
              Age.values.length,
              (int index) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
                  child: _ChoiceChip(
                    label: getAgeLabel(Age.values[index]),
                    selected: context.select<DataProvider, Age>(
                            (provider) => provider.age) ==
                        Age.values[index],
                    onSelected: (bool selected) {
                      if (selected) {
                        dataProvider.age = Age.values[index];
                      }
                    },
                  ),
                );
              },
            ).toList(),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SubmitButton(
              onPressed: onGoBack,
              label: '返回',
            ),
            _SubmitButton(
              onPressed: () {
                dataProvider.activityLevel = ActivityLevel.miderate;
                onSubmit();
              },
              label: '確認',
            )
          ],
        )
      ],
    );
  }
}

class SexPage extends StatelessWidget {
  final void Function() onGoBack;
  final void Function() onSubmit;

  const SexPage({super.key, required this.onGoBack, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _HeadLine('2.選擇您的性別：'),
        Wrap(
          spacing: 16.0,
          children: List<Widget>.generate(
            Sex.values.length,
            (int index) {
              return _ChoiceChip(
                label: getSexLabel(Sex.values[index]),
                icon: switch (Sex.values[index]) {
                  Sex.female => Icons.female,
                  Sex.male => Icons.male
                },
                selected: context.select<DataProvider, Sex>(
                        (provider) => provider.sex) ==
                    Sex.values[index],
                onSelected: (bool selected) {
                  if (selected) {
                    context.read<DataProvider>().sex = Sex.values[index];
                  }
                },
              );
            },
          ).toList(),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SubmitButton(
              onPressed: onGoBack,
              label: '返回',
            ),
            _SubmitButton(
              onPressed: onSubmit,
              label: '確認',
            )
          ],
        )
      ],
    );
  }
}

class MealPage extends StatelessWidget {
  final void Function() onGoBack;
  final void Function() onSubmit;

  const MealPage({super.key, required this.onGoBack, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _HeadLine('1.這是哪一餐？'),
        Wrap(
          spacing: 16.0,
          children: List<Widget>.generate(
            Meal.values.length,
            (int index) {
              return _ChoiceChip(
                label: getMealLabel(Meal.values[index]),
                icon: switch (Meal.values[index]) {
                  Meal.breakfast => Icons.breakfast_dining,
                  Meal.lunch => Icons.lunch_dining,
                  Meal.dinnder => Icons.dinner_dining,
                },
                selected: context.select<DataProvider, Meal>(
                        (provider) => provider.meal) ==
                    Meal.values[index],
                onSelected: (bool selected) {
                  if (selected) {
                    context.read<DataProvider>().meal = Meal.values[index];
                  }
                },
              );
            },
          ).toList(),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _SubmitButton(
              onPressed: onGoBack,
              label: '返回',
            ),
            _SubmitButton(
              onPressed: onSubmit,
              label: '確認',
            )
          ],
        )
      ],
    );
  }
}

class HomePage extends StatefulWidget {
  final void Function() onSubmit;

  const HomePage({super.key, required this.onSubmit});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool isStart = false;
  @override
  Widget build(BuildContext context) {
    final isScanning = context.select<RFIDReaderProvider, bool>(
      (provider) => provider.isScanning || provider.isCalibrating,
    );

    return Column(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(80, 0, 80, 0),
          child: Image(image: AssetImage('assets/images/title.png')),
        ),
        isStart
            ? const SizedBox(width: 880, child: LinearProgressIndicator())
            : const SizedBox(
                height: 4,
              ),
        _SubmitButton(
          onPressed: (isStart || isScanning)
              ? null
              : () async {
                  setState(() {
                    isStart = true;
                  });

                  // Check printer availability FIRST
                  final dataProvider = context.read<DataProvider>();
                  final printerName = dataProvider.printerName;

                  debugPrint(
                      '🔍 Checking printer "$printerName" on startup...');
                  final isPrinterAvailable =
                      await PrinterService.isPrinterAvailable(printerName);

                  if (!isPrinterAvailable) {
                    // Show printer not found dialog
                    // ignore: use_build_context_synchronously
                    await showPrinterNotFoundDialog(context, printerName);
                    // User canceled or went to settings, stay on home page
                    setState(() {
                      isStart = false;
                    });
                    return;
                  }

                  // Printer found: start background polling and wait for the
                  // first round (bounded) instead of a fixed 3 seconds
                  // ignore: use_build_context_synchronously
                  final provider = context.read<RFIDReaderProvider>();
                  provider.startPolling();
                  await provider.waitForFirstRound();
                  if (!mounted) return;
                  widget.onSubmit();
                },
          label: '開始',
        )
      ],
    );
  }
}

class _SubmitButton extends StatelessWidget {
  final void Function()? onPressed;
  final String label;

  const _SubmitButton({required this.onPressed, required this.label});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
        onPressed: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
          child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                      fontSize:
                          Theme.of(context).textTheme.displaySmall?.fontSize),
                ),
                // Icon(Icons.send, size: Theme.of(context).textTheme.displaySmall?.fontSize,),
              ]),
        ));
  }
}

class _TileChoiceChip extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final void Function(bool)? onSelected;

  const _TileChoiceChip(
      {required this.title,
      required this.subtitle,
      required this.selected,
      required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      child: ChoiceChip(
        label: SizedBox(
          width: 320,
          height: 64,
          child: Center(
            child: ListTile(
              leading: Text(
                title,
                style: TextStyle(
                    fontSize:
                        Theme.of(context).textTheme.headlineLarge!.fontSize),
              ),
              title: Text(subtitle),
            ),
          ),
        ),
        selected: selected,
        onSelected: onSelected,
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  final IconData? icon;
  final String label;
  final bool selected;
  final void Function(bool) onSelected;

  const _ChoiceChip(
      {this.icon,
      required this.label,
      required this.selected,
      required this.onSelected});

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: Theme.of(context).textTheme.displayMedium!.fontSize,
            ),
            const SizedBox(
              width: 8,
            ),
            Text(label,
                style: TextStyle(
                    fontSize:
                        Theme.of(context).textTheme.displayMedium!.fontSize)),
          ]),
      selected: selected,
      onSelected: onSelected,
    );
  }
}

class _HeadLine extends StatelessWidget {
  final String text;

  const _HeadLine(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
          fontSize: Theme.of(context).textTheme.displayMedium!.fontSize),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;

  const _InfoCard(
      {required this.title, required this.subtitle, required this.icon});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Card(
        child: ListTile(
          leading: Icon(
            icon,
            color: Theme.of(context).colorScheme.primary,
            size: Theme.of(context).textTheme.displayLarge!.fontSize,
          ),
          title: Text(
            title,
            style: TextStyle(
                fontSize: Theme.of(context).textTheme.headlineLarge!.fontSize),
          ),
          subtitle: Text(
            subtitle,
            style: TextStyle(
                fontSize: Theme.of(context).textTheme.bodyLarge!.fontSize),
          ),
        ),
      ),
    );
  }
}
