import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/controllers/upload_contoller.dart' show BoxTransferContext;
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/transfer_queue_service.dart';

BoxTransferJob _makeJob({int boxId = 1, int id = 1}) {
  final box = CaptureBox(id: boxId, deviceId: 'SAX01', boxDetails: 'BOX-$boxId');
  final plan = BoxTransferPlan(
    box: box,
    context: BoxTransferContext(boxId: boxId, boxDetails: box.boxDetails, infoBySourceName: const {}),
    orderedSourceNames: const ['IMG_1.jpg'],
    totalAssigned: 1,
    skippedAlreadyUploaded: 0,
    perFolderCounts: const {},
  );
  // An isolated subdirectory, never the shared systemTemp root itself — some
  // tests exercise the queue's stage-dir cleanup, which deletes this path.
  final stageDir = Directory.systemTemp.createTempSync('transfer_queue_job_test_');
  addTearDown(() {
    if (stageDir.existsSync()) stageDir.deleteSync(recursive: true);
  });
  return BoxTransferJob(
    id: id,
    box: box,
    plan: plan,
    stageDir: stageDir,
    stagedFiles: const [],
  );
}

void main() {
  group('BoxTransferJob.isActive', () {
    test('true for queued/running/waitingForDestination', () {
      final job = _makeJob();
      expect(job.isActive, isTrue); // starts queued

      job.state.value = BoxTransferJobState.running;
      expect(job.isActive, isTrue);

      job.state.value = BoxTransferJobState.waitingForDestination;
      expect(job.isActive, isTrue);
    });

    test('false for succeeded/partial/failed/cancelled', () {
      final job = _makeJob();
      for (final s in [
        BoxTransferJobState.succeeded,
        BoxTransferJobState.partial,
        BoxTransferJobState.failed,
        BoxTransferJobState.cancelled,
      ]) {
        job.state.value = s;
        expect(job.isActive, isFalse, reason: 'state $s should not be active');
      }
    });
  });

  group('QueueAlertPresenter', () {
    test('showCriticalError records the message on the job without throwing', () async {
      final job = _makeJob();
      await QueueAlertPresenter(job).showCriticalError(
        title: 'TIMEOUT',
        message: 'took too long',
      );
      expect(job.errorMessage.value, contains('TIMEOUT'));
      expect(job.errorMessage.value, contains('took too long'));
    });

    test('showFilesNotTransferred records missing/mismatch counts', () {
      final job = _makeJob();
      QueueAlertPresenter(job)
          .showFilesNotTransferred(missing: 2, sizeMismatch: 1);
      expect(job.errorMessage.value, contains('2'));
      expect(job.errorMessage.value, contains('1'));
    });

    test('waitForReconnect polls checkConnection and retryNow wakes it early',
        () async {
      final job = _makeJob();
      var callCount = 0;
      final future = QueueAlertPresenter(job).waitForReconnect(
        destDir: Directory.systemTemp,
        destPath: 'X:\\destination',
        checkConnection: () async {
          callCount++;
          return callCount >= 2; // fails first check, succeeds the second
        },
      );

      // Let the first (failing) check run and flip state.
      await Future.delayed(Duration.zero);
      expect(job.state.value, BoxTransferJobState.waitingForDestination);

      // Without retryNow, this would wait a real 5 seconds — waking it early
      // is exactly what the banner's "Retry now" button does.
      job.retryNow();
      await future;

      expect(job.state.value, BoxTransferJobState.running);
      expect(callCount, 2);
    });
  });

  group('TransferQueueService queue management', () {
    late TransferQueueService service;

    setUp(() {
      final auth = AuthController();
      final session = BoxSessionController(auth);
      service = TransferQueueService(session);
    });

    test('isBoxQueuedOrRunning reflects only active states', () {
      final job = _makeJob(boxId: 5);
      service.queue.add(job);

      expect(service.isBoxQueuedOrRunning(5), isTrue);
      expect(service.isBoxQueuedOrRunning(6), isFalse);

      job.state.value = BoxTransferJobState.succeeded;
      expect(service.isBoxQueuedOrRunning(5), isFalse);
    });

    test('queuedCount counts only jobs still in the queued state', () {
      final a = _makeJob(boxId: 1, id: 1);
      final b = _makeJob(boxId: 2, id: 2)..state.value = BoxTransferJobState.running;
      final c = _makeJob(boxId: 3, id: 3);
      service.queue.addAll([a, b, c]);

      expect(service.queuedCount, 2);
    });

    test('cancelQueued removes a queued job, moves it to history as cancelled',
        () {
      final job = _makeJob(boxId: 7);
      service.queue.add(job);

      final cancelled = service.cancelQueued(7);

      expect(cancelled, isTrue);
      expect(service.queue, isEmpty);
      expect(service.history, hasLength(1));
      expect(service.history.first.state.value, BoxTransferJobState.cancelled);
    });

    test('cancelQueued returns false for a job that is not queued (e.g. running)',
        () {
      final job = _makeJob(boxId: 8)..state.value = BoxTransferJobState.running;
      service.queue.add(job);

      expect(service.cancelQueued(8), isFalse);
      expect(service.queue, hasLength(1)); // untouched
    });

    test('dismiss removes a finished job from history', () {
      final job = _makeJob(boxId: 9)..state.value = BoxTransferJobState.succeeded;
      service.history.add(job);

      service.dismiss(job);

      expect(service.history, isEmpty);
    });
  });
}
