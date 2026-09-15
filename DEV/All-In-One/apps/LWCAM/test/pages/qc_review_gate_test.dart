import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/controllers/qc_ai_review_controller.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_ai_review.dart';
import 'package:lwcam/models/qc_task.dart';
import 'package:lwcam/pages/qc_review_page.dart';

/// On a station that reviews every folder automatically, the task stays shut
/// until its findings exist - the operator should meet them before the work, not
/// forty seconds into it. But a review is a call to somebody else's model
/// through somebody else's provider, so there is ALWAYS a way past: three
/// different output-contract failures and two rate limits were seen in one
/// afternoon, and a queue wait of thirteen minutes is in the logs.
Map<String, Object?> taskJson({String? status}) {
  final envelope = jsonDecode(
    File('test/fixtures/qc_task_page.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final data = envelope['data'] as Map<String, Object?>;
  final record = Map<String, Object?>.from(
    (data['records'] as List).cast<Map<String, Object?>>().first,
  );
  record['assignedTo'] = status == null ? 3 : null;
  if (status != null) record['status'] = status;
  final template =
      (record['images'] as List).cast<Map<String, Object?>>().first;
  record['images'] = [
    for (var i = 0; i < 3; i++)
      {...template, 'id': 100 + i, 'filename': 'PAGE_${i + 1}.jpg'},
  ];
  return record;
}

QcAiReviewJob job({
  String status = 'running',
  String jobId = 'j1',
  bool withResult = false,
  String? error,
}) =>
    QcAiReviewJob(
      jobId: jobId,
      folderId: 18,
      inputHash: 'a' * 64,
      status: status,
      stage: 'extracting',
      trigger: 'preanalysis',
      stale: false,
      error: error,
      cancelReason: null,
      processedImages: 3,
      totalImages: 8,
      result: withResult
          ? const QcAiReviewResult(
              overallStatus: 'consistent',
              fieldReviews: [],
              acceptedFields: [],
            )
          : null,
    );

/// Pumps the page with the AI controller pre-registered, so `autoRun` can be
/// injected - it otherwise comes from the station's node config, which a test
/// has no business writing.
Future<({QcReviewController review, QcAiReviewController ai})> pumpGate(
  WidgetTester tester, {
  required bool autoRun,
  String? status,
  QcAiReviewJob? existingJob,
}) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final review = Get.put(QcReviewController(18), tag: '18');
  final ai = Get.put(
    QcAiReviewController(review, autoRunEnabled: autoRun),
    tag: '18',
  );

  await tester.pumpWidget(
    const MaterialApp(home: QcReviewPage(folderId: 18, title: 'Review')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  review.task.value = QcTask.fromJson(taskJson(status: status));
  if (existingJob != null) ai.job.value = existingJob;
  await tester.pump();
  return (review: review, ai: ai);
}

void main() {
  tearDown(Get.reset);

  testWidgets('a claimed task is held back until the review has findings',
      (tester) async {
    await pumpGate(tester, autoRun: true, existingJob: job());

    expect(find.text('Checking this folder…'), findsOneWidget);
    expect(find.text('Page 1 of 3'), findsNothing,
        reason: 'the task itself must not be on screen yet');
  });

  testWidgets('Open task anyway lets the operator work immediately',
      (tester) async {
    await pumpGate(tester, autoRun: true, existingJob: job());

    await tester.tap(find.text('Open task anyway'));
    await tester.pump();

    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.text('Checking this folder…'), findsNothing);
  });

  testWidgets('a failed review offers Retry and a way in', (tester) async {
    await pumpGate(
      tester,
      autoRun: true,
      existingJob: job(status: 'failed', error: 'AI analysis failed.'),
    );

    expect(find.text('AI review failed'), findsOneWidget);
    expect(find.text('AI analysis failed.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);

    await tester.tap(find.text('Open task'));
    await tester.pump();
    expect(find.text('Page 1 of 3'), findsOneWidget,
        reason: 'a folder must never be unworkable because a model misbehaved');
  });

  testWidgets('with auto-run off the task opens straight away', (tester) async {
    await pumpGate(tester, autoRun: false);

    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(find.text('Checking this folder…'), findsNothing);
  });

  testWidgets('an unclaimed folder is never gated', (tester) async {
    // Nothing to review and nothing to apply - and the engine 403s the job
    // lookup for a non-owner anyway.
    await pumpGate(tester, autoRun: true, status: 'pending');

    expect(find.text('Checking this folder…'), findsNothing);
    expect(find.text('Page 1 of 3'), findsOneWidget);
  });

  testWidgets('a completed folder is never gated', (tester) async {
    await pumpGate(tester, autoRun: true, status: 'PASS');

    expect(find.text('Checking this folder…'), findsNothing);
    expect(find.text('Page 1 of 3'), findsOneWidget);
  });

  testWidgets('findings release the gate and open the window once',
      (tester) async {
    final ctx = await pumpGate(tester, autoRun: true, existingJob: job());
    expect(find.text('Checking this folder…'), findsOneWidget);

    ctx.ai.job.value = job(status: 'succeeded', withResult: true);
    // pump, not pumpAndSettle: once the task is revealed its thumbnails spin on
    // previews that never arrive offline, so nothing ever settles. Same reason
    // as the note in qc_review_page_test.dart.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('AI review'), findsWidgets, reason: 'the window is up');
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Page 1 of 3'), findsOneWidget,
        reason: 'closing it reveals the task');

    // The same job arriving again - a poll tick, a rebuild - must not reopen it.
    ctx.ai.job.value = job(status: 'succeeded', withResult: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(TextButton, 'Close'), findsNothing);
  });

  testWidgets('the AppBar button reopens the findings after a close',
      (tester) async {
    // The panel carries the same button, but the panel is collapsed by default,
    // so closing the window by accident used to leave nothing to click.
    final ctx = await pumpGate(tester, autoRun: false);
    // Scoped to the button: the collapsed panel header says "AI review" too.
    expect(find.widgetWithText(FilledButton, 'AI review'), findsNothing,
        reason: 'nothing to reopen before a review exists');

    ctx.ai.job.value = job(status: 'succeeded', withResult: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // This review found nothing, so the button carries no count - but it is
    // still there, because "it ran and was clean" is worth seeing again.
    final button = find.widgetWithText(FilledButton, 'AI review');
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.widgetWithText(TextButton, 'Close'), findsOneWidget,
        reason: 'the window is back');
  });

  testWidgets('the button counts the findings', (tester) async {
    final ctx = await pumpGate(tester, autoRun: false);
    ctx.ai.job.value = QcAiReviewJob(
      jobId: 'j9',
      folderId: 18,
      inputHash: 'a' * 64,
      status: 'succeeded',
      stage: 'comparing',
      trigger: 'manual',
      stale: false,
      error: null,
      cancelReason: null,
      processedImages: 8,
      totalImages: 8,
      result: const QcAiReviewResult(
        overallStatus: 'needs_review',
        fieldReviews: [
          QcAiReviewField(
            key: 'title',
            currentValue: 'a',
            suggestedValue: 'b',
            verdict: 'mismatch',
            confidence: 0.9,
            evidence: [],
          ),
          QcAiReviewField(
            key: 'volume',
            currentValue: 'a',
            suggestedValue: null,
            verdict: 'not_visible',
            confidence: 0.0,
            evidence: [],
          ),
        ],
        acceptedFields: [],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.widgetWithText(FilledButton, 'AI review (2)'), findsOneWidget,
        reason: 'two field reviews, counted on the button');
  });
}
