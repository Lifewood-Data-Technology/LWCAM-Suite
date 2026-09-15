import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Maps a rectangle drawn on screen back onto the image's own pixels.
///
/// The preview is drawn scaled to fit and centred, so the displayed picture is
/// smaller than its box and offset inside it. The crop endpoint wants the
/// rectangle in the PREVIEW's pixels, so every screen coordinate has to come
/// back through that same fit before it is sent.
///
/// Kept as a pure function, separately testable: an error here does not throw,
/// it silently crops the wrong part of a document, which is exactly the kind of
/// bug that reaches the customer.
Rect screenRectToImage({
  required Rect screenRect,
  required Size boxSize,
  required Size imageSize,
}) {
  if (imageSize.width <= 0 || imageSize.height <= 0) return Rect.zero;

  // BoxFit.contain: one scale for both axes, the smaller of the two.
  final scale = math.min(
    boxSize.width / imageSize.width,
    boxSize.height / imageSize.height,
  );
  final displayed = Size(imageSize.width * scale, imageSize.height * scale);
  final offset = Offset(
    (boxSize.width - displayed.width) / 2,
    (boxSize.height - displayed.height) / 2,
  );

  final left =
      ((screenRect.left - offset.dx) / scale).clamp(0.0, imageSize.width);
  final top = ((screenRect.top - offset.dy) / scale).clamp(0.0, imageSize.height);
  final right =
      ((screenRect.right - offset.dx) / scale).clamp(0.0, imageSize.width);
  final bottom =
      ((screenRect.bottom - offset.dy) / scale).clamp(0.0, imageSize.height);

  return Rect.fromLTRB(left, top, right, bottom);
}

/// Draws the preview with an adjustable crop rectangle over it.
///
/// Drawn once, then EDITED: eight handles resize it from any corner or edge and
/// dragging the middle moves the whole box. It used to be draw-only — every
/// drag started a fresh rectangle — so nudging one edge in meant redrawing all
/// four by hand and losing the three you had already lined up. The web console
/// has the same eight (QcIndexView.vue:1625-1650).
class QcCropOverlay extends StatefulWidget {
  const QcCropOverlay({
    super.key,
    required this.bytes,
    required this.imageSize,
    required this.onCancel,
    required this.onApply,
    this.busy = false,
  });

  final Uint8List bytes;

  final Size imageSize;

  final VoidCallback onCancel;

  final void Function(Rect imageRect) onApply;

  final bool busy;

  @override
  State<QcCropOverlay> createState() => _QcCropOverlayState();
}

/// Which part of the selection a drag is moving.
enum _Grip { nw, n, ne, e, se, s, sw, w, move }

class _QcCropOverlayState extends State<QcCropOverlay> {
  /// Smallest selection worth sending. Below this a crop is almost certainly a
  /// stray click, and the engine would be asked to keep a sliver of a page.
  static const double _minSide = 12;

  /// Hit area of a handle. Larger than the 10px square it draws, because a
  /// 10px mouse target is a test of aim rather than of intent.
  static const double _grabSlop = 22;

  Rect? _rect;
  _Grip? _grip;
  Offset _dragFrom = Offset.zero;
  Rect _rectAtDragStart = Rect.zero;

  /// The grip under [point], or null to start a new rectangle there.
  _Grip? _gripAt(Offset point) {
    final rect = _rect;
    if (rect == null) return null;
    bool near(double a, double b) => (a - b).abs() <= _grabSlop;
    final onLeft = near(point.dx, rect.left);
    final onRight = near(point.dx, rect.right);
    final onTop = near(point.dy, rect.top);
    final onBottom = near(point.dy, rect.bottom);
    final withinX =
        point.dx >= rect.left - _grabSlop && point.dx <= rect.right + _grabSlop;
    final withinY =
        point.dy >= rect.top - _grabSlop && point.dy <= rect.bottom + _grabSlop;

    // Corners first: on a small selection the edge bands overlap them, and a
    // corner is the more specific intent.
    if (onLeft && onTop) return _Grip.nw;
    if (onRight && onTop) return _Grip.ne;
    if (onRight && onBottom) return _Grip.se;
    if (onLeft && onBottom) return _Grip.sw;
    if (onTop && withinX) return _Grip.n;
    if (onBottom && withinX) return _Grip.s;
    if (onLeft && withinY) return _Grip.w;
    if (onRight && withinY) return _Grip.e;
    if (rect.contains(point)) return _Grip.move;
    return null;
  }

