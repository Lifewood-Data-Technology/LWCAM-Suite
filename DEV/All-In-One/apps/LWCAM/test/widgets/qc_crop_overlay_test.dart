import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/widgets/qc_crop_overlay.dart';

/// The crop rectangle is drawn on a picture scaled to fit and centred, but the
/// engine wants it in the preview's own pixels. Getting this wrong does not
/// throw - it silently crops the wrong part of a document.
void main() {
  test('subtracts the letterbox when the image is wider than the box', () {
    // 1000x500 image in a 1000x1000 box: scale 1, 250px bars top and bottom.
    final rect = screenRectToImage(
      screenRect: const Rect.fromLTRB(100, 350, 300, 450),
      boxSize: const Size(1000, 1000),
      imageSize: const Size(1000, 500),
    );
    expect(rect.left, 100);
    expect(rect.top, 100); // 350 on screen, less 250 of letterbox
    expect(rect.width, 200);
    expect(rect.height, 100);
  });

  test('undoes the scale when the image is shrunk to fit', () {
    // 2000x1000 image in a 1000x1000 box: scale 0.5, 250px bars.
    final rect = screenRectToImage(
      screenRect: const Rect.fromLTRB(0, 250, 500, 750),
      boxSize: const Size(1000, 1000),
      imageSize: const Size(2000, 1000),
    );
    expect(rect.left, 0);
    expect(rect.top, 0);
    expect(rect.width, 1000); // 500 screen px at half scale
    expect(rect.height, 1000);
  });

  test('clamps a drag that runs off the picture onto the letterbox', () {
    // Out-of-bounds coordinates are rejected by the engine, so they must never
    // leave here.
    final rect = screenRectToImage(
      screenRect: const Rect.fromLTRB(-500, -500, 5000, 5000),
      boxSize: const Size(1000, 1000),
      imageSize: const Size(1000, 500),
    );
    expect(rect.left, 0);
    expect(rect.top, 0);
    expect(rect.right, 1000);
    expect(rect.bottom, 500);
  });

  test('a size-less image yields no rectangle', () {
    expect(
      screenRectToImage(
        screenRect: const Rect.fromLTRB(0, 0, 10, 10),
        boxSize: const Size(100, 100),
        imageSize: Size.zero,
      ),
      Rect.zero,
    );
  });
}
