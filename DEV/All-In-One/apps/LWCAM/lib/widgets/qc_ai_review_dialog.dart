import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/qc_ai_review_controller.dart';
import 'qc_ai_review_panel.dart';

/// The AI review's findings, in front of the operator rather than behind a
/// collapsed header.
///
/// A finished review used to land silently in the right column's panel, which is
/// collapsed by default - so a folder could carry six findings at high
/// confidence and the reviewer never see one. This is what the web console does
/// (`QcIndexView.vue`, the `el-dialog` it opens on completion), brought across.
///
/// It renders the SAME widgets as the panel ([QcAiReviewFindings],
/// [QcAiReviewApplyBar]) rather than a second copy, so selection, the
/// confidence gate and every disabled rule can only ever behave one way.
class QcAiReviewDialog extends StatelessWidget {
  const QcAiReviewDialog({super.key, required this.controller});

  final QcAiReviewController controller;

  /// Opens the dialog for [controller], if there is anything to show.
  ///
  /// Safe to call from a post-frame callback: returns immediately when the job
  /// has no result yet, so a caller reacting to a job change need not repeat
  /// that test.
  static Future<void> show(
    BuildContext context,
    QcAiReviewController controller,
  ) {
    if (controller.job.value?.result == null) return Future.value();
    return showDialog<void>(
      context: context,
      builder: (_) => QcAiReviewDialog(controller: controller),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Bounded on both axes. QcAiReviewFindings is a ListView, so it cannot size
    // itself, and an AlertDialog gives its content unbounded height - the same
    // trap documented on the panel's flex split in qc_review_page.dart.
    final maxHeight = MediaQuery.of(context).size.height * 0.6;

    return Obx(() {
      final job = controller.job.value;
      final result = job?.result;

      return AlertDialog(
        title: Row(
          children: [
            // Bold, matching the panel header this modal opens from.
            const Text(
              'AI review',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 12),
            if (job != null)
              Text(
                '${job.processedImages} / ${job.totalImages} pages',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        content: SizedBox(
          width: 720,
          height: maxHeight < 560 ? maxHeight : 560,
          child: job == null || result == null
              ? Center(
                  child: Text(
                    'This review produced no findings.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                )
              : Column(
                  children: [
                    // Say WHY nothing can be ticked. The findings describe a
                    // folder that has since changed, so every checkbox is gone
                    // and the apply bar with them - without this the window just
                    // looked broken.
                    if (controller.isStale)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'The metadata changed after this review ran, so its '
                          'findings no longer describe this folder and cannot '
                          'be applied. Run it again for current findings.',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ),
                    if (controller.error.value.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          controller.error.value,
                          style: TextStyle(fontSize: 12, color: scheme.error),
                        ),
                      ),
                    Expanded(
                      child: QcAiReviewFindings(
                        controller: controller,
                        job: job,
                        // Looking at the page is the point of the evidence, so
                        // get out of the way first.
                        onEvidenceTap: (imageId) {
                          Navigator.of(context).pop();
                          controller.review.showImageById(imageId);
                        },
                      ),
                    ),
                    if (controller.appliable.isNotEmpty && !controller.isStale)
                      ...[
                      const Divider(height: 1),
                      QcAiReviewApplyBar(
                        controller: controller,
                        // The suggestions are in the metadata now, so there is
                        // nothing left to decide here. Only on success: a
                        // failure has to stay readable, and closing would take
                        // the message with it.
                        onApplied: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ],
                ),
        ),
        actions: [
          // A stale review is a dead end without this: no checkboxes, no apply
          // bar, and the only Run again button lives in a panel that is
          // collapsed by default.
          if (controller.isStale)
            FilledButton(
              onPressed: controller.starting.value
                  ? null
                  : () {
                      Navigator.of(context).pop();
                      controller.start();
                    },
              child: Text(
                controller.starting.value ? 'Starting…' : 'Run again',
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      );
    });
  }
}
