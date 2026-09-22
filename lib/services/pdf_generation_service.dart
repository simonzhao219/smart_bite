import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:screenshot/screenshot.dart';
import 'package:smart_bite/data/constant.dart';
import 'package:smart_bite/data/lazy_label_data.dart';
import 'package:smart_bite/services/nutrition_analysis_service.dart';
import 'package:smart_bite/widgets/printing_text_widgets.dart';

/// Service responsible for generating PDF documents.
/// Separated from UI/state management for better testability and maintainability.
class PDFGenerationService {
  /// Generates a combined PDF with both nutrition report and label pages.
  ///
  /// Creates a single PDF document with 2 pages:
  /// - Page 1: Nutrition analysis report
  /// - Page 2: Food label information
  ///
  /// If either page fails to generate, it will be skipped and only
  /// successfully generated pages will be included in the final PDF.
  ///
  /// Throws [PDFGenerationException] if both pages fail to generate.
  static Future<Uint8List> generateCombinedPdf({
    required PdfPageFormat format,
    required NutritionAnalysisResult analysisResult,
    required List<String> orderNames,
    required Meal meal,
    required Sex sex,
    required Age age,
    required ActivityLevel activityLevel,
  }) async {
    try {
      // Load Chinese font once for both pages
      final fontData =
          await rootBundle.load('assets/fonts/NotoSansCJK-Regular.otf');
      final ttf = pw.Font.ttf(fontData);

      final pdf = pw.Document();
      int successfulPages = 0;

      // Generate Page 1: Nutrition Report
      try {
        final reportImage = await _generateReportPage(
          analysisResult: analysisResult,
          orderNames: orderNames,
          meal: meal,
          sex: sex,
          age: age,
          activityLevel: activityLevel,
        );

        pdf.addPage(
          pw.Page(
            orientation: pw.PageOrientation.landscape,
            pageFormat: format.copyWith(
              marginBottom: 0.3 * PdfPageFormat.cm,
              marginLeft: 0.3 * PdfPageFormat.cm,
              marginRight: 0.3 * PdfPageFormat.cm,
              marginTop: 0.3 * PdfPageFormat.cm,
            ),
            theme: pw.ThemeData.withFont(base: ttf),
            build: (context) {
              return pw.Center(
                child: pw.Image(
                  pw.MemoryImage(reportImage),
                  fit: pw.BoxFit.contain,
                ),
              );
            },
          ),
        );
        successfulPages++;
      } catch (e) {
        debugPrint('Failed to generate report page, skipping: $e');
      }

      // Generate Page 2: Label Information
      try {
        final labelImage = await _generateLabelPage(
          labelInfo: analysisResult.labelInfo,
        );

        pdf.addPage(
          pw.Page(
            orientation: pw.PageOrientation.landscape,
            pageFormat: format.copyWith(
              marginBottom: 0.3 * PdfPageFormat.cm,
              marginLeft: 0.3 * PdfPageFormat.cm,
              marginRight: 0.3 * PdfPageFormat.cm,
              marginTop: 0.3 * PdfPageFormat.cm,
            ),
            theme: pw.ThemeData.withFont(base: ttf),
            build: (context) {
              return pw.Center(
                child: pw.Image(
                  pw.MemoryImage(labelImage),
                  fit: pw.BoxFit.contain,
                ),
              );
            },
          ),
        );
        successfulPages++;
      } catch (e) {
        debugPrint('Failed to generate label page, skipping: $e');
      }

      if (successfulPages == 0) {
        throw PDFGenerationException(
            'Failed to generate any pages for combined PDF');
      }

      return await pdf.save();
    } catch (e) {
      throw PDFGenerationException(
          'Failed to generate combined PDF: ${e.toString()}');
    }
  }

