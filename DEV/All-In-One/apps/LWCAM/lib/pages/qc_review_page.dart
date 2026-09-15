import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/qc_ai_review_controller.dart';
import '../controllers/qc_review_controller.dart';
import '../models/qc_ai_review.dart';
import '../models/qc_task.dart';
import '../services/node_config_service.dart';
import '../widgets/qc_ai_review_dialog.dart';
import '../widgets/qc_ai_review_panel.dart';
import '../widgets/qc_crop_overlay.dart';
import '../widgets/qc_image_toolbar.dart';
import '../widgets/qc_thumbnail_tile.dart';
import '../widgets/qc_metadata_form.dart';
import '../widgets/qc_panel_surface.dart';
import '../widgets/qc_reject_dialog.dart';

/// Reviews one task's pages.
///
/// Pages on the left, metadata on the right - the layout a reviewer actually
/// works in, reading the scan while keying what it says.
///
/// Every image operation is here: rotate, straighten, luminance, crop, restore,
/// undo/redo, insert, delete, and reorder by dragging in the page strip. The
/// right pane carries the metadata form and the AI review beside it.
///
/// Approve is the only action here that writes to `capture_folders`; everything
/// else edits a draft that can be abandoned.
class QcReviewPage extends StatefulWidget {
  const QcReviewPage({super.key, required this.folderId, this.title});

  final int folderId;
  final String? title;

  @override
  State<QcReviewPage> createState() => _QcReviewPageState();
}

class _QcReviewPageState extends State<QcReviewPage> {
  // Registered once, in initState rather than build. GetX returns the existing
  // instance on a repeat Get.put, so calling it from build was not fatal - but
  // it ran on every rebuild, and the widgets below are about to do a great deal
  // more rebuilding than they used to.
  late final QcReviewController _controller = Get.put(
    QcReviewController(widget.folderId),
    tag: '${widget.folderId}',
  );

  // Depends on the review controller for the claim and the task, so it is
  // created after it.
  late final QcAiReviewController _ai = Get.put(
    QcAiReviewController(_controller),
    tag: '${widget.folderId}',
  );

  Worker? _jobWatch;

  /// The job whose findings have already been put in front of the operator.
  /// Once per job, not once per visit: reopening a task should not repeat a
  /// dialog that was already read, but a fresh run mints a new id and does.
  String? _modalShownForJob;

  /// The operator chose to work without waiting for the review.
  bool _gateOpened = false;

  /// A review has been started for this visit, so a failure is not retried in a
  /// loop. Retrying is the operator's call - three different output-contract
  /// failures and two provider rate limits were seen in one afternoon, and an
  /// automatic loop would just spend money on them.
  bool _autoStarted = false;

  @override
  void initState() {
    super.initState();
    // The toolbar reads node-config flags (luminance) from the in-memory copy,
    // which LWCAM loaded at login. LWCam Admin's Station Setup rewrites that
    // file from another process, so re-read it here: one file read per task
    // opened, and a flag flipped in Admin lands on the next task instead of
    // the next login. Rebuild once it arrives so the toolbar picks it up.
    if (Get.isRegistered<NodeConfigService>()) {
      Get.find<NodeConfigService>().reload().then((_) {
        if (mounted) setState(() {});
      }).catchError((Object e) => print('⚠️ Node config reload failed: $e'));
    }
    // One watcher serves both paths. With auto-run on it also releases the gate;
    // with auto-run off it is what makes a manual run interrupt the operator
    // when it lands, which it never did before - a finished job only repainted a
    // panel that is collapsed by default.
    _jobWatch = ever<QcAiReviewJob?>(_ai.job, (_) => _onJobChanged());
  }

  @override
  void dispose() {
    _jobWatch?.dispose();
    super.dispose();
  }

  /// True while the task must stay hidden behind the analysing screen.
  bool get _gated {
    if (!_ai.autoRun || _gateOpened || _ai.disabled.value) return false;
    if (!_controller.canEdit || _controller.isSettled) return false;
    final job = _ai.job.value;
    return job?.result == null;
  }

