// The box transfer flow of the capture app (LWCAM): checks, confirmation,
// staging, then hand-off to the background transfer queue, which copies the
// box to its destination folder for the next pipeline stage (LWIP).
// Things to know before editing: runBoxTransferFlow is shared by the box list
// and the QC view, and returns true when the box is queued, not when it has
// finished transferring.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/box_session_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/capture_box_models.dart';
import '../services/adb_device_service.dart';
import '../services/snackbar_service.dart';
import '../services/transfer_queue_service.dart';
import '../theme/app_colors.dart';
import 'box_staging_dialog.dart';

/// The box transfer flow (gate → confirm → stage → enqueue), shared by the
/// two entry points: the box-list per-row Transfer button and the QC view's
/// Confirm Transfer button.
///
/// Staging (phone verify + pulls) is a short FOREGROUND step; once staged,
/// the actual destination copy is handed off to [TransferQueueService] and
/// runs in the background — the operator can keep capturing into another box
/// immediately. Returns true once the box is successfully QUEUED (not once
/// transferred — see [TransferQueueService]/`transfer_queue_banner.dart` for
/// the eventual result), false if the operator cancelled at any gate or
/// staging failed.
Future<bool> runBoxTransferFlow({
  required BuildContext context,
  required BoxSessionController session,
  required CaptureBox box,
  required int folderCount,
}) async {
  final queue = Get.isRegistered<TransferQueueService>()
      ? Get.find<TransferQueueService>()
      : Get.put(TransferQueueService(session), permanent: true);

  if (queue.isBoxQueuedOrRunning(box.id)) {
    showAppSnackBar(
      'Already transferring',
      'This group is already queued/transferring in the background.',
      backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
      colorText: Get.theme.extension<LifewoodColors>()!.onWarning,
    );
    return false;
  }

  // Gate: every folder must be metadata-complete and hold ≥1 image.
  final issues = await session.folderIssues(box);
  if (issues.isNotEmpty) {
    if (!context.mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Group not ready to transfer'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Fix these folders first (open the group to edit):'),
              const SizedBox(height: 8),
              ...issues.map(
                (i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${i.description}',
                    style: TextStyle(color: LifewoodColors.of(ctx).warning),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false;
  }

  // Recovery integrity is per-page: check before the plan so the empty-plan
  // branch (which calls markTransferred directly) cannot bypass the decision.
  late final BoxColorCalibrationPreflight calibration;
  try {
    calibration = await session.colorCalibrationPreflight(box);
  } catch (e) {
    showAppSnackBar(
      'Colour calibration check failed',
      '$e',
      backgroundColor: Get.theme.colorScheme.error,
      colorText: Get.theme.colorScheme.onError,
    );
    return false;
  }
  if (calibration.hasIssues) {
    if (!context.mounted) return false;
    final canContinue = calibration.canContinueUncalibrated;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Colour calibration needs attention'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                canContinue
                    ? 'Some pages have no stored colour decision because the '
                          'local calibration history could not be recovered. '
                          'Continuing records them as historical (no colour '
                          'correction); pages with a valid profile keep it.'
                    : 'These pages cannot be transferred until the local '
                          'database backup is restored or the page is retaken.',
              ),
              const SizedBox(height: 8),
              ...calibration.issues.map(
                (issue) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '• ${issue.folderName} / ${issue.imageName}: ${issue.message}',
                    style: TextStyle(
                      color: canContinue
                          ? Theme.of(ctx).colorScheme.onSurfaceVariant
                          : LifewoodColors.of(ctx).warning,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(canContinue ? 'Cancel' : 'Close'),
          ),
          if (canContinue)
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue without colour calibration'),
            ),
        ],
      ),
    );
    if (proceed != true) return false;
    try {
      await session.acceptUncalibratedColorBindings(box, calibration);
    } catch (e) {
      showAppSnackBar(
        'Colour calibration needs repair',
        '$e',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
        colorText: Get.theme.extension<LifewoodColors>()!.onWarning,
      );
      return false;
    }
  } else {
    // Every page already has a valid decision; retire a stale recovery flag
    // left by an earlier recovery. Safe and best-effort.
    await session.clearResolvedColorIntegrity();
  }

  // Plan (computes + persists folder names / finalized volumes).
  final BoxTransferPlan plan;
  try {
    plan = await session.buildBoxTransferPlan(box);
  } catch (e) {
    showAppSnackBar(
      'Error',
      '$e',
      backgroundColor: Get.theme.colorScheme.error,
      colorText: Get.theme.colorScheme.onError,
    );
    return false;
  }

  if (plan.orderedSourceNames.isEmpty) {
    // Every assigned image is already recorded as uploaded — this happens
    // when a previous run was cut off AFTER all copies completed but BEFORE
    // the box was marked transferred. Before finishing that bookkeeping, run
    // the same completeness gate the queue uses: an orphaned/unverified image
    // must still block the transferred marker (this empty-plan path is
    // exactly where a retry lands).
    final issue = await session.verifyBoxComplete(box);
    if (issue != null) {
      await UploadStatsDB().setBoxTransferState(
        deviceId: box.deviceId,
        boxId: box.id,
        state: 'partial',
        error: issue,
      );
      await session.loadBoxes();
      showAppSnackBar(
        'Group not complete',
        issue,
        backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
        colorText: Get.theme.extension<LifewoodColors>()!.onWarning,
      );
      return false;
    }
    // Thumbnails fall back to the durable local store; markTransferred also
    // clears the persisted interrupted/failed marker.
    try {
      await session.persistBoxThumbnails(box);
      await session.markTransferred(box);
    } catch (e) {
      await UploadStatsDB().setBoxTransferState(
        deviceId: box.deviceId,
        boxId: box.id,
        state: 'partial',
        error: '$e',
      );
      await session.loadBoxes();
      showAppSnackBar(
        'Transfer needs retry',
        '$e',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
        colorText: Get.theme.extension<LifewoodColors>()!.onWarning,
      );
      return false;
    }
    showAppSnackBar(
      'Nothing to transfer',
      'All ${plan.totalAssigned} image(s) of this group were already '
          'transferred — marked the group as transferred.',
      backgroundColor: Get.theme.extension<LifewoodColors>()!.info,
      colorText: Get.theme.extension<LifewoodColors>()!.onInfo,
    );
    return false;
  }

  // Best-effort device sweep for the "not in this box" warning.
  int unassignedOnDevice = 0;
  final deviceNames = await AdbDeviceService().listDeviceImageNames();
  if (deviceNames != null) {
    final inBox = plan.context.infoBySourceName.keys.toSet();
    unassignedOnDevice = deviceNames.where((n) => !inBox.contains(n)).length;
  }

  if (!context.mounted) return false;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Transfer group?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              box.boxDetails,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
            ),
            const SizedBox(height: 8),
            Text(
              '$folderCount folders · '
              '${plan.orderedSourceNames.length} image(s) to transfer',
              style: const TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 8),
            ...plan.perFolderCounts.entries.map(
              (e) => Text(
                '• ${e.key}: ${e.value} image(s)',
                style: TextStyle(
                  fontSize: 15,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (plan.skippedAlreadyUploaded > 0) ...[
              const SizedBox(height: 8),
              Text(
                '${plan.skippedAlreadyUploaded} previously transferred image(s) '
                'will be skipped.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (unassignedOnDevice > 0) ...[
              const SizedBox(height: 8),
              Text(
                '⚠️ $unassignedOnDevice image(s) on the device are not part of '
                'this group and will NOT transfer.',
                style: TextStyle(
                  fontSize: 12,
                  color: LifewoodColors.of(ctx).warning,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Transfer'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;

  final staged = await showBoxStagingDialog(session: session, plan: plan);
  if (staged == null) {
    await session.loadBoxes();
    return false;
  }

  final job = queue.enqueue(box: box, plan: plan, staged: staged);
  final message = job.state.value == BoxTransferJobState.running
      ? '"${box.boxDetails}" is transferring in the background — you can '
            'keep working in another group.'
      : '"${box.boxDetails}" is queued and will transfer in the background '
            'shortly.';
  showAppSnackBar(
    'Group queued for transfer',
    message,
    backgroundColor: Get.theme.extension<LifewoodColors>()!.info,
    colorText: Get.theme.extension<LifewoodColors>()!.onInfo,
  );
  return true;
}
