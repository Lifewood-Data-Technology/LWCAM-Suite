// Modal progress dialog shown while a capture box is staged for transfer in the
// capture app (LWCAM): the images are verified and pulled from the phone before
// the background transfer queue takes over. Opened by box_transfer_flow.dart.
// Things to know before editing: the dialog cannot be dismissed by tapping
// outside, and it returns null on failure or cancel (the caller shows errors).

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/box_session_controller.dart';

/// Short FOREGROUND modal covering just the staging step (phone verify +
/// pulls) of a box transfer — the destination copy that follows runs in the
/// background via TransferQueueService. Returns null on failure/cancel; the
/// caller (box_transfer_flow.dart) shows the error itself.
Future<StagedBox?> showBoxStagingDialog({
  required BoxSessionController session,
  required BoxTransferPlan plan,
}) {
  return Get.dialog<StagedBox>(
    _BoxStagingDialog(session: session, plan: plan),
    barrierDismissible: false,
  );
}

class _BoxStagingDialog extends StatefulWidget {
  final BoxSessionController session;
  final BoxTransferPlan plan;
  const _BoxStagingDialog({required this.session, required this.plan});

  @override
  State<_BoxStagingDialog> createState() => _BoxStagingDialogState();
}

class _BoxStagingDialogState extends State<_BoxStagingDialog> {
  int _done = 0;
  int _total = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _total = widget.plan.orderedSourceNames.length;
    _run();
  }

  Future<void> _run() async {
    try {
      final staged = await widget.session.stageBoxFiles(
        widget.plan,
        onProgress: (done, total) {
          if (mounted) setState(() { _done = done; _total = total; });
        },
      );
      if (mounted) Get.back(result: staged);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Preparing group for transfer'),
      content: SizedBox(
        width: 360,
        child: _error != null
            ? Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(
                    value: _total == 0 ? null : _done / _total,
                  ),
                  const SizedBox(height: 12),
                  Text('Pulling images from the device… $_done/$_total'),
                ],
              ),
      ),
      actions: _error != null
          ? [
              TextButton(
                onPressed: () => Get.back(result: null),
                child: const Text('Close'),
              ),
            ]
          : null,
    );
  }
}
