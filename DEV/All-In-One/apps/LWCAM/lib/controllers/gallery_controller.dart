// ignore_for_file: avoid_print

import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../services/thumbnail_service.dart';

/// Each entry holds the real image file + its thumbnail
class ImageEntry {
  final File file;
  final Uint8List? thumb;
  ImageEntry(this.file, this.thumb);
}

class GalleryController extends GetxController {
  /// Identifies the box/device currently represented by [groupedImages].
  String? galleryScope;

  /// Session-lifetime thumbnail cache. Reopening a box otherwise re-reads
  /// (~13MB each) and re-decodes EVERY image — slow for 1k+ galleries. This
  /// controller is registered permanent, so the cache survives the gallery
  /// page being disposed and rebuilt. Keyed by "name:byteLength" so a swap
  /// recapture (same filename, different bytes ⇒ different length) misses
  /// and re-decodes correctly. LRU via LinkedHashMap access-reordering,
  /// capped so a long multi-box session can't grow it without bound.
  final LinkedHashMap<String, Uint8List> _thumbCache =
      LinkedHashMap<String, Uint8List>();
  static const int _thumbCacheMaxEntries = 1500;

  /// Returns [file]'s 512px thumbnail bytes, reusing a cached instance when
  /// the same (name, byte-length) was decoded earlier this session. Returns
  /// the SAME [Uint8List] instance on a hit, so Flutter's own MemoryImage
  /// cache (keyed by object identity) also hits and skips re-decoding at
  /// paint time. [bypassCache] for replacement slots, whose bytes can change
  /// under a stable filename (mirrors the file-reuse rule in
  /// gallery_page's loadDcimImages).
  Future<Uint8List?> thumbnailFor(
    File file, {
    bool bypassCache = false,
    int targetWidth = 512,
    int? targetHeight,
  }) async {
    final name = p.basename(file.path);
    int length = -1;
    try {
      length = await file.length();
    } catch (_) {}

    final canCache = !bypassCache && length > 0;
    final key = '$name:$length';
    if (canCache) {
      final hit = _thumbCache.remove(key);
      if (hit != null) {
        _thumbCache[key] = hit; // move to most-recently-used
        return hit;
      }
    }

    final bytes = await ThumbnailService.buildPngThumbnail(
      file,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    if (bytes != null && canCache) {
      _thumbCache[key] = bytes;
      while (_thumbCache.length > _thumbCacheMaxEntries) {
        _thumbCache.remove(_thumbCache.keys.first); // evict least-recent
      }
    }
    return bytes;
  }

  final selectedImages = <File>[].obs;

  /// Right-side preview panel state
  final Rxn<File> previewFile = Rxn<File>();

  /// key: date group, value: list of ImageEntry (with thumb + file)
  final groupedImages = <String, List<ImageEntry>>{}.obs;

  final isLoading = false.obs;

  /// Used by `gallery_page.dart` when pulling images via ADB
  void addThumbnail(
    String key,
    File file,
    Uint8List? thumb, {
    bool refresh = true,
  }) {
    groupedImages.putIfAbsent(key, () => []);
    groupedImages[key]!.add(ImageEntry(file, thumb));
    if (refresh) {
      groupedImages.refresh();
    }
  }

  void toggleSelection(File file) {
    if (selectedImages.contains(file)) {
      selectedImages.remove(file);
    } else {
      selectedImages.add(file);
    }
  }

  void setPreview(File? file) {
    previewFile.value = file;
  }

  /// Clear all selection
  void clearSelection() {
    selectedImages.clear();
  }
}
