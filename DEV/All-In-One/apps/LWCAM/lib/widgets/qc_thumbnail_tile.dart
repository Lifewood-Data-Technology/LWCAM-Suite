import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controllers/qc_review_controller.dart';
import '../models/qc_task.dart';

/// One page in the review rail: the scan itself, with its page number on it.
///
/// The image IS the tile. QC is a visual judgement - is this page straight, is
/// it cropped, is it the right way up - and a column of numbers answers none of
/// those. The filename is deliberately not drawn here; it would turn the rail
/// into a list of strings to read rather than pictures to scan, and it already
/// has a home in the Current image card.
///
/// Stateful so it can fetch on mount: the rail's list only builds tiles that
/// are near the viewport, so "load when built" IS lazy loading, with no
/// visibility observer to maintain. The controller caches by preview URL and
/// caps how many run at once, so scrolling fast queues rather than floods.
class QcThumbnailTile extends StatefulWidget {
  const QcThumbnailTile({
    super.key,
    required this.controller,
    required this.image,
    required this.pageNumber,
    required this.selected,
    required this.checked,
    required this.checkable,
    required this.edited,
    required this.onCheckedChanged,
    required this.onTap,
  });

  final QcReviewController controller;
  final QcTaskImage image;
  final int pageNumber;

  /// This is the page on screen. Distinct from [checked]: the reviewer reads one
  /// page while a batch may be aimed at several others.
  final bool selected;

  /// This page is ticked for a batch operation.
  final bool checked;

  /// The tick can be changed - the folder is claimed and the page is not broken.
  final bool checkable;

  /// The reviewer's draft has changed this page.
  final bool edited;

  final ValueChanged<bool> onCheckedChanged;

  /// Called with the modifier keys held at the moment of the tap, since
  /// [InkWell] carries none of that itself.
  final void Function(bool shift, bool ctrl) onTap;

  @override
  State<QcThumbnailTile> createState() => _QcThumbnailTileState();
}

class _QcThumbnailTileState extends State<QcThumbnailTile> {
  @override
  void initState() {
    super.initState();
    widget.controller.ensurePreview(widget.image);
  }

  @override
  void didUpdateWidget(QcThumbnailTile old) {
    super.didUpdateWidget(old);
    // An edit mints a new preview URL (the ?v= stamp), so the same page needs
    // fetching again rather than showing the pre-edit scan.
    if (old.image.previewUrl != widget.image.previewUrl) {
      widget.controller.ensurePreview(widget.image);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final image = widget.image;
    final bytes = widget.controller.previewFor(image);

    return Tooltip(
      message: image.filename,
      waitDuration: const Duration(milliseconds: 600),
      // The card is a white Material so the InkWell's hover (Theme.hoverColor,
      // Material's default grey) has a ground to paint on; an opaque
      // Container above the ink would hide it.
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            // Read the modifiers at the moment of the tap. InkWell hands over no
            // pointer event, and rebuilding the rail on a raw GestureDetector to
            // get one would cost the ink response for nothing.
            final held = HardwareKeyboard.instance.logicalKeysPressed;
            final shift =
                held.contains(LogicalKeyboardKey.shiftLeft) ||
                held.contains(LogicalKeyboardKey.shiftRight);
            final ctrl =
                held.contains(LogicalKeyboardKey.controlLeft) ||
                held.contains(LogicalKeyboardKey.controlRight) ||
                held.contains(LogicalKeyboardKey.metaLeft) ||
                held.contains(LogicalKeyboardKey.metaRight);
            widget.onTap(shift, ctrl);
          },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              // Castleton Green marks the page on screen; every other card keeps
              // the green-grey hairline so it reads as a card on the white panel.
              // A tick is shown by the checkbox and the wash below it, because
              // the two facts are independent - the page being read is often not
              // one of the ticked ones - and one border cannot say both.
              border: Border.all(
                color: widget.selected ? scheme.primary : scheme.outlineVariant,
                width: 3,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(5),
              child: AspectRatio(
                // The shape of the pages themselves, so a thumbnail is a small
                // version of the scan rather than a cropped or padded one.
                aspectRatio: 1 / 1.35,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (!image.available)
                      Center(
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: scheme.error,
                          size: 20,
                        ),
                      )
                    else if (bytes == null)
                      const Center(
                        child: SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      // contain, not cover: a cropped thumbnail would hide the
                      // very edges the reviewer is checking.
                      Image.memory(bytes, fit: BoxFit.contain),
                    // A ticked page has to be legible at rail width from across a
                    // desk, which a 20px checkbox alone is not.
                    if (widget.checked)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: scheme.primary.withValues(alpha: 0.22),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 4,
                      left: 4,
                      // Swallows the tap so ticking a page does not also make it
                      // the page on screen - the reviewer keeps reading what they
                      // were reading while building a selection.
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: widget.checkable
                            ? () => widget.onCheckedChanged(!widget.checked)
                            : null,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            // The scans are mostly white, so an unticked box
                            // needs its own ground to be visible at all.
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: widget.checked,
                              // The GestureDetector above owns the hit area; the
                              // checkbox itself only draws, so the tap target is
                              // the whole padded square rather than the 18px tick.
                              onChanged: widget.checkable
                                  ? (v) => widget.onCheckedChanged(v ?? false)
                                  : null,
                              side: const BorderSide(
                                color: Colors.white70,
                                width: 1.5,
                              ),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Left of the page number, so the rail can be scanned
                          // down the same column for both facts. Suppressed on an
                          // inserted page: NEW already says the page is the
                          // reviewer's, and saying it twice on one thumbnail
                          // crowds the number off a 240px rail.
                          if (widget.edited &&
                              widget.image.draftState != 'inserted') ...[
                            _Pill(
                              text: 'Edited',
                              background: scheme.secondary,
                              foreground: scheme.onSecondary,
                            ),
                            const SizedBox(width: 4),
                          ],
                          _Pill(
                            text: widget.pageNumber.toString().padLeft(2, '0'),
                            background: widget.selected
                                ? scheme.primary
                                : Colors.black.withValues(alpha: 0.55),
                            foreground: widget.selected
                                ? scheme.onPrimary
                                : Colors.white,
                          ),
                        ],
                      ),
                    ),
                    // A page the operator added, told apart from the ones the
                    // capture produced.
                    if (image.draftState == 'inserted')
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: _Pill(
                          text: 'NEW',
                          background: scheme.tertiary,
                          foreground: scheme.onTertiary,
                        ),
                      ),
                    // Where a split into a child folder begins.
                    if (image.separationStart)
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 3, color: scheme.primary),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.background,
    required this.foreground,
  });

  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}