  void _onJobChanged() {
    final job = _ai.job.value;

    // Nothing to analyse yet, or nothing worth analysing.
    if (_ai.autoRun &&
        !_autoStarted &&
        !_gateOpened &&
        !_ai.disabled.value &&
        _controller.canEdit &&
        !_controller.isSettled &&
        job == null &&
        !_ai.loading.value) {
      // Preanalysis only scans folders nobody has claimed, so a folder claimed
      // before the scanner reached it has no review and never will. Start one.
      _autoStarted = true;
      _ai.start();
      return;
    }

    if (job == null || job.status != 'succeeded' || job.result == null) {
      if (mounted) setState(() {});
      return;
    }
    if (job.jobId == _modalShownForJob) return;
    if (!_controller.canEdit || _controller.isSettled) return;

    _modalShownForJob = job.jobId;
    // The worker can fire mid-build, and showing the findings also reveals the
    // task behind them.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      QcAiReviewDialog.show(context, _ai);
    });
  }

  /// Left and right page through the scans.
  ///
  /// Scoped to the rail and the viewer, NOT the whole screen, and that is the
  /// whole design. Flutter's text-editing shortcuts live at the app level,
  /// ABOVE any page - so a page-level handler sees an arrow key BEFORE the
  /// focused field's caret does and eats it. Measured, not assumed: keying a
  /// volume number and pressing left turned the page instead of moving the
  /// cursor. Hanging this off a subtree the metadata panel is not part of means
  /// the handler is simply not on the focus chain while a field has focus,
  /// which needs no test of what kind of widget is focused.
  ///
  /// Returning `handled` also keeps the key away from Flutter's default
  /// arrow-to-focus-traversal binding, which would walk the toolbar instead of
  /// turning the page.
  KeyEventResult _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _controller.previous();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _controller.next();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final controller = _controller;
    final ai = _ai;

    return Scaffold(
      appBar: AppBar(
        title: Text(title ?? 'Review'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            icon: const Icon(Icons.refresh),
            onPressed: controller.load,
          ),
          // Reopening the findings, in the one place that is always visible.
          // The panel has the same button, but the panel is collapsed by
          // default - so after closing the window by accident there was nothing
          // to click, which is no way to treat findings the reviewer is meant to
          // act on. Counts them, so it also says there is something to look at.
          Obx(() {
            // Shown for any COMPLETED review, including one that found nothing -
            // "the check ran and was clean" is worth being able to see again.
            // The count is dropped rather than shown as (0), which reads like a
            // fault.
            final result = ai.job.value?.result;
            if (result == null) return const SizedBox.shrink();
            final findings = result.fieldReviews.length;
            // The AI treatment (Core UI colors): Paper ground, Dark Serpent
            // label, Saffron only on the icon. tertiaryContainer carries that
            // pair in light mode and a dark-amber equivalent in dark, so one
            // rule covers both themes and reads on the Dark Serpent bar.
            final scheme = Theme.of(context).colorScheme;
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.tertiaryContainer,
                  foregroundColor: scheme.onTertiaryContainer,
                ),
                icon: Icon(
                  Icons.fact_check_outlined,
                  size: 18,
                  color: scheme.tertiary,
                ),
                label: Text(
                  findings == 0 ? 'AI review' : 'AI review ($findings)',
                ),
                onPressed: () => QcAiReviewDialog.show(context, ai),
              ),
            );
          }),
          const SizedBox(width: 8),
          Obx(() {
            final busy = controller.finalizing.value;
            final blocked = controller.blocksApproval;
            return Row(
              children: [
                // Rework is the one action that sends work backwards, so it is
                // the semantic red. `scheme.error` is that red in light mode
                // (#D92D2D, Core UI colors) and its dark-mode counterpart.
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  icon: const Icon(Icons.replay, size: 18),
                  label: const Text('Rework'),
                  onPressed: busy || !controller.canEdit
                      ? null
                      : () => _reject(context, controller),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  // Say why it is unavailable rather than leaving a dead button.
                  message: blocked ?? 'Commit this folder',
                  child: FilledButton.icon(
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(busy ? 'Working…' : 'Approve'),
                    onPressed: busy || blocked != null
                        ? null
                        : () => _approve(context, controller),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            );
          }),
        ],
      ),
      body: Obx(() {
        if (controller.loading.value && controller.task.value == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (controller.task.value == null) {
          return _Message(
            text: controller.error.value.isEmpty
                ? 'This task could not be loaded.'
                : controller.error.value,
            isError: true,
          );
        }
        final images = controller.task.value!.images;
        if (images.isEmpty) {
          return const _Message(text: 'This folder has no pages.');
        }
        if (_gated) {
          return _AnalysingGate(
            ai: ai,
            onOpenAnyway: () => setState(() => _gateOpened = true),
          );
        }
        // Three columns, matching the web console (QcIndexView.vue:3800-3811):
        // the page rail runs the FULL height on the left - past the toolbar,
        // not stopping at it - and the toolbar spans only the centre column, so
        // it reads as belonging to the image rather than to the screen.
        final divider = VerticalDivider(
          width: 1,
          color: Theme.of(context).colorScheme.outlineVariant,
        );
        return Row(
          children: [
            // Everything that is not the metadata panel, under one focus scope
            // so the arrow keys reach _handleKey - see its doc comment for why
            // this is not simply wrapped around the Scaffold.
            Expanded(
              child: Focus(
                autofocus: true,
                onKeyEvent: (_, event) => _handleKey(event),
                child: Row(
                  children: [
                    SizedBox(
                      width: 240,
                      child: _PageStrip(controller: controller),
                    ),
                    divider,
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: _Viewer(controller: controller)),
                          QcImageToolbar(
                            controller: controller,
                            onDelete: () => _confirmDelete(context, controller),
                            onInsert: () => _pickAndInsert(controller),
                            onReplace: () => _pickAndReplace(controller),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            divider,
            SizedBox(
              width: 380,
              // One scrolling column, not tabs. The AI review reads as a
              // comment on the metadata fields, so it sits beneath them where
              // both are visible at once - hiding it behind a tab meant an
              // operator had to remember a verdict while reading the form.
              child: _ReviewPanel(controller: controller, ai: ai),
            ),
          ],
        );
      }),
    );
  }
}

/// Approve commits the draft: the pages and metadata on screen become the real
/// folder, separated pages are physically moved, and the draft is discarded.
/// None of that can be undone from here, so it is spelled out first.
Future<void> _approve(
  BuildContext context,
  QcReviewController controller,
) async {
  final task = controller.task.value;
  if (task == null) return;
  final pages = task.images.length;
  final unsaved = controller.dirty.value;

  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Approve this folder?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$pages page(s) and their metadata become final, and the '
            'folder leaves your queue.',
          ),
          const SizedBox(height: 8),
          const Text(
            'This cannot be undone from the review screen.',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          if (unsaved)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Your unsaved metadata changes are saved first.'),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Approve'),
        ),
      ],
    ),
  );
  if (!(ok ?? false)) return;

  final done = await controller.approve();
  if (!context.mounted) return;
  if (done) {
    Navigator.of(context).pop(true);
  } else {
    _sayWhy(context, controller.error.value, 'The folder was not approved.');
  }
}

