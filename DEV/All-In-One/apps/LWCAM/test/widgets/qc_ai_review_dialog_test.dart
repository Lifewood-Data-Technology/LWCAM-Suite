import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/controllers/qc_ai_review_controller.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_ai_review.dart';
import 'package:lwcam/models/qc_task.dart';
import 'package:lwcam/widgets/qc_ai_review_dialog.dart';

/// The findings window.
///
/// A finished review used to repaint a panel that is collapsed by default, so a
/// folder could carry six findings at 0.9 confidence and the reviewer never see
/// one. This is the window that puts them in front of them, and it renders the
/// panel's own widgets so the two can never disagree about what is appliable.
QcAiReviewJob jobWith(
  List<QcAiReviewField> fields, {
  String status = 'succeeded',
  bool stale = false,
  String jobId = 'j1',
}) =>
    QcAiReviewJob(
      jobId: jobId,
      folderId: 7,
      inputHash: 'a' * 64,
      status: status,
      stage: 'comparing',
      trigger: 'manual',
      stale: stale,
      error: null,
      cancelReason: null,
      processedImages: 8,
      totalImages: 8,
      result: QcAiReviewResult(
        overallStatus: 'needs_review',
        fieldReviews: fields,
        acceptedFields: const [],
      ),
    );

QcAiReviewField field({
  String key = 'title',
  String verdict = 'mismatch',
  double confidence = 0.9,
  String? suggested = 'WWII Medical Files',
  List<QcAiReviewEvidence> evidence = const [],
}) =>
    QcAiReviewField(
      key: key,
      currentValue: 'WWI Medical Files',
      suggestedValue: suggested,
      verdict: verdict,
      confidence: confidence,
      evidence: evidence,
    );

Map<String, Object?> taskJson() => {
      'id': 7,
      'status': 'pending',
      'sourceHash': 'a' * 64,
      'assignedTo': 3,
      'metadata': <String, Object?>{'folderId': 7},
      'metadataTemplate': {'fields': <Object?>[]},
      'images': [
        for (var i = 0; i < 3; i++)
          {
            'id': 100 + i,
            'filename': 'PAGE_${i + 1}.jpg',
            'available': true,
            'previewUrl': '/p/${100 + i}',
            'draftState': null,
            'separationStart': false,
          },
      ],
    };

Future<QcAiReviewController> pumpDialog(
  WidgetTester tester,
  QcAiReviewJob job,
) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final review = QcReviewController(7);
  review.task.value = QcTask.fromJson(taskJson());
  final ai = QcAiReviewController(review, autoRunEnabled: false);
  ai.job.value = job;

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => QcAiReviewDialog.show(context, ai),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return ai;
}

void main() {
  tearDown(Get.reset);

  testWidgets('it lists a card per finding', (tester) async {
    await pumpDialog(tester, jobWith([field(key: 'title'), field(key: 'volume')]));

    expect(find.text('title'), findsOneWidget);
    expect(find.text('volume'), findsOneWidget);
    expect(find.text('8 / 8 pages'), findsOneWidget);
  });

  testWidgets('Apply waits for a selection', (tester) async {
    final ai = await pumpDialog(tester, jobWith([field()]));
    final apply = find.widgetWithText(FilledButton, 'Apply');
    expect(tester.widget<FilledButton>(apply).onPressed, isNull,
        reason: 'nothing is ticked yet');

    ai.toggle('title', true);
    await tester.pump();

    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
  });

  testWidgets('a stale review offers no Apply, but says why and offers a re-run',
      (tester) async {
    // The metadata moved on since the review looked at it, so applying would
    // write findings computed against something else. Every checkbox and the
    // apply bar disappear - which read as a broken window until it explained
    // itself and offered the way out.
    await pumpDialog(tester, jobWith([field()], stale: true));

    expect(find.widgetWithText(FilledButton, 'Apply'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('metadata changed after this review ran'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Run again'), findsOneWidget);
  });

  testWidgets('a current review shows neither the warning nor Run again',
      (tester) async {
    await pumpDialog(tester, jobWith([field()]));

    expect(find.textContaining('metadata changed after this review ran'),
        findsNothing);
    expect(find.widgetWithText(FilledButton, 'Run again'), findsNothing);
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('tapping evidence closes the window and opens that page',
      (tester) async {
    final ai = await pumpDialog(
      tester,
      jobWith([
        field(evidence: const [
          QcAiReviewEvidence(
            imageId: 102,
            filename: 'PAGE_3.jpg',
            observation: 'header reads 1940',
          ),
        ]),
      ]),
    );
    expect(ai.review.index.value, 0);

    await tester.tap(find.textContaining('header reads 1940'));
    await tester.pumpAndSettle();

    expect(find.text('AI review'), findsNothing,
        reason: 'looking at the page means getting out of its way');
    expect(ai.review.index.value, 2, reason: 'PAGE_3.jpg is the third page');
  });

  testWidgets('evidence for a page that has since been deleted does nothing',
      (tester) async {
    final ai = await pumpDialog(
      tester,
      jobWith([
        field(evidence: const [
          QcAiReviewEvidence(
            imageId: 999,
            filename: 'GONE.jpg',
            observation: 'from a deleted page',
          ),
        ]),
      ]),
    );

    await tester.tap(find.textContaining('from a deleted page'));
    await tester.pumpAndSettle();

    expect(ai.review.index.value, 0);
  });

  testWidgets('a review that found nothing says so', (tester) async {
    await pumpDialog(tester, jobWith(const []));

    expect(find.text('Nothing to report against the current metadata.'),
        findsOneWidget);
  });

  testWidgets('ticking a finding repaints its checkbox', (tester) async {
    // The failure that made selection look broken: the checkbox and the count
    // read `selected`, which no enclosing Obx watched, so a tap changed the
    // controller and repainted nothing at all.
    await pumpDialog(tester, jobWith([field(key: 'title')]));
    final box = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(box).value, isFalse);

    await tester.tap(box);
    await tester.pump();

    expect(tester.widget<Checkbox>(box).value, isTrue);
    expect(find.text('1 of 1'), findsOneWidget);
  });

  testWidgets('Select all ticks every appliable finding', (tester) async {
    await pumpDialog(
      tester,
      jobWith([
        field(key: 'title'),
        field(key: 'startDate', suggested: '1939'),
        // Advisory: no suggestion, so not appliable and not counted.
        field(key: 'volume', verdict: 'not_visible', confidence: 0, suggested: null),
      ]),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Select all'));
    await tester.pump();

    expect(find.text('2 of 2'), findsOneWidget);
    expect(tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply')).onPressed,
        isNotNull);

    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pump();
    expect(find.text('0 of 2'), findsOneWidget);
  });

  testWidgets('a failed apply keeps the window open and shows why',
      (tester) async {
    // Offline the apply call throws QcApiException(401) before it opens a
    // socket, so this exercises the failure branch without a fake client. The
    // window must survive it: closing would take the message with it.
    await pumpDialog(tester, jobWith([field(key: 'title')]));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget,
        reason: 'the window stays up so the failure can be read');
    expect(find.text('1 of 1'), findsOneWidget,
        reason: 'the selection survives, so Apply can be retried');
  });
}
