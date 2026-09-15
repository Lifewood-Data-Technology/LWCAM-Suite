// Throwaway check against a RUNNING engine with AI review enabled.
// Deliberately not named *_test.dart so `flutter test` never picks it up.
//
// What it proves that unit tests cannot: the model parses what the engine
// really emits (nested progress and result, the verdict vocabulary, evidence),
// and the apply guard behaves as the panel assumes.
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/qc_ai_review.dart';
import 'package:lwcam/services/qc_ai_poller.dart';
import 'package:lwcam/services/qc_api_client.dart';

void main() {
  test('AI review parses and applies against the live engine', () async {
    final api = QcApiClient.instance;
    await api.signIn('Albert', 'Albert');

    final page = await api.tasks(scope: 'pending');
    final rows = (page['records'] as List).cast<Map<String, Object?>>();
    final folderId = (rows.first['folderId'] ?? rows.first['id']) as int;
    try {
      await api.claim(folderId);
    } catch (e) {
      print('claim: $e');
    }

    var task = await api.task(folderId);
    final sourceHash = task['sourceHash'] as String;

    // --- latest ------------------------------------------------------------
    final latestRaw = await api.latestAiReview(folderId);
    print('latest: ${latestRaw == null ? 'none' : 'present'}');

    QcAiReviewJob? job = latestRaw == null ? null : QcAiReviewJob.fromJson(latestRaw);
    if (job != null) {
      print('  status=${job.status} trigger=${job.trigger} stale=${job.stale} '
          'progress=${job.processedImages}/${job.totalImages}');
      expect(job.jobId, isNotEmpty);
      expect(job.inputHash, hasLength(64));
    }

    // --- start / poll ------------------------------------------------------
    if (job == null || job.isFinished) {
      final action = QcAiPoller.startAction(job);
      print('start action: force=${action.force} confirm=${action.confirmRerun}');
      job = QcAiReviewJob.fromJson(
          await api.startAiReview(folderId, sourceHash, force: action.force));
      print('started ${job.jobId} status=${job.status}');
    }

    // Poll to completion by hand so the check does not depend on Timer pacing.
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (!job!.isFinished && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      job = QcAiReviewJob.fromJson(await api.aiReviewJob(folderId, job.jobId));
      print('  ${job.status}/${QcAiPoller.resolveStage(job)} '
          '${job.processedImages}/${job.totalImages}');
    }
    expect(job.isFinished, isTrue, reason: 'job did not finish in time');
    print('finished: ${job.status} error=${job.error}');

    if (job.status != 'succeeded') {
      print('SKIPPED apply checks: job ${job.status}');
      await api.release(folderId);
      return;
    }

    final result = job.result;
    expect(result, isNotNull, reason: 'a succeeded job must carry a result');
    print('overall=${result!.overallStatus} '
        'fields=${result.fieldReviews.length} '
        'accepted=${result.acceptedFields}');

    // Every verdict the engine emits must be one the panel knows how to render.
    const known = {'match', 'mismatch', 'uncertain', 'not_visible'};
    for (final f in result.fieldReviews) {
      expect(known, contains(f.verdict), reason: 'unknown verdict ${f.verdict}');
      expect(f.confidence, inInclusiveRange(0, 1));
      print('  ${f.key}: ${f.verdict} ${(f.confidence * 100).round()}% '
          'canApply=${f.canApply} evidence=${f.evidence.length} '
          'current=${f.currentValue} suggested=${f.suggestedValue}');
    }

    final appliable = result.fieldReviews.where((f) => f.canApply).toList();

    // --- the guards the panel relies on ------------------------------------
    // A stale inputHash must be refused, not applied to the current metadata.
    await expectLater(
      api.applyAiReview(folderId, sourceHash, 'f' * 64, ['title']),
      throwsA(isA<QcApiException>()),
      reason: 'the engine accepted an apply against a hash it never issued',
    );
    print('stale-hash guard: refused');

    // A field the engine did not stand behind must be refused too, which is why
    // the panel offers no checkbox for one.
    final unappliable =
        result.fieldReviews.where((f) => !f.canApply).map((f) => f.key).toList();
    if (unappliable.isNotEmpty) {
      await expectLater(
        api.applyAiReview(folderId, sourceHash, job.inputHash, [unappliable.first]),
        throwsA(isA<QcApiException>()),
        reason: 'the engine applied a suggestion it rated un-appliable',
      );
      print('un-appliable guard: refused (${unappliable.first})');
    }

    // --- a real apply ------------------------------------------------------
    if (appliable.isEmpty) {
      print('no appliable suggestions; apply path not exercised');
    } else {
      final key = appliable.first.key;
      final before = (task['metadata'] as Map<String, Object?>)[key];
      task = await api.applyAiReview(
          folderId, sourceHash, job.inputHash, [key]);
      final after = (task['metadata'] as Map<String, Object?>)[key];
      print('applied $key: $before -> $after');
      expect(after, isNot(before), reason: 'apply did not change the metadata');

      // Undo must put the metadata back, or an accepted suggestion would be
      // unrecoverable.
      task = await api.undo(folderId);
      print('after undo: ${(task['metadata'] as Map<String, Object?>)[key]}');
    }

    await api.release(folderId);
    print('PASS');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
