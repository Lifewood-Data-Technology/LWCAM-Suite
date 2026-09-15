// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../controllers/box_session_controller.dart';
import '../controllers/upload_contoller.dart';
import '../db/upload_stats_db.dart';
import '../models/capture_box_models.dart';
import '../pages/settings_page.dart';
import 'transfer_alert_presenter.dart';
import 'windows_notification_service.dart';

enum BoxTransferJobState {
  queued,
  running,
  waitingForDestination,
  succeeded,
  partial,
  failed,
  cancelled,
}

/// One box's background transfer, from the moment its files finish staging
/// to the moment it's fully copied (or gives up). Owns [stageDir] — the
/// queue deletes it once the job finishes, regardless of outcome.
class BoxTransferJob {
  final int id;
  final CaptureBox box;
  final BoxTransferPlan plan;
  final Directory stageDir;
  final List<File> stagedFiles;

  final Rx<BoxTransferJobState> state = BoxTransferJobState.queued.obs;
  final RxString errorMessage = ''.obs;
  UploadBatchResult? result;

  /// Completed by [retryNow] to wake an in-progress `waitForReconnect` poll
  /// early — see [QueueAlertPresenter.waitForReconnect].
  Completer<void>? _reconnectSignal;

  BoxTransferJob({
    required this.id,
    required this.box,
    required this.plan,
    required this.stageDir,
    required this.stagedFiles,
  });

  bool get isActive =>
      state.value == BoxTransferJobState.queued ||
      state.value == BoxTransferJobState.running ||
      state.value == BoxTransferJobState.waitingForDestination;

  /// The banner's "Retry now" button — a no-op unless this job is currently
  /// waiting on the destination.
  void retryNow() => _reconnectSignal?.complete();
}

/// Surfaces a queued job's alerts as state changes instead of modal dialogs,
/// so the operator can keep working in another box while this one runs in
/// the background (see transfer_alert_presenter.dart for the interface Normal
/// Mode's [DialogAlertPresenter] also implements).
class QueueAlertPresenter extends TransferAlertPresenter {
  final BoxTransferJob job;
  const QueueAlertPresenter(this.job);

  @override
  Future<void> showCriticalError({
    required String title,
    required String message,
    String actionText = 'OK - CANCEL ALL',
  }) async {
    job.errorMessage.value = '$title: $message';
  }

  @override
  void showFilesNotTransferred({
    required int missing,
    required int sizeMismatch,
  }) {
    job.errorMessage.value =
        'Missing: $missing, size mismatches: $sizeMismatch (see the logs folder).';
  }

  @override
  Future<void> waitForReconnect({
    required Directory destDir,
    required String destPath,
    required Future<bool> Function() checkConnection,
  }) async {
    while (true) {
      if (await checkConnection()) {
        job.state.value = BoxTransferJobState.running;
        return;
      }
      job.state.value = BoxTransferJobState.waitingForDestination;
      final signal = Completer<void>();
      job._reconnectSignal = signal;
      await Future.any([
        Future.delayed(const Duration(seconds: 5)),
        signal.future,
      ]);
    }
  }
}

/// One-at-a-time background transfer queue for box-mode boxes. Staging
/// (phone verify + pulls) stays a short FOREGROUND step (see
/// box_staging_dialog.dart) — only the destination copy, via
/// `UploadController.uploadAll`, runs here in the background, so the
/// existing 470-line reliability engine (timeout/stall/checkpoint/verify) is
/// reused unchanged, shared with Normal Mode.
class TransferQueueService extends GetxController {
  final BoxSessionController session;
  TransferQueueService(this.session);

  final RxList<BoxTransferJob> queue = <BoxTransferJob>[].obs;

  /// Finished jobs (succeeded/partial/failed/cancelled), most recent first,
  /// kept until the operator dismisses them — the banner reads this to show
  /// a result after the job leaves [queue].
  final RxList<BoxTransferJob> history = <BoxTransferJob>[].obs;

  int _nextId = 1;
  bool _pumping = false;

  @override
  void onInit() {
    super.onInit();
    unawaited(_sweepStaleStageDirs());
  }

  /// Adds a freshly staged box to the queue and (re)starts the pump.
  BoxTransferJob enqueue({
    required CaptureBox box,
    required BoxTransferPlan plan,
    required StagedBox staged,
  }) {
    final job = BoxTransferJob(
      id: _nextId++,
      box: box,
      plan: plan,
      stageDir: staged.stageDir,
      stagedFiles: staged.files,
    );
    queue.add(job);
    unawaited(_pump());
    return job;
  }

  bool isBoxQueuedOrRunning(int boxId) =>
      queue.any((j) => j.box.id == boxId && j.isActive);

  int get queuedCount =>
      queue.where((j) => j.state.value == BoxTransferJobState.queued).length;

  /// Cancels a box's job while it's still waiting its turn — the transfer
  /// engine has no mid-copy cancel, so a RUNNING job can't be stopped here.
  bool cancelQueued(int boxId) {
    final job = queue.firstWhereOrNull(
      (j) => j.box.id == boxId && j.state.value == BoxTransferJobState.queued,
    );
    if (job == null) return false;
    queue.remove(job);
    job.state.value = BoxTransferJobState.cancelled;
    history.insert(0, job);
    unawaited(_deleteStageDir(job));
    return true;
  }

