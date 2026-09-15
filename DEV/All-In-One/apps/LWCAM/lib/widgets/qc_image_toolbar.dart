import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/qc_review_controller.dart';
import '../services/node_config_service.dart';
import 'qc_panel_surface.dart';

/// Whether this station offers Luminance Correction.
///
/// Read from the LOCAL node config for the same reason the AI pre-analysis flag
/// is (`qc_ai_review_controller.dart`): the engine only exposes its settings
/// through `GET /api/admin/settings/paths`, which is admin-gated and therefore
/// unreachable for a `qc` account. Both read the one
/// `lwcam_node_config.json`, so the button and the engine cannot disagree.
///
/// False whenever the config has not loaded, matching the engine's own default
/// since 2026-09-10: the tool is enhancement by definition and stays hidden
/// until a station explicitly allows it.
bool _luminanceAllowed() {
  if (!Get.isRegistered<NodeConfigService>()) return false;
  return Get.find<NodeConfigService>().cached?.luminanceEnabled ?? false;
}

/// Image tools for the page on screen.
///
/// Every button edits the reviewer's DRAFT: the engine copies the page into a
/// work area on first touch and leaves the captured file alone, so "Restore
/// original" always has something to go back to and an abandoned review changes
/// nothing.
///
/// Crop is a mode rather than a one-shot button: it swaps the viewer for a
/// selection overlay until the operator crops or cancels.
///
/// Delete and insert are here too; reorder is a drag in the page strip below,
/// since dragging a page is the gesture, not a button.
class QcImageToolbar extends StatelessWidget {
  const QcImageToolbar({
    super.key,
    required this.controller,
    required this.onDelete,
    required this.onInsert,
    required this.onReplace,
  });

  final QcReviewController controller;

  /// Both ask the operator something first - a confirmation, a file - so the
  /// page owns them rather than the toolbar.
  final VoidCallback onDelete;
  final VoidCallback onInsert;

  /// Swaps a different scan into this page, keeping the page's own filename.
  final VoidCallback onReplace;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final scheme = Theme.of(context).colorScheme;
      // Editing needs the claim. Showing live buttons that fail at the engine
      // would waste the operator's time on work that cannot land.
      final enabled = controller.canEdit && !controller.working.value;