/// Rework discards the reviewer's draft, so the dialog says so before asking
/// which pages are at fault.
Future<void> _reject(
  BuildContext context,
  QcReviewController controller,
) async {
  final official = controller.officialImages;
  final total = controller.task.value?.images.length ?? 0;
  if (official.isEmpty) {
    _sayWhy(context, '', 'None of these pages can be sent for rework.');
    return;
  }

  final reasons = await showDialog<Map<int, String>>(
    context: context,
    builder: (context) => QcRejectDialog(
      images: official,
      droppedInsertedPages: total - official.length,
    ),
  );
  if (reasons == null || reasons.isEmpty) return;

  final done = await controller.reject(reasons);
  if (!context.mounted) return;
  if (done) {
    Navigator.of(context).pop(true);
  } else {
    _sayWhy(
      context,
      controller.error.value,
      'The folder was not sent for rework.',
    );
  }
}

/// A terminal action that failed must not fail quietly - the reviewer needs to
/// know the folder is still theirs.
void _sayWhy(BuildContext context, String message, String fallback) {
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message.isEmpty ? fallback : message)));
}

/// Deleting a page is reversible - it edits the draft, and undo puts it back -
/// but it is still the one button here that makes a document shorter, so it
/// asks first.
Future<void> _confirmDelete(
  BuildContext context,
  QcReviewController controller,
) async {
  final image = controller.current;
  if (image == null) return;
  // Name the page when there is one to name, count them when there are several:
  // a filename is the more useful confirmation, but only while it is the whole
  // truth about what the button is going to remove.
  final count = controller.targetIds.length;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(count > 1 ? 'Remove $count pages?' : 'Remove this page?'),
      content: Text(
        count > 1
            ? '$count selected pages will be left out of this folder. The '
                  'captured files are not deleted, and Undo puts them back.'
            : '${image.filename} will be left out of this folder. The captured '
                  'file is not deleted, and Undo puts the page back.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  if (ok ?? false) await controller.deleteSelected();
}

/// Picking the file is the view's job; the controller only takes bytes.
Future<void> _pickAndInsert(QcReviewController controller) async {
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: QcReviewController.uploadExtensions,
    dialogTitle: 'Insert a page before this one',
  );
  final file = picked?.files.singleOrNull;
  final path = file?.path;
  if (file == null || path == null) return;
  // Read the file here rather than passing withData to the picker: that would
  // hold a second copy of a full-resolution scan in memory for no gain.
  await controller.insertBefore(file.name, await File(path).readAsBytes());
}

