// Daily colour calibration page of the capture app (LWCAM): shows the steps of
// ColorCalibrationController (shoot the chart, analyse, accept or correct
// corners). Calibration happens before capture starts, so later images can be
// colour corrected.
// Things to know before editing: the page is reached either from the project
// area or from the capture entry gate, and what Save and Continue do depends on
// whether a resume project was passed in.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/color_calibration_controller.dart';
import '../models/project.dart';
import '../services/color_cal_service.dart';
import '../services/node_config_service.dart';
import '../widgets/session_app_bar_actions.dart';

/// Daily color-calibration capture + analyse flow (WP-D5). Reached either
/// from the project-area card (`resumeProject: null`) or from the
/// capture-entry gate's "Calibrate now" (`resumeProject` set — see
/// `calibration_gate.dart` / `AuthController.enterCaptureWithProject`'s
/// routing rule), in which case **Save & activate** and **Continue without
/// calibrating** both resume capture into that project instead of merely
/// leaving the page.
class ColorCalibrationPage extends StatelessWidget {
  const ColorCalibrationPage({super.key, this.resumeProject});

  final Project? resumeProject;

  bool get _enabled =>
      Get.isRegistered<NodeConfigService>() &&
      (Get.find<NodeConfigService>().cached?.colorCalEnabled ?? false);

  @override
  Widget build(BuildContext context) {
    if (!_enabled) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Color calibration'),
          actions: sessionAppBarActions(context),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Color calibration is switched off for this station '
              '(LWCam Admin → Station Setup).',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // Fresh per visit: Get.put returns an already-registered instance
    // unchanged, so a pre-put (real app entry, or a test driving state
    // directly) is respected rather than replaced.
    final controller = Get.put(
      ColorCalibrationController(resumeProject: resumeProject),
    );

    return PopScope(
      canPop: resumeProject == null,
      onPopInvokedWithResult: (didPop, result) {
        // Fallback only: the normal exits (Save & activate / Continue
        // without calibrating) already delete the controller themselves
        // in ColorCalibrationController._continue(), right before
        // navigating away — see its doc comment for why that can't wait
        // for a pop. Guarded so a delete that already happened there
        // doesn't run a second time here.
        if (didPop && Get.isRegistered<ColorCalibrationController>()) {
          Get.delete<ColorCalibrationController>();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Color calibration'),
          actions: sessionAppBarActions(context),
        ),
        // Esc lives on the body, not the Scaffold — same reasoning as
        // qc_review_page.dart's arrow-key handler: a Scaffold-level handler
        // would sit above any text field this page grows later and eat its
        // key events first.
        body: Focus(
          autofocus: true,
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent) return KeyEventResult.ignored;
            if (event.logicalKey == LogicalKeyboardKey.escape) {
              controller.cancel();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Obx(() => _body(controller)),
        ),
      ),
    );
  }

  Widget _body(ColorCalibrationController controller) {
    switch (controller.phase.value) {
      case CalPhase.idle:
        return _IdleView(controller: controller);
      case CalPhase.result:
        return _ResultView(controller: controller);
      case CalPhase.detectionFailed:
      case CalPhase.manualCorners:
        return _DetectionFailedView(controller: controller);
      case CalPhase.error:
        return _ErrorView(controller: controller);
      case CalPhase.launchingCamera:
      case CalPhase.waitingForShot:
      case CalPhase.pulling:
      case CalPhase.analysing:
        return _BusyView(controller: controller);
    }
  }
}

String _formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _fmt2(dynamic v) => v is num ? v.toStringAsFixed(2) : '—';

class _IdleView extends StatelessWidget {
  const _IdleView({required this.controller});
  final ColorCalibrationController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final active = controller.lastActive.value;
      final calibratedToday = ColorCalService.isCalibratedToday(active);
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.palette_outlined, size: 56),
                const SizedBox(height: 16),
                Text(
                  active == null
                      ? 'No calibration profile has been saved on this '
                            'station yet.'
                      : 'Last calibrated ${_formatDateTime(active.calibratedAt)}'
                            '${calibratedToday ? ' (today)' : ''}'
                            '${active.meanDe00 != null ? ', mean ΔE00 ${_fmt2(active.meanDe00)}' : ''}.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: const Text('Start calibration'),
                  onPressed: controller.start,
                ),
                if (controller.pending.value != null)
                  OutlinedButton(
                    onPressed: controller.resumePending,
                    child: const Text('Resume saved calibration task'),
                  ),
                if (controller.resumeProject != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: controller.continueWithoutCalibrating,
                    child: const Text('Continue without calibrating'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }
}