  /// Generates a nutrition report PDF (single page).
  ///
  /// Throws [PDFGenerationException] if PDF generation fails.
  static Future<Uint8List> generateReportPdf({
    required PdfPageFormat format,
    required NutritionAnalysisResult analysisResult,
    required List<String> orderNames,
    required Meal meal,
    required Sex sex,
    required Age age,
    required ActivityLevel activityLevel,
  }) async {
    try {
      // Load Chinese font
      final fontData =
          await rootBundle.load('assets/fonts/NotoSansCJK-Regular.otf');
      final ttf = pw.Font.ttf(fontData);

      final capturedImage = await _generateReportPage(
        analysisResult: analysisResult,
        orderNames: orderNames,
        meal: meal,
        sex: sex,
        age: age,
        activityLevel: activityLevel,
      );

      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          orientation: pw.PageOrientation.landscape,
          pageFormat: format.copyWith(
              marginBottom: 0.3 * PdfPageFormat.cm,
              marginLeft: 0.3 * PdfPageFormat.cm,
              marginRight: 0.3 * PdfPageFormat.cm,
              marginTop: 0.3 * PdfPageFormat.cm),
          theme: pw.ThemeData.withFont(base: ttf),
          build: (context) {
            return pw.Center(
              child: pw.Image(
                pw.MemoryImage(capturedImage),
                fit: pw.BoxFit.contain,
              ),
            );
          },
        ),
      );
      return await pdf.save();
    } catch (e) {
      throw PDFGenerationException(
          'Failed to generate report PDF: ${e.toString()}');
    }
  }

  /// Internal method to generate the nutrition report page as an image.
  ///
  /// Returns the captured image as [Uint8List].
  static Future<Uint8List> _generateReportPage({
    required NutritionAnalysisResult analysisResult,
    required List<String> orderNames,
    required Meal meal,
    required Sex sex,
    required Age age,
    required ActivityLevel activityLevel,
  }) async {
    const frameOpacity = 0.0;

    Widget myContainer = Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/printing_layout_1.png"),
          fit: BoxFit.contain,
        ),
      ),
      child: Column(
        children: [
          SizedBox(
              height: 100,
              child: Container(
                  color: Colors.blue.withValues(alpha: frameOpacity))),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                  width: 480,
                  height: 64,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Basic Info
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                      height: 80,
                      child: Center(
                          child: NormalRedPrintingText(getSexLabel(sex)))),
                  SizedBox(
                      height: 18,
                      width: 200,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      height: 80,
                      child: Center(
                          child:
                              NormalRedPrintingText('${getAgeLabel(age)}歲'))),
                  SizedBox(
                      height: 18,
                      width: 200,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      height: 80,
                      child: Center(
                          child: NormalRedPrintingText(
                              getActivityLevelLabel(activityLevel)))),
                  SizedBox(
                      height: 18,
                      width: 200,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      height: 80,
                      child: Center(
                          child: NormalRedPrintingText(getMealLabel(meal)))),
                ],
              ),
              SizedBox(
                  width: 120,
                  height: 100,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Ordered Dishes
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 1160,
                      height: 56,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 1160,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: Center(
                              child: NormalRedPrintingText(
                                  orderNames.isEmpty ? '未點餐' : orderNames.join('、'))))),
                ],
              ),
              SizedBox(
                  width: 160,
                  height: 100,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Overall Comment
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 1160,
                      height: 56,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 1160,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              analysisResult.overallComment))),
                ],
              ),
            ],
          ),
          SizedBox(
              height: 18,
              child: Container(
                  color: Colors.blue.withValues(alpha: frameOpacity))),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                  width: 720,
                  height: 50,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Needed Calorie Per Day
              SizedBox(
                  width: 360,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity),
                      child: HighlightPrintingText(analysisResult
                          .neededCaloriePerDay
                          .toStringAsFixed(0)))),
              SizedBox(
                  width: 560,
                  height: 50,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Needed Calorie Range for This Meal
              SizedBox(
                  width: 810,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity),
                      child: HighlightPrintingText(
                          '${(analysisResult.neededCalorieThisMeal / 100).floor() * 100}-${(analysisResult.neededCalorieThisMeal / 100).ceil() * 100}'))),
            ],
          ),
          SizedBox(
              height: 118,
              child: Container(
                  color: Colors.blue.withValues(alpha: frameOpacity))),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                  width: 456,
                  height: 32,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Intake Food Type Amount
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      height: 0,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 100,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .intakeFoodType[NutritionType.grains]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 100,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .intakeFoodType[NutritionType.meat]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 100,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .intakeFoodType[NutritionType.vegetables]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 100,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .intakeFoodType[NutritionType.fruits]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 100,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .intakeFoodType[NutritionType.oils]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 100,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .intakeFoodType[NutritionType.dairy]!
                              .toStringAsFixed(1)))),
                ],
              ),
              SizedBox(
                  width: 263,
                  height: 5,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Intake Food Type Daily Proportion Bars
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                      height: 14,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  PrintingBar(
                      (analysisResult.intakeFoodTypeDailyProportion[
                                      NutritionType.grains]! >
                                  100
                              ? 100
                              : analysisResult.intakeFoodTypeDailyProportion[
                                  NutritionType.grains]!)
                          .round(),
                      color: const Color.fromARGB(190, 247, 172, 0)),
                  SizedBox(
                      height: 66,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  PrintingBar(
                      (analysisResult.intakeFoodTypeDailyProportion[
                                      NutritionType.meat]! >
                                  100
                              ? 100
                              : analysisResult.intakeFoodTypeDailyProportion[
                                  NutritionType.meat]!)
                          .round(),
                      color: const Color.fromARGB(190, 236, 67, 115)),
                  SizedBox(
                      height: 66,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  PrintingBar(
                      (analysisResult.intakeFoodTypeDailyProportion[
                                      NutritionType.vegetables]! >
                                  100
                              ? 100
                              : analysisResult.intakeFoodTypeDailyProportion[
                                  NutritionType.vegetables]!)
                          .round(),
                      color: const Color.fromARGB(190, 126, 187, 0)),
                  SizedBox(
                      height: 66,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  PrintingBar(
                      (analysisResult.intakeFoodTypeDailyProportion[
                                      NutritionType.fruits]! >
                                  100
                              ? 100
                              : analysisResult.intakeFoodTypeDailyProportion[
                                  NutritionType.fruits]!)
                          .round(),
                      color: const Color.fromARGB(190, 236, 94, 0)),
                  SizedBox(
                      height: 66,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  PrintingBar(
                      (analysisResult.intakeFoodTypeDailyProportion[
                                      NutritionType.oils]! >
                                  100
                              ? 100
                              : analysisResult.intakeFoodTypeDailyProportion[
                                  NutritionType.oils]!)
                          .round(),
                      color: const Color.fromARGB(190, 220, 178, 86)),
                  SizedBox(
                      height: 66,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  PrintingBar(
                      (analysisResult.intakeFoodTypeDailyProportion[
                                      NutritionType.dairy]! >
                                  100
                              ? 100
                              : analysisResult.intakeFoodTypeDailyProportion[
                                  NutritionType.dairy]!)
                          .round(),
                      color: const Color.fromARGB(190, 130, 206, 236)),
                ],
              ),
              // Intake Food Type Daily Proportion Percentage
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      height: 0,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 180,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              '${analysisResult.intakeFoodTypeDailyProportion[NutritionType.grains]!.round()}%'))),
                  SizedBox(
                      width: 180,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              '${analysisResult.intakeFoodTypeDailyProportion[NutritionType.meat]!.round()}%'))),
                  SizedBox(
                      width: 180,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              '${analysisResult.intakeFoodTypeDailyProportion[NutritionType.vegetables]!.round()}%'))),
                  SizedBox(
                      width: 180,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              '${analysisResult.intakeFoodTypeDailyProportion[NutritionType.fruits]!.round()}%'))),
                  SizedBox(
                      width: 180,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              '${analysisResult.intakeFoodTypeDailyProportion[NutritionType.oils]!.round()}%'))),
                  SizedBox(
                      width: 180,
                      height: 132,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(
                              '${analysisResult.intakeFoodTypeDailyProportion[NutritionType.dairy]!.round()}%'))),
                ],
              ),
              SizedBox(
                  width: 550,
                  height: 5,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              // Intake Total Nutrition Without Food Type
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.calorie]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.carb]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.protein]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.fat]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.na]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.ca]!
                              .toStringAsFixed(1)))),
                  SizedBox(
                      width: 300,
                      height: 105,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: NormalRedPrintingText(analysisResult
                              .intakeTotalNutritionWithoutFoodType[
                                  NutritionType.fiber]!
                              .toStringAsFixed(1)))),
                ],
              ),
            ],
          ),
          SizedBox(
              height: 199,
              child: Container(
                  color: Colors.blue.withValues(alpha: frameOpacity))),
          // Ranks by Food Type and Comments
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                  width: 592,
                  height: 50,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 64,
                      height: 4,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 64,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: MidPrintingText(analysisResult
                              .ranksByFoodType[NutritionType.grains]!))),
                  SizedBox(
                      width: 64,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 64,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: MidPrintingText(analysisResult
                              .ranksByFoodType[NutritionType.meat]!))),
                  SizedBox(
                      width: 64,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 64,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: MidPrintingText(analysisResult
                              .ranksByFoodType[NutritionType.vegetables]!))),
                ],
              ),
              SizedBox(
                  width: 56,
                  height: 50,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 1000,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .commentsByFoodType[NutritionType.grains]!))),
                  SizedBox(
                      width: 50,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 1000,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .commentsByFoodType[NutritionType.meat]!))),
                  SizedBox(
                      width: 50,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 1000,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .commentsByFoodType[NutritionType.vegetables]!))),
                ],
              ),
              SizedBox(
                  width: 472,
                  height: 50,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 64,
                      height: 4,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 64,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: MidPrintingText(analysisResult
                              .ranksByFoodType[NutritionType.fruits]!))),
                  SizedBox(
                      width: 64,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 64,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: MidPrintingText(analysisResult
                              .ranksByFoodType[NutritionType.oils]!))),
                  SizedBox(
                      width: 64,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 64,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: MidPrintingText(analysisResult
                              .ranksByFoodType[NutritionType.dairy]!))),
                ],
              ),
              SizedBox(
                  width: 60,
                  height: 50,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                      width: 1000,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .commentsByFoodType[NutritionType.fruits]!))),
                  SizedBox(
                      width: 50,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 1000,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .commentsByFoodType[NutritionType.oils]!))),
                  SizedBox(
                      width: 50,
                      height: 36,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                  SizedBox(
                      width: 1000,
                      height: 180,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity),
                          child: SmallPrintingText(analysisResult
                              .commentsByFoodType[NutritionType.dairy]!))),
                ],
              ),
            ],
          ),
        ],
      ),
    );

    ScreenshotController screenshotController = ScreenshotController();
    return await screenshotController.captureFromWidget(myContainer,
        pixelRatio: 1,
        targetSize: const Size(3508, 2480),
        delay: const Duration(milliseconds: 500));
  }

  /// Generates a food label PDF (single page).
  ///
  /// Throws [PDFGenerationException] if PDF generation fails.
  static Future<Uint8List> generateLabelPdf({
    required PdfPageFormat format,
    required LabelInformation labelInfo,
  }) async {
    try {
      // Load Chinese font
      final fontData =
          await rootBundle.load('assets/fonts/NotoSansCJK-Regular.otf');
      final ttf = pw.Font.ttf(fontData);

      final capturedImage = await _generateLabelPage(labelInfo: labelInfo);

      final pdf = pw.Document();
      pdf.addPage(
        pw.Page(
          orientation: pw.PageOrientation.landscape,
          pageFormat: format.copyWith(
              marginBottom: 0.3 * PdfPageFormat.cm,
              marginLeft: 0.3 * PdfPageFormat.cm,
              marginRight: 0.3 * PdfPageFormat.cm,
              marginTop: 0.3 * PdfPageFormat.cm),
          theme: pw.ThemeData.withFont(base: ttf),
          build: (context) {
            return pw.Center(
              child: pw.Image(
                pw.MemoryImage(capturedImage),
                fit: pw.BoxFit.contain,
              ),
            );
          },
        ),
      );
      return await pdf.save();
    } catch (e) {
      throw PDFGenerationException(
          'Failed to generate label PDF: ${e.toString()}');
    }
  }

  /// Internal method to generate the label page as an image.
  ///
  /// Returns the captured image as [Uint8List].
  static Future<Uint8List> _generateLabelPage({
    required LabelInformation labelInfo,
  }) async {
    const frameOpacity = 0.0;

    Widget myContainer = Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/printing_layout_2.png"),
          fit: BoxFit.contain,
        ),
      ),
      child: Column(
        children: [
          // Title height
          SizedBox(
              height: 640,
              child: Container(
                  color: Colors.blue.withValues(alpha: frameOpacity))),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              // Product Resume
              SizedBox(
                  width: 1000,
                  height: 5,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                      height: 825,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Builder(builder: (context) {
                          // Cache lookup result to eliminate redundant map accesses
                          final productResumeData = LazyLabelData.getInfo(
                            labelInfo.productResumeLabelFood);
                          final baseText = '追溯編號：${productResumeData?["trace_code"] ?? ""}\n產品名稱：${labelInfo.productResumeLabelFood}\n農產品經營者：${productResumeData?["operator"] ?? ""}\n包裝日期：${productResumeData?["packaging_date"] ?? ""}\n電話：${productResumeData?["phone"] ?? ""}\n地址：${productResumeData?["address"] ?? ""}';
                          final displayText = labelInfo.productResumeLabelDishes.isEmpty 
                            ? baseText 
                            : '料理： ${labelInfo.productResumeLabelDishes}\n$baseText';
                          return NormalBlackPrintingText(displayText);
                          }))),
                  SizedBox(
                      height: 5,
                      width: 740,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                ],
              ),
              // CAS Label
              SizedBox(
                  width: 600,
                  height: 5,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                      height: 825,
                      child: Align(
                          alignment: Alignment.topLeft,
                          child: Builder(builder: (context) {
                            // Cache lookup result to eliminate redundant map accesses
                            final casData =
                                LazyLabelData.getInfo(labelInfo.casLabelFood);
                            final baseText = '標章編號：${casData?["certification_id"] ?? ""}\n產品種類：${casData?["product_type"] ?? ""}\n產品名稱：${labelInfo.casLabelFood}\n產品類別：${casData?["category"] ?? ""}\n廠商名稱：${casData?["manufacturer"] ?? ""}\n地址：${casData?["address"] ?? ""}\n電話：${casData?["phone"] ?? ""}\n負責人：${casData?["representative"] ?? ""}\n驗證機構：${casData?["certification_body"] ?? ""}';
                            final displayText = labelInfo.casLabelDishes.isEmpty 
                              ? baseText 
                              : '料理：${labelInfo.casLabelDishes}\n$baseText';
                            return NormalBlackPrintingText(displayText);
                          }))),
                  // space between label group 2
                  SizedBox(
                      height: 5,
                      width: 1155,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                ],
              ),
              SizedBox(
                  width: 5,
                  height: 830,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
            ],
          ),
          // Organic Label
          SizedBox(
              height: 80,
              child: Container(
                  color: Colors.blue.withValues(alpha: frameOpacity))),
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              SizedBox(
                  width: 650,
                  height: 5,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                      height: 800,
                      child: Center(child: Builder(builder: (context) {
                        // Cache lookup result to eliminate redundant map accesses
                        final organicData =
                            LazyLabelData.getInfo(labelInfo.organicLabelFood);
                        final baseText = '品項：${labelInfo.organicLabelFood}\n產品範圍：${organicData?["category"] ?? ""}\n農產品經營者：${organicData?["operator"] ?? ""}\n驗證機構名稱：${organicData?["certification_body"] ?? ""}\n證書字號(有機)：${organicData?["certificate_number"] ?? ""}\n驗證效期：${organicData?["expiration_date"] ?? ""}\n電話：${organicData?["phone"] ?? ""}\n驗證場所地址(有機)：${organicData?["address"] ?? ""}';
                        final displayText = labelInfo.organicLabelDishes.isEmpty 
                          ? baseText 
                          : '料理：${labelInfo.organicLabelDishes}\n$baseText';
                        return NormalBlackPrintingText(displayText);
                      }))),
                  SizedBox(
                      height: 30,
                      width: 1100,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                ],
              ),
              // Traceable Label
              SizedBox(
                  width: 550,
                  height: 5,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
              Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  SizedBox(
                      height: 800,
                      child: Center(child: Builder(builder: (context) {
                        // Cache lookup result to eliminate redundant map accesses
                        final traceableData =
                            LazyLabelData.getInfo(labelInfo.traceableLabelFood);
                        final baseText = '追溯編號：${traceableData?["trace_code"] ?? ""}\n品名：${labelInfo.traceableLabelFood}\n生產者：${traceableData?["operator"] ?? ""}\n電話：${traceableData?["phone"] ?? ""}\n地址：${traceableData?["address"] ?? ""}\n簡介：${traceableData?["description"] ?? ""}';
                        final displayText = labelInfo.traceableLabelDishes.isEmpty 
                          ? baseText 
                          : '料理：${labelInfo.traceableLabelDishes}\n$baseText';
                        return NormalBlackPrintingText(displayText);
                      }))),
                  SizedBox(
                      height: 30,
                      width: 1200,
                      child: Container(
                          color: Colors.blue.withValues(alpha: frameOpacity))),
                ],
              ),
              SizedBox(
                  width: 5,
                  height: 830,
                  child: Container(
                      color: Colors.blue.withValues(alpha: frameOpacity))),
            ],
          ),
        ],
      ),
    );

    final screenshotController = ScreenshotController();
    // Note: ScreenshotController doesn't require explicit disposal
    // It only manages a GlobalKey which is garbage collected automatically
    // The ui.Image objects are disposed within captureFromWidget()
    return await screenshotController.captureFromWidget(myContainer,
        pixelRatio: 1,
        targetSize: const Size(3508, 2480),
        delay: const Duration(milliseconds: 500));
  }

  /// Generates a test PDF with background images only.
  ///
  /// This method creates a minimal PDF with just the background images
  /// for testing printer configuration. No actual data is included.
  ///
  /// Parameters:
  /// - [format]: The page format for the PDF
  /// - [includeLabelPage]: If true, includes both report and label backgrounds.
  ///                       If false, includes only the report background.
  ///
  /// Throws [PDFGenerationException] if PDF generation fails.
  static Future<Uint8List> generateTestPdf({
    required PdfPageFormat format,
    required bool includeLabelPage,
  }) async {
    try {
      // Load Chinese font
      final fontData =
          await rootBundle.load('assets/fonts/NotoSansCJK-Regular.otf');
      final ttf = pw.Font.ttf(fontData);

      final pdf = pw.Document();

      // Always add report background page
      final reportImage = await _generateTestReportPage();
      pdf.addPage(
        pw.Page(
          orientation: pw.PageOrientation.landscape,
          pageFormat: format.copyWith(
              marginBottom: 0.3 * PdfPageFormat.cm,
              marginLeft: 0.3 * PdfPageFormat.cm,
              marginRight: 0.3 * PdfPageFormat.cm,
              marginTop: 0.3 * PdfPageFormat.cm),
          theme: pw.ThemeData.withFont(base: ttf),
          build: (context) {
            return pw.Center(
              child: pw.Image(
                pw.MemoryImage(reportImage),
                fit: pw.BoxFit.contain,
              ),
            );
          },
        ),
      );

      // Conditionally add label background page
      if (includeLabelPage) {
        final labelImage = await _generateTestLabelPage();
        pdf.addPage(
          pw.Page(
            orientation: pw.PageOrientation.landscape,
            pageFormat: format.copyWith(
                marginBottom: 0.3 * PdfPageFormat.cm,
                marginLeft: 0.3 * PdfPageFormat.cm,
                marginRight: 0.3 * PdfPageFormat.cm,
                marginTop: 0.3 * PdfPageFormat.cm),
            theme: pw.ThemeData.withFont(base: ttf),
            build: (context) {
              return pw.Center(
                child: pw.Image(
                  pw.MemoryImage(labelImage),
                  fit: pw.BoxFit.contain,
                ),
              );
            },
          ),
        );
      }

      return await pdf.save();
    } catch (e) {
      throw PDFGenerationException(
          'Failed to generate test PDF: ${e.toString()}');
    }
  }

  /// Internal method to generate a test report page with background only.
  ///
  /// Returns the captured image as [Uint8List].
  static Future<Uint8List> _generateTestReportPage() async {
    // Create a simple container with just the report background image
    Widget myContainer = Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/printing_layout_1.png"),
          fit: BoxFit.contain,
        ),
      ),
    );

    final screenshotController = ScreenshotController();
    return await screenshotController.captureFromWidget(myContainer,
        pixelRatio: 1,
        targetSize: const Size(3508, 2480),
        delay: const Duration(milliseconds: 500));
  }

  /// Internal method to generate a test label page with background only.
  ///
  /// Returns the captured image as [Uint8List].
  static Future<Uint8List> _generateTestLabelPage() async {
    // Create a simple container with just the label background image
    Widget myContainer = Container(
      decoration: const BoxDecoration(
        image: DecorationImage(
          image: AssetImage("assets/images/printing_layout_2.png"),
          fit: BoxFit.contain,
        ),
      ),
    );

    final screenshotController = ScreenshotController();
    return await screenshotController.captureFromWidget(myContainer,
        pixelRatio: 1,
        targetSize: const Size(3508, 2480),
        delay: const Duration(milliseconds: 500));
  }
}
/// Exception thrown when PDF generation fails.
class PDFGenerationException implements Exception {
  final String message;

  PDFGenerationException(this.message);

  @override
  String toString() => 'PDFGenerationException: $message';
}