/// Swaps a different scan into the page being viewed.
///
/// The page KEEPS ITS OWN NAME. Filename is page identity here - it carries the
/// ordering and it is what the export references - so the engine renames the
/// upload to match the page it replaces rather than the other way round. Pick a
/// file called anything; it lands as the page it replaced.
Future<void> _pickAndReplace(QcReviewController controller) async {
  final image = controller.current;
  if (image == null) return;
  final picked = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: QcReviewController.uploadExtensions,
    dialogTitle: 'Replace ${image.filename}',
  );
  final file = picked?.files.singleOrNull;
  final path = file?.path;
  if (file == null || path == null) return;
  await controller.replaceImage(file.name, await File(path).readAsBytes());
}

/// The right column: which page you are on, the metadata for the folder, and
/// the AI review beneath it.
///
/// One column rather than the tabs this used to have, so a verdict and the
/// field it disputes are legible together. The AI review collapses, because
/// the metadata is the thing being read all day and it should fit without
/// scrolling; the review is consulted, not monitored.
class _ReviewPanel extends StatefulWidget {
  const _ReviewPanel({required this.controller, required this.ai});

  final QcReviewController controller;
  final QcAiReviewController ai;

  @override
  State<_ReviewPanel> createState() => _ReviewPanelState();
}

