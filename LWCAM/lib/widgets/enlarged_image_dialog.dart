// Shared full-size image viewer of the capture app (LWCAM): a zoomable dialog
// over a local image file, used by the transferred-box viewer, the unresolved
// images screen and rework mode.
// Things to know before editing: images are decoded at a capped width to keep
// large photos from exhausting memory.

import 'dart:io';

import 'package:flutter/material.dart';

/// Zoom cap for the decoded bitmap. Matches gallery_page's kPreviewCacheWidth:
/// callers pass anything from a 256px thumbnail to an LWIP input page
/// (~3566x5206, which is ~74 MB of RGBA if decoded whole). Image wraps this in
/// a ResizeImage with allowUpscaling false, so a thumbnail is unaffected.
const int _kEnlargedCacheWidth = 2560;

/// The app's one full-image viewer: a framed, zoomable dialog over a local
/// file. Shared by the transferred-box viewer, the unresolved-images screen and
/// rework mode, all of which show a photo the operator needs to actually read.
Future<void> showEnlargedImage(
  BuildContext context,
  File file, {
  String? caption,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        // A clear frame + shadow so the enlarged photo reads as a floating
        // panel instead of blending into the dimmed grid behind it.
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 6),
          boxShadow: const [
            BoxShadow(color: Colors.black87, blurRadius: 32, spreadRadius: 4),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                child: Image.file(
                  file,
                  cacheWidth: _kEnlargedCacheWidth,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'This image could not be read.',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
            if (caption != null && caption.isNotEmpty)
              Container(
                width: double.infinity,
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  caption,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
