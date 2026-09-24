import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/orphan_image_store.dart';
import 'package:path/path.dart' as p;

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

/// A source image the store will COPY from — lives in its own dir so tests can
/// assert the source survives a stash.
Future<File> _sourceImage(String name, {String bytes = 'IMGDATA'}) async {
  final dir = await _tempDir('orphan_src_');
  final f = File(p.join(dir.path, name));
  await f.writeAsString(bytes);
  return f;
}

OrphanImageStore _store(Directory base) =>
    OrphanImageStore(resolveBaseDir: () async => base);

void main() {
  group('retrying', () {
    test('returns the first success without retrying', () async {
      var calls = 0;
      final r = await retrying(() async {
        calls++;
        return 'ok';
      });
      expect(r, 'ok');
      expect(calls, 1);
    });

    test('succeeds on the 3rd attempt after two throws', () async {
      var calls = 0;
      final r = await retrying(() async {
        calls++;
        if (calls < 3) throw StateError('locked');
        return calls;
      }, delays: const [Duration.zero, Duration.zero]);
      expect(r, 3);
      expect(calls, 3);
    });

    test('rethrows after exhausting attempts', () async {
      var calls = 0;
      await expectLater(
        retrying(() async {
          calls++;
          throw StateError('always');
        }, delays: const [Duration.zero, Duration.zero]),
        throwsStateError,
      );
      expect(calls, 3); // 1 + 2 retries
    });

    test('does NOT retry a false return (a result, not an error)', () async {
      var calls = 0;
      final r = await retrying<bool>(() async {
        calls++;
        return false;
      });
      expect(r, isFalse);
      expect(calls, 1);
    });
  });

  group('OrphanImageStore', () {
    test('stash copies the source (source survives) + sidecar round-trips', () async {
      final base = await _tempDir('orphan_store_');
      final store = _store(base);
      final src = await _sourceImage('IMG_1.jpg');

      final entry = await store.stash(
        source: src,
        deviceId: 'SAX04',
        deviceFilename: 'IMG_1.jpg',
        boxId: 7,
        folderId: 3,
        reason: 'db-error: boom',
        stashedAt: DateTime(2026, 7, 20, 10),
      );

      expect(entry, isNotNull);
      expect(await src.exists(), isTrue, reason: 'stash must COPY, not move');
      expect(await entry!.file.exists(), isTrue);
      expect(entry.intentKnown, isTrue);

      final reread = (await store.list('SAX04')).single;
      expect(reread.deviceFilename, 'IMG_1.jpg');
      expect(reread.boxId, 7);
      expect(reread.folderId, 3);
      expect(reread.reason, 'db-error: boom');
      expect(reread.stashedAt, DateTime(2026, 7, 20, 10));
      expect(reread.intentKnown, isTrue);
    });

    test('no boxId → intent unknown', () async {
      final base = await _tempDir('orphan_store_');
      final store = _store(base);
      await store.stash(
        source: await _sourceImage('IMG_2.jpg'),
        deviceId: 'SAX04',
        deviceFilename: 'IMG_2.jpg',
        reason: 'no-active-folder',
      );
      final e = (await store.list('SAX04')).single;
      expect(e.intentKnown, isFalse);
      expect(e.boxId, isNull);
    });

    test('collision uniquifies the stored name; sidecar keeps the real name', () async {
      final base = await _tempDir('orphan_store_');
      final store = _store(base);
      await store.stash(
          source: await _sourceImage('IMG_3.jpg', bytes: 'A'),
          deviceId: 'SAX04',
          deviceFilename: 'IMG_3.jpg',
          reason: 'r1');
      await store.stash(
          source: await _sourceImage('IMG_3.jpg', bytes: 'B'),
          deviceId: 'SAX04',
          deviceFilename: 'IMG_3.jpg',
          reason: 'r2');

      final entries = await store.list('SAX04');
      expect(entries, hasLength(2));
      // Both carry the true device filename regardless of stored basename.
      expect(entries.every((e) => e.deviceFilename == 'IMG_3.jpg'), isTrue);
      // On disk the stored names differ (one got a ~2 suffix).
      final storedNames = entries.map((e) => p.basename(e.file.path)).toSet();
      expect(storedNames, hasLength(2));
    });

    test('an image file with no sidecar lists as intent-unknown', () async {
      final base = await _tempDir('orphan_store_');
      final devDir = Directory(p.join(base.path, 'SAX04'))..createSync(recursive: true);
      await File(p.join(devDir.path, 'loose.jpg')).writeAsString('x');
      final e = (await _store(base).list('SAX04')).single;
      expect(e.intentKnown, isFalse);
      expect(e.deviceFilename, 'loose.jpg');
    });

    test('demoteToUnknown drops intent, keeps a note', () async {
      final base = await _tempDir('orphan_store_');
      final store = _store(base);
      final entry = await store.stash(
          source: await _sourceImage('IMG_4.jpg'),
          deviceId: 'SAX04',
          deviceFilename: 'IMG_4.jpg',
          boxId: 5,
          folderId: 2,
          reason: 'db-error');
      await store.demoteToUnknown(entry!, note: 'folder-missing');
      final e = (await store.list('SAX04')).single;
      expect(e.intentKnown, isFalse);
      expect(e.note, 'folder-missing');
    });

    test('discard removes both file and sidecar', () async {
      final base = await _tempDir('orphan_store_');
      final store = _store(base);
      final entry = await store.stash(
          source: await _sourceImage('IMG_5.jpg'),
          deviceId: 'SAX04',
          deviceFilename: 'IMG_5.jpg',
          boxId: 1,
          folderId: 1,
          reason: 'r');
      await store.discard(entry!);
      expect(await store.list('SAX04'), isEmpty);
      expect(entry.file.existsSync(), isFalse);
      expect(entry.sidecar!.existsSync(), isFalse);
    });

    test('resolveInto lands the file under its deviceFilename and empties the stash',
        () async {
      final base = await _tempDir('orphan_store_');
      final target = await _tempDir('orphan_target_');
      final store = _store(base);
      final entry = await store.stash(
          source: await _sourceImage('IMG_6.jpg', bytes: 'PIX'),
          deviceId: 'SAX04',
          deviceFilename: 'IMG_6.jpg',
          boxId: 1,
          folderId: 1,
          reason: 'r');

      final landed = await store.resolveInto(entry!, target);
      expect(p.basename(landed.path), 'IMG_6.jpg');
      expect(await landed.readAsString(), 'PIX');
      expect(await store.list('SAX04'), isEmpty);
    });

    test('listAll spans every device subdir', () async {
      final base = await _tempDir('orphan_store_');
      final store = _store(base);
      await store.stash(
          source: await _sourceImage('A.jpg'),
          deviceId: 'SAX01',
          deviceFilename: 'A.jpg',
          reason: 'r');
      await store.stash(
          source: await _sourceImage('B.jpg'),
          deviceId: 'SAX02',
          deviceFilename: 'B.jpg',
          reason: 'r');
      final all = await store.listAll();
      expect(all.map((e) => e.deviceId).toSet(), {'SAX01', 'SAX02'});
    });
  });
}