class _ReviewPanelState extends State<_ReviewPanel> {
  /// Collapsed by default: the metadata is read on every single folder, the AI
  /// review on some of them. Giving the review a permanent share of the column
  /// meant the fields - which should be legible in one look - scrolled.
  bool _aiOpen = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final ai = widget.ai;
    final scheme = Theme.of(context).colorScheme;
    // The only one of the three panels with nothing to hang a colour on - the
    // rail and the toolbar already had a Container for their hairline.
    return ColoredBox(
      color: qcPanelSurface(context) ?? Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Obx(() {
            final image = controller.current;
            final images =
                controller.task.value?.images ?? const <QcTaskImage>[];
            return Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current image',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // The filename lives here, not on the rail tile - the tile is
                  // the image itself, and a name under each one turned the rail
                  // into a list of strings you had to read instead of look at.
                  Text(
                    image?.filename ?? 'Select a page',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (images.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${controller.index.value + 1} / ${images.length}',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }),
          // Metadata takes the whole column while the review is shut, so the
          // fields fit without scrolling. Open, the review takes a fixed share.
          //
          // They are STACKED rather than the AI card sitting inside the metadata
          // list the way the web console has it - not a style choice. This AI
          // panel is itself a scroll region (its own ListView, and an Expanded
          // above it), so nesting it handed it unbounded height: that crashed the
          // paint (`child.geometry!` null in RenderViewportBase._paintContents)
          // and collapsed the metadata list on the way. The web's AI card does
          // not scroll, so it can nest; this one cannot.
          Expanded(
            flex: _aiOpen ? 3 : 1,
            child: QcMetadataForm(controller: controller),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          InkWell(
            onTap: () => setState(() => _aiOpen = !_aiOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Text(
                    'AI review',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    _aiOpen ? Icons.expand_more : Icons.expand_less,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_aiOpen) ...[
            Divider(height: 1, color: scheme.outlineVariant),
            Expanded(flex: 2, child: QcAiReviewPanel(controller: ai)),
          ],
        ],
      ),
    );
  }
}

class _Viewer extends StatelessWidget {
  const _Viewer({required this.controller});

  final QcReviewController controller;

  // Obx, because every read below is an Rx read: `current` (via index), the
  // preview cache, and `cropping`. GetX only subscribes to reads made
  // synchronously inside a builder closure, so without this the page's own
  // Obx - which is watching `task` and `loading`, not `index` - was the only
  // subscriber, and show(i) updated state nothing was listening to.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final image = controller.current;
    if (image == null) return const SizedBox.shrink();

    if (!image.available) {
      return _Message(
        text: '${image.filename} could not be read from disk.',
        isError: true,
      );
    }

    final bytes = controller.previewFor(image);
    final size = controller.previewSizeFor(image);

    // Crop needs the preview's real pixel size to map the drag, and the drag
    // itself has to reach the overlay rather than pan the viewer - so it takes
    // over the pane entirely, including the page arrows.
    if (controller.cropping.value && bytes != null && size != null) {
      return QcCropOverlay(
        bytes: bytes,
        imageSize: size,
        busy: controller.working.value,
        onCancel: () => controller.cropping.value = false,
        onApply: controller.crop,
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            // The viewer is the canvas itself (Sea Salt in light), so the
            // historical document stands out; the dark neutral frame below is
            // what gives the scan its edge, not a grey pane.
            color: Theme.of(context).scaffoldBackgroundColor,
            child: bytes == null
                ? const Center(child: CircularProgressIndicator())
                : InteractiveViewer(
                    // A reviewer's first instinct on a scan is to zoom into the
                    // handwriting, so pan/zoom is table stakes even in a
                    // viewer-only build.
                    maxScale: 6,
                    child: Center(
                      child: Container(
                        // Deliberately not Dark Serpent: the neutralised
                        // green-black reads as a viewer frame, not brand.
                        color: const Color(0xFF202824),
                        padding: const EdgeInsets.all(12),
                        child: Image.memory(bytes),
                      ),
                    ),
                  ),
          ),
        ),
        Positioned(
          left: 8,
          top: 0,
          bottom: 0,
          child: _NavButton(
            icon: Icons.chevron_left,
            onPressed: controller.index.value == 0 ? null : controller.previous,
          ),
        ),
        Positioned(
          right: 8,
          top: 0,
          bottom: 0,
          child: _NavButton(
            icon: Icons.chevron_right,
            onPressed:
                controller.index.value >=
                    (controller.task.value?.images.length ?? 1) - 1
                ? null
                : controller.next,
          ),
        ),
      ],
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Material(
        color: scheme.surface,
        shape: CircleBorder(side: BorderSide(color: scheme.outlineVariant)),
        child: IconButton(
          icon: Icon(icon),
          onPressed: onPressed,
          // Paper under the pointer, Castleton icon while hovered.
          style: toolboxHover(context).copyWith(
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) =>
                  states.contains(WidgetState.hovered) ? scheme.primary : null,
            ),
          ),
        ),
      ),
    );
  }
}

class _PageStrip extends StatelessWidget {
  const _PageStrip({required this.controller});

  final QcReviewController controller;

  // Obx for the same reason as _Viewer: `index` drives both the highlight and
  // the page counter, and neither repainted when it changed.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = controller.task.value?.images ?? const <QcTaskImage>[];
    final current = controller.index.value;

