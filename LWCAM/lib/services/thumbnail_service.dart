// ignore_for_file: avoid_print

// Builds PNG thumbnails for the LWCAM gallery and transferred-box views, and
// knows where persisted thumbnails are stored on disk.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Shared thumbnail generation + the on-disk location used to persist
/// thumbnails for transferred boxes (see [BoxSessionController.persistBoxThumbnails]
/// and `transferred_box_view_page.dart`). PNG (not JPEG) because `dart:ui`
/// only encodes PNG and the `image` package isn't a dependency — a follow-up
/// could switch to JPEG for ~3-5x smaller files.
abstract final class ThumbnailService {
  /// Decodes [file] and re-encodes it as a PNG thumbnail no wider than
  /// [targetWidth]. Returns null (never throws) on any read/decode failure.
  static Future<Uint8List?> buildPngThumbnail(
    File file, {
    int targetWidth = 512,
    int? targetHeight,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (e) {
      print('⚠️ Thumbnail generation failed for ${p.basename(file.path)}: $e');
      return null;
    }
  }

  /// `<appSupport>/box_thumbs/<deviceId>/box_<boxId>/` — created if missing.
  /// Persists past the box's full-resolution images being deleted at
  /// transfer (see `BoxSessionController.markTransferred`), so a transferred
  /// box can still be viewed read-only.
  static Future<Directory> boxThumbsDir(String deviceId, int boxId) async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'box_thumbs', deviceId, 'box_$boxId'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
