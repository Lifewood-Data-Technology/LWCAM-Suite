// Status strip for the background box transfer queue in the capture app
// (LWCAM), shown on the box list and the box-mode gallery. The state comes from
// TransferQueueService.
// Things to know before editing: it hides itself when the service is not
// registered yet or the queue is idle with nothing to report.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/upload_controller.dart';
import '../pages/upload_status_page.dart';
import '../services/transfer_queue_service.dart';
import '../theme/app_colors.dart';

/// Persistent strip showing the background box-transfer queue's state —
/// shown atop the box list and the box-mode gallery body. Hidden entirely
/// when the queue has never been used this session (service not yet
/// registered) or is currently idle with nothing left to report.
class TransferQueueBanner extends StatelessWidget {
  const TransferQueueBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<TransferQueueService>()) return const SizedBox.shrink();
    final queue = Get.find<TransferQueueService>();
    final cs = Theme.of(context).colorScheme;
    final lw = LifewoodColors.of(context);

    return Obx(() {
      final waiting = queue.queue.firstWhereOrNull(
          (j) => j.state.value == BoxTransferJobState.waitingForDestination);
      final running = queue.queue
          .firstWhereOrNull((j) => j.state.value == BoxTransferJobState.running);
      final active = waiting ?? running;

      if (active != null) {
        final isWaiting = active.state.value == BoxTransferJobState.waitingForDestination;
        final queuedBehind = queue.queuedCount;
        final fg = isWaiting ? lw.onWarningContainer : cs.onPrimary;
        // One shared engine, one job at a time — the engine's overall
        // fraction is the running box's fraction.
        final progress = !isWaiting && Get.isRegistered<UploadController>()
            ? Get.find<UploadController>().progress.value
            : null;
        return Material(
          color: isWaiting ? lw.warningContainer : cs.primary,
          child: InkWell(
            onTap: () => Get.to(() => const UploadStatusPage()),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (isWaiting)
                    Icon(Icons.wifi_off, color: fg, size: 18)
                  else
                    SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: fg,
                        value: progress,
                      ),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      isWaiting
                          ? 'Destination unreachable for "${active.box.boxDetails}" — waiting to reconnect…'
                          : 'Transferring "${active.box.boxDetails}"'
                              '${progress != null ? ' ${(progress * 100).toStringAsFixed(0)}%' : ''}'
                              '${queuedBehind > 0 ? ' (+$queuedBehind queued)' : ''}',
                      style: TextStyle(color: fg),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isWaiting)
                    TextButton(
                      onPressed: active.retryNow,
                      style: TextButton.styleFrom(
                          foregroundColor: lw.onWarningContainer),
                      child: const Text('Retry now'),
                    ),
                ],
              ),
            ),
          ),
        );
      }

      // No active job — surface the most recent finished one until dismissed.
      final last = queue.history.isEmpty ? null : queue.history.first;
      if (last == null) return const SizedBox.shrink();

      final Color color;
      final Color onColor;
      final String label;
      switch (last.state.value) {
        case BoxTransferJobState.succeeded:
          color = lw.success;
          onColor = lw.onSuccess;
          label = '"${last.box.boxDetails}" transferred '
              '(${last.result?.completed ?? 0}/${last.result?.totalQueued ?? 0}).';
          break;
        case BoxTransferJobState.cancelled:
          color = cs.inverseSurface;
          onColor = cs.onInverseSurface;
          label = '"${last.box.boxDetails}" transfer cancelled.';
          break;
        default:
          color = lw.warning;
          onColor = lw.onWarning;
          label = '"${last.box.boxDetails}": '
              '${last.errorMessage.value.isEmpty ? 'transfer incomplete.' : last.errorMessage.value}'
              ' Use Retry on the group list.';
      }

      return Material(
        color: color,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(color: onColor),
                    overflow: TextOverflow.ellipsis),
              ),
              TextButton(
                onPressed: () => queue.dismiss(last),
                style: TextButton.styleFrom(foregroundColor: onColor),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ),
      );
    });
  }
}