    return Container(
      decoration: BoxDecoration(
        color: qcPanelSurface(context),
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        children: [
          // Select-all sits above the list it selects. It used to be the last
          // item of the centre toolbar's horizontally scrolling tool row, where
          // restoring the window from maximised scrolled it out of sight.
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    // Tristate for the partial case: a dash says "some pages",
                    // which a plain unticked box would misreport as "none".
                    tristate: true,
                    value: controller.selected.isEmpty
                        ? false
                        : (controller.allSelected ? true : null),
                    onChanged: controller.canEdit
                        ? (v) => controller.setSelectAll(v ?? false)
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'All pages',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (controller.selected.isNotEmpty)
                  Text(
                    '${controller.selected.length} / ${images.length}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              'Page ${current + 1} of ${images.length}',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(
            // Dragging a page is the gesture for reordering one, so the strip
            // does it directly rather than offering move-left/move-right
            // buttons. Without the claim it is still a page picker, just not a
            // draggable one.
            // Vertical, which is also what makes it scrollable: a HORIZONTAL
            // list on Windows gets no scrollbar, ignores the vertical wheel
            // (it reads scrollDelta.dx, which is 0) and refuses mouse drag,
            // leaving Shift+wheel as the only working gesture. Vertical gets
            // all three for free.
            child: ReorderableListView.builder(
              // Handles OFF. Flutter overlays a 24px drag handle on each tile
              // and it wins the hit test over the tile beneath, so part of every
              // thumbnail simply would not respond to a click. Reordering moved
              // to the toolbar, which is where the web console has it.
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              itemCount: images.length,
              onReorder: (from, to) {
                // ReorderableListView reports the drop index BEFORE the dragged
                // page is lifted out, so moving later is off by one.
                controller.moveImage(from, to > from ? to - 1 : to);
              },
              itemBuilder: (context, i) {
                final image = images[i];
                return Padding(
                  key: ValueKey(image.id),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: QcThumbnailTile(
                    controller: controller,
                    image: image,
                    pageNumber: i + 1,
                    selected: i == current,
                    checked: controller.selected.contains(image.id),
                    checkable: controller.canEdit && image.available,
                    edited:
                        controller.task.value?.draftImageIds.contains(
                          image.id,
                        ) ??
                        false,
                    onCheckedChanged: (_) => controller.toggleSelect(image.id),
                    // Shift and ctrl tick pages without moving the page on
                    // screen - the reviewer builds a selection while still
                    // looking at the scan they were reading. The same shape as
                    // the web console, so the gesture means one thing in both.
                    onTap: (shift, ctrl) {
                      if (!controller.canEdit || !(shift || ctrl)) {
                        controller.show(i);
                        return;
                      }
                      if (shift) {
                        controller.selectRange(controller.index.value, i);
                      } else if (image.available) {
                        controller.toggleSelect(image.id);
                      }
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Holds the task shut until its AI review has findings.
///
/// Only on a station that reviews every folder automatically, and only for a
/// folder this reviewer has claimed. The point is that the operator meets the
/// findings before the work rather than minutes into it.
///
/// It ALWAYS offers a way past. A review is a call to somebody else's model
/// through somebody else's provider: three different output-contract failures
/// and two rate limits were seen in a single afternoon, and queue waits of over
/// thirteen minutes are in the logs. None of that may make a folder unworkable.
class _AnalysingGate extends StatelessWidget {
  const _AnalysingGate({required this.ai, required this.onOpenAnyway});

  final QcAiReviewController ai;
  final VoidCallback onOpenAnyway;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final scheme = Theme.of(context).colorScheme;
      final job = ai.job.value;
      final failed =
          job != null && (job.status == 'failed' || job.status == 'cancelled');
      // The job's own message first. `ai.error` can hold something older and
      // less relevant - a failed poll, or the 401 from asking before sign-in.
      final message = job?.error?.isNotEmpty ?? false
          ? job!.error!
          : (job?.cancelReason ?? ai.error.value);

      return Center(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                failed ? 'AI review failed' : 'Checking this folder…',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              if (failed)
                Text(
                  message.isEmpty ? 'The review did not finish.' : message,
                  style: TextStyle(fontSize: 13, color: scheme.error),
                )
              else if (job != null)
                QcAiReviewProgress(controller: ai, job: job)
              else ...[
                const LinearProgressIndicator(minHeight: 3),
                const SizedBox(height: 6),
                Text(
                  'Starting the review…',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Row(
                children: [
                  if (failed) ...[
                    FilledButton(
                      onPressed: ai.starting.value ? null : ai.start,
                      child: Text(ai.starting.value ? 'Starting…' : 'Retry'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  TextButton(
                    onPressed: onOpenAnyway,
                    child: Text(failed ? 'Open task' : 'Open task anyway'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isError ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
