import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/qc_ai_review.dart';
import 'package:lwcam/services/qc_ai_poller.dart';

QcAiReviewJob job({
  String status = 'running',
  String? stage,
  bool stale = false,
  int processed = 0,
  int total = 0,
  List<QcAiReviewField> fields = const [],
}) =>
    QcAiReviewJob(
      jobId: 'j1',
      folderId: 1,
      inputHash: 'a' * 64,
      status: status,
      stage: stage,
      trigger: 'manual',
      stale: stale,
      error: null,
      cancelReason: null,
      processedImages: processed,
      totalImages: total,
      result: fields.isEmpty
          ? null
          : QcAiReviewResult(
              overallStatus: 'needs_review',
              fieldReviews: fields,
              acceptedFields: const [],
            ),
    );

QcAiReviewField field({
  String key = 'title',
  String verdict = 'mismatch',
  double confidence = 0.95,
  String? suggested = 'A better title',
}) =>
    QcAiReviewField(
      key: key,
      currentValue: 'Something',
      suggestedValue: suggested,
      verdict: verdict,
      confidence: confidence,
      evidence: const [],
    );

void main() {
  group('backoff', () {
    test('a job that moved is polled again straight away', () {
      expect(QcAiPoller.nextDelayIndex(3, progressed: true), 0);
    });

    test('a quiet job is polled less and less often', () {
      expect(QcAiPoller.nextDelayIndex(0, progressed: false), 1);
      expect(QcAiPoller.nextDelayIndex(1, progressed: false), 2);
    });

    test('the wait stops growing at the top of the ladder', () {
      final last = QcAiPoller.delaysMs.length - 1;
      expect(QcAiPoller.nextDelayIndex(last, progressed: false), last);
    });
  });

  group('progress signature', () {
    test('another page read counts as movement', () {
      expect(
        QcAiPoller.progressSignature(job(processed: 1, total: 4)),
        isNot(QcAiPoller.progressSignature(job(processed: 2, total: 4))),
      );
    });

    test('a change of stage counts as movement even at the same page count', () {
      expect(
        QcAiPoller.progressSignature(job(stage: 'extracting', processed: 4, total: 4)),
        isNot(QcAiPoller
            .progressSignature(job(stage: 'comparing', processed: 4, total: 4))),
      );
    });

    test('an unchanged job reads the same twice', () {
      expect(
        QcAiPoller.progressSignature(job(processed: 2, total: 4)),
        QcAiPoller.progressSignature(job(processed: 2, total: 4)),
      );
    });
  });

  group('starting a review', () {
    test('with no previous job, just start one', () {
      final action = QcAiPoller.startAction(null);
      expect(action.force, isFalse);
      expect(action.confirmRerun, isFalse);
    });

    test('a failed job is retried outright', () {
      final action = QcAiPoller.startAction(job(status: 'failed'));
      expect(action.force, isTrue);
      expect(action.confirmRerun, isFalse);
    });

    test('a cancelled job is retried outright', () {
      expect(QcAiPoller.startAction(job(status: 'cancelled')).force, isTrue);
    });

    test('re-running over a good result asks first', () {
      // The findings still describe this folder, so a re-run throws away
      // something the reviewer may be part-way through acting on.
      final action = QcAiPoller.startAction(job(status: 'succeeded'));
      expect(action.force, isTrue);
      expect(action.confirmRerun, isTrue);
    });

    test('a result the folder has outgrown is replaced without asking', () {
      final action =
          QcAiPoller.startAction(job(status: 'succeeded', stale: true));
      expect(action.confirmRerun, isFalse);
      expect(action.force, isFalse);
    });

    test('a job already running is not forced into a second one', () {
      expect(QcAiPoller.startAction(job(status: 'running')).force, isFalse);
    });
  });

  group('stage shown to the reviewer', () {
    test('queued reports itself', () {
      expect(QcAiPoller.resolveStage(job(status: 'queued')), 'queued');
    });

    test('the engine stage wins when it gives one', () {
      expect(
        QcAiPoller.resolveStage(job(stage: 'comparing', processed: 1, total: 9)),
        'comparing',
      );
    });

    test('every page read but no stage yet means comparing', () {
      expect(QcAiPoller.resolveStage(job(processed: 4, total: 4)), 'comparing');
    });

    test('pages still to read means extracting', () {
      expect(QcAiPoller.resolveStage(job(processed: 1, total: 4)), 'extracting');
    });

    test('a finished job has no stage', () {
      expect(QcAiPoller.resolveStage(job(status: 'succeeded')), isNull);
      expect(QcAiPoller.resolveStage(null), isNull);
    });
  });

  group('which suggestions may be applied', () {
    // The engine rejects an apply that misses any of these with a 400, and
    // rejects the WHOLE request - so one un-appliable tick would lose the lot.
    test('a confident mismatch with a value can be applied', () {
      expect(field().canApply, isTrue);
    });

    test('agreement is not a suggestion', () {
      expect(field(verdict: 'match').canApply, isFalse);
    });

    test('a field the pages never showed cannot be applied', () {
      expect(field(verdict: 'not_visible').canApply, isFalse);
    });

    test('an uncertain reading cannot be applied', () {
      expect(field(verdict: 'uncertain').canApply, isFalse);
    });

    test('confidence below the engine threshold cannot be applied', () {
      expect(field(confidence: 0.79).canApply, isFalse);
      expect(field(confidence: 0.8).canApply, isTrue);
    });

    test('a mismatch with nothing to put there cannot be applied', () {
      expect(field(suggested: null).canApply, isFalse);
      expect(field(suggested: '').canApply, isFalse);
    });
  });
}
