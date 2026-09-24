import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/thumbnail_service.dart';
import 'package:path/path.dart' as p;

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

// A minimal valid 1x1 red-pixel PNG.
const _onePixelPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+P+/HgAFhAJ/wlseKgAAAABJRU5ErkJggg==';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider has no real platform implementation under `flutter test`
  // (no Windows plugin registered) — mock its channel so
  // getApplicationSupportDirectory() resolves to a real temp directory
  // instead of throwing MissingPluginException.
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDir;
  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('thumb_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return supportDir.path;
      return null;
    });
  });
  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  group('ThumbnailService.buildPngThumbnail', () {
    test('decodes a valid image and re-encodes it as PNG bytes', () async {
      final dir = await _tempDir('thumb_valid_');
      final file = File(p.join(dir.path, 'source.png'));
      await file.writeAsBytes(base64Decode(_onePixelPngBase64));

      final result = await ThumbnailService.buildPngThumbnail(file, targetWidth: 64);

      expect(result, isNotNull);
      expect(result!.isNotEmpty, isTrue);
      // PNG magic bytes.
      expect(result.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    });

    test('returns null (never throws) for a corrupt/unreadable image', () async {
      final dir = await _tempDir('thumb_corrupt_');
      final file = File(p.join(dir.path, 'not_an_image.jpg'));
      await file.writeAsBytes([1, 2, 3, 4, 5]);

      final result = await ThumbnailService.buildPngThumbnail(file);

      expect(result, isNull);
    });

    test('returns null for a file that does not exist', () async {
      final dir = await _tempDir('thumb_missing_');
      final file = File(p.join(dir.path, 'missing.jpg'));

      final result = await ThumbnailService.buildPngThumbnail(file);

      expect(result, isNull);
    });
  });

  group('ThumbnailService.boxThumbsDir', () {
    test('returns a device+box scoped path and creates it if missing', () async {
      final dir = await ThumbnailService.boxThumbsDir('SAX01', 42);
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });

      expect(await dir.exists(), isTrue);
      expect(p.basename(dir.path), 'box_42');
      expect(p.basename(dir.parent.path), 'SAX01');
      expect(p.basename(dir.parent.parent.path), 'box_thumbs');
    });

    test('is idempotent when called again for the same device/box', () async {
      final first = await ThumbnailService.boxThumbsDir('SAX02', 7);
      addTearDown(() async {
        if (await first.exists()) await first.delete(recursive: true);
      });
      final second = await ThumbnailService.boxThumbsDir('SAX02', 7);

      expect(second.path, first.path);
      expect(await second.exists(), isTrue);
    });
  });
}