class _BusyView extends StatelessWidget {
  const _BusyView({required this.controller});
  final ColorCalibrationController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(controller.status.value, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: controller.cancel,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.controller});
  final ColorCalibrationController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(controller.status.value, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: controller.start,
                  child: const Text('Retake'),
                ),
                if (controller.pending.value != null)
                  OutlinedButton(onPressed: controller.resumePending, child: const Text('Resume saved calibration task')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.controller});
  final ColorCalibrationController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final result = controller.result.value;
      if (result is! CalibrationSuccess) return const SizedBox.shrink();
      final stats = (result.profile['stats'] as Map?) ?? const {};
      final perPatch =
          ((stats['per_patch'] as List?) ?? const [])
              .cast<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
            ..sort(
              (a, b) => ((b['de00'] as num?) ?? 0).compareTo(
                (a['de00'] as num?) ?? 0,
              ),
            );

      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (result.warnings.isNotEmpty)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(result.warnings.join('\n')),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Mean ΔE00',
                    value: _fmt2(stats['mean_de00']),
                  ),
                ),
                Expanded(
                  child: _StatTile(
                    label: 'Median ΔE00',
                    value: _fmt2(stats['median_de00']),
                  ),
                ),
                Expanded(
                  child: _StatTile(
                    label: 'Max ΔE00',
                    value: _fmt2(stats['max_de00']),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.detectedPng != null)
                  Expanded(
                    child: _DebugImage(
                      title: 'Detected',
                      file: result.detectedPng!,
                    ),
                  ),
                if (result.detectedPng != null && result.rectifiedPng != null)
                  const SizedBox(width: 12),
                if (result.rectifiedPng != null)
                  Expanded(
                    child: _DebugImage(
                      title: 'Rectified',
                      file: result.rectifiedPng!,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Per-patch ΔE00 (worst first)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            DataTable(
              columns: const [
                DataColumn(label: Text('Patch')),
                DataColumn(label: Text('ΔE00'), numeric: true),
                DataColumn(label: Text('Clipped')),
              ],
              rows: [
                for (final patch in perPatch)
                  DataRow(
                    cells: [
                      DataCell(Text('${patch['name']}')),
                      DataCell(Text(_fmt2(patch['de00']))),
                      DataCell(Text(patch['clipped'] == true ? 'yes' : '')),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.check),
                  label: const Text('Save & activate'),
                  onPressed: controller.saveAndActivate,
                ),
                OutlinedButton(
                  onPressed: controller.retake,
                  child: const Text('Retake'),
                ),
                TextButton(
                  onPressed: controller.continueWithoutCalibrating,
                  child: const Text('Discard'),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Text(
          '$label $value',
          style: Theme.of(context).textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _DebugImage extends StatelessWidget {
  const _DebugImage({required this.title, required this.file});
  final String title;
  final File file;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [Text(title), const SizedBox(height: 4), Image.file(file)],
    );
  }
}

class _DetectionFailedView extends StatelessWidget {
  const _DetectionFailedView({required this.controller});
  final ColorCalibrationController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final result = controller.result.value;
      final message = result is CalibrationDetectionFailed
          ? result.message
          : controller.status.value;
      final canUseDetectedAnyway =
          result is CalibrationDetectionFailed &&
          result.code == 'low_confidence';
      final image = controller.capturedImage.value;
      final quad = result is CalibrationDetectionFailed ? result.quad : null;

      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            const Text(
              "Tap the card's corners in order: top-left, top-right, "
              'bottom-right, bottom-left.',
              textAlign: TextAlign.center,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 12),
            if (image != null)
              Expanded(
                child: _CornerPicker(
                  image: image,
                  imageSize: controller.imageSize.value,
                  detectedQuad: quad,
                  // .toList() reads the RxList (registers this Obx to
                  // rebuild on tap) and hands _CornerPicker an immutable
                  // snapshot rather than the live Rx object.
                  tappedCorners: controller.tappedCorners.toList(),
                  onTap: controller.addCorner,
                ),
              ),
            const SizedBox(height: 12),
            Obx(
              () => Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: controller.tappedCorners.isEmpty
                        ? null
                        : controller.clearCorners,
                    child: const Text('Clear'),
                  ),
                  FilledButton(
                    onPressed: controller.tappedCorners.length == 4
                        ? controller.analyseWithCorners
                        : null,
                    child: const Text('Analyse with these corners'),
                  ),
                  if (canUseDetectedAnyway)
                    OutlinedButton(
                      onPressed: controller.useDetectedAnyway,
                      child: const Text('Use detected anyway'),
                    ),
                  OutlinedButton(
                    onPressed: controller.retake,
                    child: const Text('Retake'),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }
}

/// Lets the operator tap the chart's 4 corners (TL,TR,BR,BL) over the
/// captured photo when auto-detection failed or needs review. Coordinates
/// reported via [onTap] are in SOURCE image px (both `Image.file`'s decoder
/// and the CLI apply EXIF orientation, so this is the same frame the CLI's
/// `--corners` expects).
///
/// [imageSize] is decoded once by `ColorCalibrationController` right after
/// capture, not by this widget — a widget-local `ui.instantiateImageCodec`
/// decode used to gate the whole view, which is unreliable inside
/// `testWidgets` (real async decode does not settle under its fake-time
/// zone). This widget stays a dumb, stateless renderer.
class _CornerPicker extends StatelessWidget {
  const _CornerPicker({
    required this.image,
    required this.imageSize,
    required this.detectedQuad,
    required this.tappedCorners,
    required this.onTap,
  });

  final File image;
  final Size? imageSize;
  final List<Offset>? detectedQuad;

  /// A snapshot, not the live `RxList` — GetX's `Obx` cannot be nested
  /// inside `LayoutBuilder`'s builder (it mounts children during the
  /// parent's layout callback, and `Obx` asserts on an Rx read there:
  /// "the improper use of a GetX has been detected"). Reactivity to taps
  /// instead comes from the caller's own `Obx` reading `tappedCorners`
  /// before constructing this widget (`_DetectionFailedView`), which
  /// rebuilds this whole picker on every tap — cheap enough at 4 points.
  final List<Offset> tappedCorners;
  final void Function(Offset) onTap;

  @override
  Widget build(BuildContext context) {
    final size = imageSize;
    if (size == null) {
      return const Center(child: Text('Image size unknown — taps disabled.'));
    }
    final imgW = size.width;
    final imgH = size.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final boxW = constraints.maxWidth;
        final boxH = constraints.maxHeight;
        final scale = (boxW / imgW < boxH / imgH) ? boxW / imgW : boxH / imgH;
        final offX = (boxW - imgW * scale) / 2;
        final offY = (boxH - imgH * scale) / 2;

        return GestureDetector(
          key: const Key('corner_picker_tap_area'),
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final local = details.localPosition;
            final x = (local.dx - offX) / scale;
            final y = (local.dy - offY) / scale;
            if (x < 0 || y < 0 || x > imgW || y > imgH) return;
            onTap(Offset(x, y));
          },
          child: SizedBox(
            width: boxW,
            height: boxH,
            child: CustomPaint(
              foregroundPainter: _CornerPainter(
                detectedQuad: detectedQuad,
                tappedCorners: tappedCorners,
                scale: scale,
                offset: Offset(offX, offY),
              ),
              child: Center(
                child: Image.file(
                  image,
                  width: imgW * scale,
                  height: imgH * scale,
                  fit: BoxFit.fill,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CornerPainter extends CustomPainter {
  _CornerPainter({
    required this.detectedQuad,
    required this.tappedCorners,
    required this.scale,
    required this.offset,
  });

  final List<Offset>? detectedQuad;
  final List<Offset> tappedCorners;
  final double scale;
  final Offset offset;

  Offset _toCanvas(Offset src) =>
      Offset(src.dx * scale + offset.dx, src.dy * scale + offset.dy);

  @override
  void paint(Canvas canvas, Size size) {
    final quad = detectedQuad;
    if (quad != null && quad.length == 4) {
      final paint = Paint()
        ..color = Colors.grey
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      final path = Path()..addPolygon(quad.map(_toCanvas).toList(), true);
      canvas.drawPath(path, paint);
    }
    for (var i = 0; i < tappedCorners.length; i++) {
      final c = _toCanvas(tappedCorners[i]);
      canvas.drawCircle(c, 6, Paint()..color = Colors.redAccent);
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c + const Offset(8, -8));
    }
  }

  @override
  bool shouldRepaint(covariant _CornerPainter oldDelegate) =>
      oldDelegate.detectedQuad != detectedQuad ||
      !identical(oldDelegate.tappedCorners, tappedCorners) ||
      oldDelegate.tappedCorners.length != tappedCorners.length ||
      oldDelegate.scale != scale ||
      oldDelegate.offset != offset;
}
