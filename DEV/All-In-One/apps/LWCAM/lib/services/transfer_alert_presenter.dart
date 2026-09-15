import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// Where `UploadController.uploadAll`'s critical-error / files-not-transferred
/// / destination-unreachable alerts are surfaced. [DialogAlertPresenter] (the
/// default) reproduces the original always-modal behavior verbatim, so Normal
/// Mode's single foreground transfer is byte-identical to before this
/// existed. A queued box transfer (`TransferQueueService`) instead updates
/// job state and lets the operator keep working in another box while this
/// one finishes in the background — see `QueueAlertPresenter` in
/// transfer_queue_service.dart.
abstract class TransferAlertPresenter {
  const TransferAlertPresenter();

  /// A fatal error stopped the batch (uploadAll has already set
  /// `isUploading = false` by the time this is called).
  Future<void> showCriticalError({
    required String title,
    required String message,
    String actionText = 'OK - CANCEL ALL',
  });

  /// The batch finished but some files failed post-copy verification.
  void showFilesNotTransferred({required int missing, required int sizeMismatch});

  /// The destination is unreachable; uploadAll is paused here. Returns once
  /// [checkConnection] reports the destination reachable again — callers
  /// still do their own logging/audit after this returns.
  Future<void> waitForReconnect({
    required Directory destDir,
    required String destPath,
    required Future<bool> Function() checkConnection,
  });
}

/// Reproduces uploadAll's original modal-dialog behavior exactly.
class DialogAlertPresenter extends TransferAlertPresenter {
  const DialogAlertPresenter();

  @override
  Future<void> showCriticalError({
    required String title,
    required String message,
    String actionText = 'OK - CANCEL ALL',
  }) async {
    await Get.defaultDialog(
      title: title,
      middleText: message,
      textConfirm: actionText,
      confirmTextColor: Get.theme.colorScheme.onPrimary,
      barrierDismissible: false, // Force user to click
      onConfirm: () => Get.back(),
    );
  }

  @override
  void showFilesNotTransferred({required int missing, required int sizeMismatch}) {
    Get.defaultDialog(
      title: 'Some files were not transferred',
      middleText:
          'Please check the error and interruption logs in the logs folder for details.\n\n'
          'Missing files: $missing\n'
          'Size mismatches: $sizeMismatch',
      textConfirm: 'OK',
      confirmTextColor: Get.theme.colorScheme.onPrimary,
    );
  }

  @override
  Future<void> waitForReconnect({
    required Directory destDir,
    required String destPath,
    required Future<bool> Function() checkConnection,
  }) async {
    await Get.dialog(
      WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          title: const Text('🔌 Connection Lost'),
          content: Text(
            'The destination is not reachable.\n\n'
            'Path: $destPath\n\n'
            'Please verify the network connection and ensure the destination path is accessible, '
            'then click "Reconnect" to retry.',
          ),
          actions: [
            TextButton(
              onPressed: () async {
                Get.back();
                if (await checkConnection()) return;
                await waitForReconnect(
                  destDir: destDir,
                  destPath: destPath,
                  checkConnection: checkConnection,
                );
              },
              child: const Text('Reconnect'),
            ),
          ],
        ),
      ),
      barrierDismissible: false,
    );
  }
}