      // Rotate, deskew, luminance and delete act on every ticked page; crop,
      // replace, insert and restore stay per-page, because none of them has a
      // meaning that survives being pointed at a set of scans. Say the count in
      // the tooltip so a click's reach is visible without counting ticks.
      final batchCount = controller.selected.length;
      String batched(String label) =>
          batchCount > 1 ? '$label ($batchCount pages)' : label;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: qcPanelSurface(context),
          border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            // The tools scroll rather than overflow. There are seventeen of
            // them, and restoring the window from maximised took the row past
            // the viewport - a RenderFlex overflow, which is a yellow-and-black
            // hazard bar across the UI, not a soft failure. (Select-all used to
            // ride along at the end here and was the first thing to scroll out
            // of reach; it lives above the page rail now.)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _Tool(
                      icon: Icons.rotate_90_degrees_ccw,
                      tooltip: batched('Rotate left'),
                      onPressed: enabled ? () => controller.rotate(-90) : null,
                    ),
                    _Tool(
                      icon: Icons.rotate_90_degrees_cw,
                      tooltip: batched('Rotate right'),
                      onPressed: enabled ? () => controller.rotate(90) : null,
                    ),
                    _Tool(
                      icon: Icons.flip_camera_android,
                      tooltip: batched('Rotate 180'),
                      onPressed: enabled ? () => controller.rotate(180) : null,
                    ),
                    _Tool(
                      icon: Icons.crop,
                      tooltip: 'Crop',
                      selected: controller.cropping.value,
                      onPressed: enabled
                          ? () => controller.cropping.toggle()
                          : null,
                    ),
                    const _Sep(),
                    // Deskew is the fine correction after LWIP already deskewed,
                    // not a second pass - the engine bounds the step to 0.1-10
                    // degrees. The step sits BETWEEN the two arrows because it
                    // belongs to both of them equally; put beside either one it
                    // reads as that direction's setting.
                    _Tool(
                      icon: Icons.turn_slight_left,
                      tooltip: batched(
                        'Straighten ${_stepLabel(controller)}° left',
                      ),
                      onPressed: enabled ? () => controller.deskew(-1) : null,
                    ),
                    _DeskewStep(controller: controller, enabled: enabled),
                    _Tool(
                      icon: Icons.turn_slight_right,
                      tooltip: batched(
                        'Straighten ${_stepLabel(controller)}° right',
                      ),
                      onPressed: enabled ? () => controller.deskew(1) : null,
                    ),
                    const _Sep(),
                    if (_luminanceAllowed()) ...[
                      _Tool(
                        icon: Icons.brightness_6_outlined,
                        tooltip: batched('Luminance correction'),
                        onPressed: enabled ? controller.luminance : null,
                      ),
                    ],
                    _Tool(
                      icon: Icons.restore,
                      tooltip: 'Restore this page to the captured original',
                      onPressed: enabled ? controller.restoreOriginal : null,
                    ),
                    const _Sep(),
                    _Tool(
                      icon: Icons.note_add_outlined,
                      tooltip: 'Insert a page before this one',
                      onPressed: enabled ? onInsert : null,
                    ),
                    // Reordering lives here because the rail cannot host it: Flutter's
                    // drag handles overlay each tile and swallow the click that selects
                    // it. The web console reorders from its toolbar for its own
                    // reasons; the result is the same shape.
                    _Tool(
                      icon: Icons.keyboard_arrow_up,
                      tooltip: 'Move this page earlier',
                      onPressed: enabled && controller.index.value > 0
                          ? () => controller.moveImage(
                              controller.index.value,
                              controller.index.value - 1,
                            )
                          : null,
                    ),
                    _Tool(
                      icon: Icons.keyboard_arrow_down,
                      tooltip: 'Move this page later',
                      onPressed:
                          enabled &&
                              controller.index.value <
                                  ((controller.task.value?.images.length ?? 1) -
                                      1)
                          ? () => controller.moveImage(
                              controller.index.value,
                              controller.index.value + 1,
                            )
                          : null,
                    ),
                    const _Sep(),
                    _Tool(
                      icon: Icons.find_replace_outlined,
                      tooltip:
                          'Replace this page with another file '
                          '(the page keeps its own name)',
                      onPressed: enabled ? onReplace : null,
                    ),
                    _Tool(
                      icon: Icons.delete_outline,
                      tooltip: batchCount > 1
                          ? 'Remove $batchCount pages'
                          : 'Remove this page',
                      onPressed: enabled ? onDelete : null,
                    ),
                    const _Sep(),
                    _Tool(
                      icon: Icons.undo,
                      tooltip: 'Undo',
                      onPressed: enabled ? controller.undo : null,
                    ),
                    _Tool(
                      icon: Icons.redo,
                      tooltip: 'Redo',
                      onPressed: enabled ? controller.redo : null,
                    ),
                  ],
                ),
              ),
            ),
            // Status stays pinned; it is the one thing that must not scroll
            // out of sight.
            const SizedBox(width: 8),
            if (controller.working.value)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (!controller.canEdit)
              Text(
                controller.isSettled
                    ? 'Completed - read only'
                    : 'Claim this task to edit',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            const SizedBox(width: 8),
          ],
        ),
      );
    });
  }
}