  void dismiss(BoxTransferJob job) => history.remove(job);

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (true) {
        final next = queue.firstWhereOrNull(
          (j) => j.state.value == BoxTransferJobState.queued,
        );
        if (next == null) return;
        await _run(next);
      }
    } finally {
      _pumping = false;
    }
  }

  Future<void> _run(BoxTransferJob job) async {
    final u = Get.isRegistered<UploadController>()
        ? Get.find<UploadController>()
        : Get.put(UploadController(), permanent: true);

    // A concurrent Normal-Mode modal transfer holds the shared engine state
    // (files/uploads) — wait it out before claiming it for this job.
    while (u.isUploading.value) {
      await Future.delayed(const Duration(milliseconds: 500));
    }

    job.state.value = BoxTransferJobState.running;
    // Persisted so a crash/power-loss mid-transfer is visible at next login:
    // a leftover 'running' with no live job renders as "Interrupted" on the
    // box list. Cleared by markTransferred on full success, overwritten with
    // the terminal outcome below otherwise.
    await _setPersistedState(job, 'running', null);
    // Box transfers always skip previously transferred files ("only NEW") —
    // moved here from the old box_transfer_flow.dart tail.
    final settings = Get.find<SettingsController>();
    settings.includeUploaded.value = false;
    u.addFiles(job.stagedFiles);

    UploadBatchResult? result;
    try {
      // Cloud transfer_start_at + the box's destination day dir, fixed on the
      // first attempt and reused by every retry (markCaptureBoxTransferStarted)
      // so one folder never straddles two YYYYMMDD dirs. An empty root is left
      // to uploadAll, which refuses with the Station Setup message.
      final root = settings.destinationPath.value.trim();
      Directory? destinationDir;
      if (root.isNotEmpty) {
        destinationDir = Directory(
          await UploadStatsDB().markCaptureBoxTransferStarted(
            deviceId: job.box.deviceId,
            boxId: job.box.id,
            destinationRoot: root,
          ),
        );
      }
      result = await u.uploadAll(
        boxDetails: job.box.boxDetails,
        box: job.plan.context,
        alerts: QueueAlertPresenter(job),
        destinationDir: destinationDir,
      );
    } catch (e) {
      job.errorMessage.value = '$e';
    }

    job.result = result;
    var retainStageForRetry = false;
    if (result != null && result.isFullSuccess) {
      // Completeness gate: the batch copied everything it was handed, but that
      // proves nothing about images that never reached the engine (a lost
      // assignment / stashed orphan). Only mark transferred when every
      // assigned image is recorded landed AND no orphan still targets this box.
      final issue = await session.verifyBoxComplete(job.box);
      if (issue == null) {
        await session.persistBoxThumbnails(job.box, stagedDir: job.stageDir);
        try {
          await session.markTransferred(
            job.box,
          ); // also clears last_transfer_state
          job.state.value = BoxTransferJobState.succeeded;
        } catch (e) {
          retainStageForRetry = true;
          job.errorMessage.value = '$e';
          job.state.value = BoxTransferJobState.partial;
          await _setPersistedState(job, 'partial', job.errorMessage.value);
          await _notifyFailure(job);
          await session.loadBoxes();
        }
      } else {
        job.errorMessage.value = issue;
        job.state.value = BoxTransferJobState.partial;
        await _setPersistedState(job, 'partial', issue);
        await _notifyFailure(job);
        await session.loadBoxes();
      }
    } else if (result != null) {
      job.errorMessage.value =
          'Transferred ${result.completed}/${result.totalQueued}.';
      job.state.value = BoxTransferJobState.partial;
      await _setPersistedState(job, 'partial', job.errorMessage.value);
      await _notifyFailure(job);
      await session.loadBoxes();
    } else {
      if (job.errorMessage.value.isEmpty) {
        job.errorMessage.value = 'Transfer did not complete.';
      }
      job.state.value = BoxTransferJobState.failed;
      await _setPersistedState(job, 'failed', job.errorMessage.value);
      await _notifyFailure(job);
      await session.loadBoxes();
    }

    queue.remove(job);
    history.insert(0, job);
    if (!retainStageForRetry) await _deleteStageDir(job);
  }

  /// Best-effort persist of the box's transfer outcome — a DB hiccup here
  /// must never mask the transfer result itself.
  Future<void> _setPersistedState(
    BoxTransferJob job,
    String? state,
    String? error,
  ) async {
    try {
      await UploadStatsDB().setBoxTransferState(
        deviceId: job.box.deviceId,
        boxId: job.box.id,
        state: state,
        error: error,
      );
    } catch (e) {
      print('⚠️ Could not persist transfer state for box ${job.box.id}: $e');
    }
  }

  /// Windows toast so the operator hears about a failed/partial box even
  /// while heads-down capturing into another one. Best-effort.
  Future<void> _notifyFailure(BoxTransferJob job) async {
    try {
      await WindowsNotificationService.instance.showTransferNotification(
        title: 'LWCAM group transfer needs attention',
        body:
            '"${job.box.boxDetails}": ${job.errorMessage.value} '
            'Use Retry on the group list.',
        warning: true,
      );
    } catch (_) {
      // The box tile still shows the failure — a toast miss is not fatal.
    }
  }

  Future<void> _deleteStageDir(BoxTransferJob job) async {
    try {
      if (await job.stageDir.exists())
        await job.stageDir.delete(recursive: true);
    } catch (e) {
      print('⚠️ Could not delete stage dir for box ${job.box.id}: $e');
    }
  }

  /// No job can be running at app start — clears any `box_transfer_stage*`
  /// dirs a crash/forced-close left behind mid-transfer.
  Future<void> _sweepStaleStageDirs() async {
    try {
      await for (final entity in Directory.systemTemp.list()) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('box_transfer_stage')) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {
      // Best-effort — a locked/unreadable temp dir must never block startup.
    }
  }
}
