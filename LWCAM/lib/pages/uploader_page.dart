// Transfer progress page of the capture app (LWCAM): asks for the group
// details, prepares the files and copies them to the destination folder where
// the next stage (LWIP) picks them up.
// Things to know before editing: files are prepared lazily through the
// prepareFiles callback, and a box transfer skips the details prompt by passing
// presetBoxDetails.

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/upload_controller.dart';
import 'upload_status_page.dart';
import '../theme/app_colors.dart';

class UploaderPage extends StatefulWidget {
  /// Callback that prepares files (pulls from ADB)
  /// after user confirms box details.
  final Future<List<File>> Function() prepareFiles;

  /// When set, this is a capture-box transfer (Box→Folders workflow): the
  /// box-details prompt is skipped (the box already carries it) and
  /// [presetBoxDetails] is used instead.
  final BoxTransferContext? boxContext;
  final String? presetBoxDetails;

  const UploaderPage({
    super.key,
    required this.prepareFiles,
    this.boxContext,
    this.presetBoxDetails,
  });

  @override
  State<UploaderPage> createState() => _UploaderPageState();
}

class _UploaderPageState extends State<UploaderPage> {
  final UploadController c = Get.find<UploadController>();
  UploadBatchResult? _result;

  @override
  void initState() {
    super.initState();
    _startUploadFlow();
  }

  /// Entry point for the upload process — ensures safe context usage
  void _startUploadFlow() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final boxDetails = widget.boxContext != null
          ? widget.presetBoxDetails
          : await _promptBoxDetails(context);

      if (!mounted) return;

      if (boxDetails != null && boxDetails.isNotEmpty) {
        // mark that we are preparing and set an initial label
        c.startPreparing(label: "Preparing items for upload…");

        List<File> files = [];
        try {
          files = await widget.prepareFiles();
        } finally {
          // if something goes wrong and no files at all, clear preparing state
          if (files.isEmpty) {
            c.finishPreparing();
          }
        }

        if (!mounted) return;

        if (files.isEmpty) {
          _popSelf(null);
          return;
        }

        c.addFiles(files);
        try {
          _result = await c.uploadAll(
            boxDetails: boxDetails,
            box: widget.boxContext,
          );
        } catch (e) {
          // A throw before/around the engine's own handling (e.g. the
          // destination folder can't be created on an unreachable share)
          // must not strand the dialog open with no result.
          c.finishPreparing();
          debugPrint('Upload flow failed: $e');
        }
        // This flow owns the definitive result — close the dialog ourselves
        // once uploadAll returns, instead of relying on the build-scheduled
        // auto-close (which could fire before `_result` was assigned and
        // return null for a fully successful transfer).
        await _popSelfWithResult();
      } else {
        if (mounted) {
          _popSelf(null);
        }
      }
    });
  }

  /// Pops THIS dialog route with [_result], waiting until it is the current
  /// route — never popping whatever happens to be on top (the operator may
  /// be viewing UploadStatusPage, or the engine's "some files were not
  /// transferred" warning may be showing).
  Future<void> _popSelfWithResult() async {
    while (true) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null) return; // already popped
      if (route.isCurrent) {
        if (!mounted) return;
        Navigator.of(context).pop(_result);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
  }

  void _popSelf(UploadBatchResult? result) {
    final route = ModalRoute.of(context);
    if (route != null && route.isCurrent) {
      Navigator.of(context).pop(result);
    }
  }

  /// Prompt user for Group Details
  Future<String?> _promptBoxDetails(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Enter Group Details'),
        content: TextField(
          controller: controller,
          autofocus: false,
          decoration: const InputDecoration(
            labelText: 'Group Details',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final text = controller.text.trim();
              Navigator.pop(ctx, text);
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lw = LifewoodColors.of(context);
    // Dim scrim over the covered page — deliberately black-based in both
    // modes (it darkens arbitrary content, not a themed surface).
    return Scaffold(
      backgroundColor: Colors.black.withOpacity(0.25),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Obx(() {
            final totalUploads = c.uploads.length;
            final uploading = c.isUploading.value;
            final uploadProgress = c.progress.value;

            final preparing = c.isPreparing.value;
            final preparingCurrent = c.preparingCurrent.value;
            final preparingTotal = c.preparingTotal.value;
            final preparingLabel = c.preparingLabel.value;

            final doneCount = (totalUploads == 0)
                ? 0
                : (uploadProgress * totalUploads).floor().clamp(
                    0,
                    totalUploads,
                  );

            final bool completed =
                !uploading && totalUploads > 0 && uploadProgress >= 1.0;

            IconData icon;
            Color iconColor;
            String titleText;
            String subtitleText;
            double? progressValue;

            if (preparing) {
              // 🔹 PREPARING (pulling, scanning, etc.)
              icon = Icons.hourglass_top;
              iconColor = cs.onSurfaceVariant;

              final hasTotal = preparingTotal > 0;
              if (hasTotal) {
                // title shows "Preparing items for upload… (3/40)"
                titleText =
                    "Preparing items for upload… ($preparingCurrent/$preparingTotal)";
                progressValue = (preparingCurrent / preparingTotal).clamp(
                  0.0,
                  1.0,
                );
              } else {
                titleText = "Preparing items for upload…";
                progressValue = null; // indeterminate
              }

              // subtitle says what it's doing (if you set a label)
              subtitleText = preparingLabel.isNotEmpty
                  ? preparingLabel
                  : (hasTotal ? "" : "Collecting items from device…");
            } else if (uploading) {
              // 🔹 UPLOADING
              icon = Icons.sync;
              iconColor = lw.info;
              final percent = (uploadProgress * 100)
                  .clamp(0, 100)
                  .toStringAsFixed(0);

              titleText =
                  "Uploading $totalUploads item${totalUploads == 1 ? '' : 's'}";
              subtitleText = "$doneCount of $totalUploads • $percent%";
              progressValue = uploadProgress;
            } else if (completed) {
              // 🔹 COMPLETED
              icon = Icons.check_circle;
              iconColor = lw.success;
              titleText = "Upload complete";
              subtitleText =
                  "Uploaded $doneCount of $totalUploads item${totalUploads == 1 ? '' : 's'}";
              progressValue = 1.0;

              // Fallback auto-close only (the upload flow pops this dialog
              // itself once the result is definitive). Guarded so it can
              // only ever pop THIS route — a blind Get.back here used to
              // dismiss the engine's error dialog or UploadStatusPage when
              // one of those was on top — and never before the result is in.
              Future.delayed(const Duration(seconds: 3), () {
                if (mounted && _result != null) {
                  _popSelf(_result);
                }
              });
            } else {
              // 🔹 IDLE / FALLBACK
              icon = Icons.info;
              iconColor = cs.onSurfaceVariant;
              titleText = "Ready to upload";
              subtitleText = "";
              progressValue = uploadProgress == 0.0 ? null : uploadProgress;
            }

            return GestureDetector(
              onTap: () {
                Get.to(() => UploadStatusPage());
              },
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 360,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).cardColor,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(icon, color: iconColor, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              titleText,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (subtitleText.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                subtitleText,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: 6),
                            LinearProgressIndicator(
                              value: progressValue,
                              minHeight: 4,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          uploading || preparing
                              ? Icons.open_in_full
                              : Icons.close,
                          size: 20,
                        ),
                        onPressed: () {
                          if (uploading || preparing) {
                            Get.to(() => UploadStatusPage());
                          } else {
                            _popSelf(_result);
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