class _Tool extends StatelessWidget {
  const _Tool({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Marks a tool that stays on until switched off, so the operator can see
  /// that the next drag will draw a selection rather than pan the page.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(
        icon,
        size: 20,
        // Active tool = Castleton Green (Core UI colors).
        color: selected
            ? scheme.primary
            : toolboxForeground(context, enabled: onPressed != null),
      ),
      tooltip: tooltip,
      onPressed: onPressed,
      isSelected: selected,
      style: toolboxHover(context).copyWith(
        backgroundColor: selected
            ? WidgetStatePropertyAll(scheme.primaryContainer)
            : null,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The foreground every control in this toolbar draws itself in.
///
/// Set explicitly rather than left to IconButton's Material 3 default, which is
/// `onSurfaceVariant` - a mid grey that reads as washed out in light mode, where
/// these should be black. `onSurface` is near-black in light and near-white in
/// dark, so one token covers both.
///
/// The disabled branch matters: giving an icon an explicit colour throws away the
/// dimming IconButton would have applied, and a disabled tool that looks live is
/// worse than a grey one.
Color toolboxForeground(BuildContext context, {required bool enabled}) {
  final scheme = Theme.of(context).colorScheme;
  // Disabled = the muted control grey (#8A9891 in light), not a faded copy of
  // the text colour, so it matches the other secondary icons in the row.
  return enabled ? scheme.onSurface : scheme.outline;
}

/// The hover ground shared by the toolbar's tools and the viewer's arrows.
///
/// `Theme.hoverColor` in light mode — Material's default grey, the one hover
/// colour the whole app uses. Dark mode gets null, so
/// IconButton keeps its own faint overlay; a second colour to keep in step
/// would buy nothing.
ButtonStyle toolboxHover(BuildContext context) {
  final hover = Theme.of(context).hoverColor;
  return ButtonStyle(
    overlayColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.hovered) ? hover : null,
    ),
  );
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: SizedBox(
      height: 20,
      child: VerticalDivider(
        width: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    ),
  );
}

/// Formats the step the way the field shows it: `1`, not `1.0`.
String _stepLabel(QcReviewController controller) {
  final value = controller.deskewStep.value;
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

/// The degrees-per-click field, between the two straighten arrows.
///
/// Typing and the +/- buttons write to the same controller value, so the two
/// can never disagree. The text field is rebuilt from that value by keying it on
/// the value itself - which is safe HERE, unlike in the metadata form, because
/// the field is at most four characters and there is no caret worth preserving
/// mid-entry; committing on submit or focus loss rather than per keystroke is
/// what keeps a half-typed "0." from being clamped to the minimum as it is
/// typed.
class _DeskewStep extends StatefulWidget {
  const _DeskewStep({required this.controller, required this.enabled});

  final QcReviewController controller;
  final bool enabled;

  @override
  State<_DeskewStep> createState() => _DeskewStepState();
}

class _DeskewStepState extends State<_DeskewStep> {
  late final TextEditingController _text = TextEditingController(
    text: _stepLabel(widget.controller),
  );
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final typed = double.tryParse(_text.text.trim());
    if (typed != null) widget.controller.setDeskewStep(typed);
    // Always re-render from the controller: an unparseable or out-of-range
    // entry then snaps back to what will actually be applied, instead of
    // sitting there looking like it took.
    _text.text = _stepLabel(widget.controller);
  }

  /// Steps by 0.1 below one degree and by 1 above it.
  ///
  /// A flat 0.1 would take ninety clicks to get from 1 to 10; a flat 1 could
  /// never reach the half-degree corrections this field exists for.
  void _nudge(int direction) {
    final current = widget.controller.deskewStep.value;
    final increment = (direction > 0 ? current : current - 0.01) < 1
        ? 0.1
        : 1.0;
    // Rounded to one decimal: repeated 0.1 steps in binary floating point
    // otherwise drift to values like 0.7000000000000001.
    final next = ((current + increment * direction) * 10).roundToDouble() / 10;
    widget.controller.setDeskewStep(next);
    _text.text = _stepLabel(widget.controller);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.enabled;

    return Obx(() {
      // Keep the box in step when something else changes the value.
      final label = _stepLabel(widget.controller);
      if (!_focus.hasFocus && _text.text != label) _text.text = label;

      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Nudge(
              plus: false,
              tooltip: 'Smaller step',
              onPressed:
                  enabled &&
                      widget.controller.deskewStep.value >
                          QcReviewController.deskewStepMin
                  ? () => _nudge(-1)
                  : null,
            ),
            SizedBox(
              width: 42,
              child: TextField(
                controller: _text,
                focusNode: _focus,
                enabled: enabled,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  suffixText: '°',
                  suffixStyle: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onSubmitted: (_) => _commit(),
              ),
            ),
            _Nudge(
              plus: true,
              tooltip: 'Bigger step',
              onPressed:
                  enabled &&
                      widget.controller.deskewStep.value <
                          QcReviewController.deskewStepMax
                  ? () => _nudge(1)
                  : null,
            ),
          ],
        ),
      );
    });
  }
}

/// The + and - beside the step box. Smaller than a _Tool: these adjust a
/// setting, they do not edit the page, and sizing them alike would read as two
/// more image operations.
class _Nudge extends StatelessWidget {
  const _Nudge({
    required this.plus,
    required this.tooltip,
    required this.onPressed,
  });

  /// True draws `+`, false draws a minus.
  final bool plus;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // A TEXT glyph, not an icon, and that is the fix rather than a style choice.
    // These two rendered as nothing on the station in dark mode - space was
    // allocated either side of the step field and no mark appeared - while every
    // other tool in this row drew fine in the same colour, so it was never
    // contrast. `Icons.add` and `Icons.remove` were the only uses of those two
    // codepoints in the whole app, which points at the icon font rather than the
    // theme (release builds tree-shake MaterialIcons). A character from the text
    // font cannot go missing that way. U+2212 is the real minus sign; a hyphen
    // sits too high and too short beside a plus.
    return IconButton(
      icon: Text(
        plus ? '+' : '−',
        style: TextStyle(
          fontSize: 17,
          height: 1,
          fontWeight: FontWeight.w600,
          color: toolboxForeground(context, enabled: onPressed != null),
        ),
      ),
      tooltip: tooltip,
      onPressed: onPressed,
      style: toolboxHover(context),
      visualDensity: VisualDensity.compact,
      // Still smaller than a _Tool: these adjust a setting, they do not edit the
      // page, and matching the tools' footprint would read as two more image
      // operations.
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      padding: EdgeInsets.zero,
    );
  }
}