  Rect _applyDrag(Offset delta, Size box) {
    final start = _rectAtDragStart;
    var left = start.left, top = start.top;
    var right = start.right, bottom = start.bottom;

    switch (_grip!) {
      case _Grip.move:
        // Moving must not resize, so the box is shifted whole and stopped at
        // the pane edge rather than clipped against it.
        final dx = delta.dx.clamp(-start.left, box.width - start.right);
        final dy = delta.dy.clamp(-start.top, box.height - start.bottom);
        return start.shift(Offset(dx, dy));
      case _Grip.nw:
        left += delta.dx;
        top += delta.dy;
      case _Grip.n:
        top += delta.dy;
      case _Grip.ne:
        right += delta.dx;
        top += delta.dy;
      case _Grip.e:
        right += delta.dx;
      case _Grip.se:
        right += delta.dx;
        bottom += delta.dy;
      case _Grip.s:
        bottom += delta.dy;
      case _Grip.sw:
        left += delta.dx;
        bottom += delta.dy;
      case _Grip.w:
        left += delta.dx;
    }

    // Stop an edge crossing its opposite: without this, dragging hard past the
    // far side inverts the rectangle.
    left = left.clamp(0.0, math.max(0.0, right - _minSide));
    top = top.clamp(0.0, math.max(0.0, bottom - _minSide));
    right = right.clamp(math.min(box.width, left + _minSide), box.width);
    bottom = bottom.clamp(math.min(box.height, top + _minSide), box.height);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  MouseCursor _cursorFor(_Grip? grip) => switch (grip) {
        _Grip.nw || _Grip.se => SystemMouseCursors.resizeUpLeftDownRight,
        _Grip.ne || _Grip.sw => SystemMouseCursors.resizeUpRightDownLeft,
        _Grip.n || _Grip.s => SystemMouseCursors.resizeUpDown,
        _Grip.e || _Grip.w => SystemMouseCursors.resizeLeftRight,
        _Grip.move => SystemMouseCursors.move,
        null => SystemMouseCursors.precise,
      };

  static Offset _handleCentre(Rect r, _Grip grip) => switch (grip) {
        _Grip.nw => r.topLeft,
        _Grip.n => Offset(r.center.dx, r.top),
        _Grip.ne => r.topRight,
        _Grip.e => Offset(r.right, r.center.dy),
        _Grip.se => r.bottomRight,
        _Grip.s => Offset(r.center.dx, r.bottom),
        _Grip.sw => r.bottomLeft,
        _Grip.w => Offset(r.left, r.center.dy),
        _Grip.move => r.center,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final boxSize = Size(constraints.maxWidth, constraints.maxHeight);
        final rect = _rect;
        final usable = rect != null &&
            rect.width >= _minSide &&
            rect.height >= _minSide;

        return Stack(
          children: [
            Positioned.fill(
              child: MouseRegion(
                cursor: _cursorFor(_grip),
                child: GestureDetector(
                  onPanStart: (details) => setState(() {
                    final grip = _gripAt(details.localPosition);
                    _dragFrom = details.localPosition;
                    if (grip == null) {
                      // Nothing under the cursor: start a fresh selection and
                      // treat it as dragging its bottom-right corner out.
                      _rect = Rect.fromPoints(
                        details.localPosition,
                        details.localPosition,
                      );
                      _grip = _Grip.se;
                    } else {
                      _grip = grip;
                    }
                    _rectAtDragStart = _rect!;
                  }),
                  onPanUpdate: (details) {
                    if (_grip == null) return;
                    setState(() {
                      _rect =
                          _applyDrag(details.localPosition - _dragFrom, boxSize);
                    });
                  },
                  onPanEnd: (_) => setState(() => _grip = null),
                  child: Container(
                    color: scheme.surfaceContainerHighest,
                    child: Center(child: Image.memory(widget.bytes)),
                  ),
                ),
              ),
            ),
            if (rect != null) ...[
              // Dim everything outside the selection, so the eye reads what
              // will be KEPT rather than what happens to be boxed.
              IgnorePointer(
                child: CustomPaint(
                  size: boxSize,
                  painter: _ShadePainter(rect: rect),
                ),
              ),
              Positioned.fromRect(
                rect: rect,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.primary, width: 2),
                    ),
                  ),
                ),
              ),
              for (final grip in _Grip.values)
                if (grip != _Grip.move)
                  Positioned(
                    left: _handleCentre(rect, grip).dx - 5,
                    top: _handleCentre(rect, grip).dy - 5,
                    child: IgnorePointer(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          border: Border.all(color: scheme.onPrimary),
                        ),
                      ),
                    ),
                  ),
            ],
            Positioned(
              left: 12,
              bottom: 12,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        rect == null
                            ? 'Drag to select the area to keep, then adjust its edges'
                            : _describe(rect, boxSize),
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(width: 12),
                      if (rect != null)
                        TextButton(
                          onPressed: widget.busy
                              ? null
                              : () => setState(() => _rect = null),
                          child: const Text('Reset'),
                        ),
                      TextButton(
                        onPressed: widget.busy ? null : widget.onCancel,
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: !usable || widget.busy
                            ? null
                            : () => widget.onApply(
                                  screenRectToImage(
                                    screenRect: rect,
                                    boxSize: boxSize,
                                    imageSize: widget.imageSize,
                                  ),
                                ),
                        child: Text(widget.busy ? 'Cropping…' : 'Crop'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  String _describe(Rect rect, Size boxSize) {
    final image = screenRectToImage(
      screenRect: rect,
      boxSize: boxSize,
      imageSize: widget.imageSize,
    );
    return '${image.width.round()} × ${image.height.round()} px';
  }
}

/// Darkens everything outside the selection.
class _ShadePainter extends CustomPainter {
  const _ShadePainter({required this.rect});

  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) {
    // saveLayer + clear punches the hole: a plain four-rectangle border would
    // seam at the corners when the selection sits against an edge.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0x6B000000));
    canvas.drawRect(rect, Paint()..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShadePainter old) => old.rect != rect;
}
