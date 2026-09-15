import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/upload_contoller.dart';
import 'package:path/path.dart' as p;

/// UploadController.generateUniqueTargetFile is static and pure file I/O, so
/// it's driven directly against a temp dir — no GetX bootstrap needed.
void main() {
  late Directory dir;
  const base = 'SAX01_IMG_20260720_100000';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('name_resolution_');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<void> touch(String name) =>
      File(p.join(dir.path, name)).writeAsString('x');

  test('empty destination allocates _001', () async {
    final f = await UploadController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: const {},
    );
    expect(p.basename(f.path), '${base}_001.jpg');
  });

  test('an on-disk file with NO DB record is an orphan — returned for '
      'overwrite instead of suffix-skipped', () async {
    await touch('${base}_001.jpg'); // partial left by an interrupted run

    final f = await UploadController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: const {}, // nothing recorded ⇒ _001 is an orphan
    );
    expect(p.basename(f.path), '${base}_001.jpg');
  });

  test('an on-disk file WITH a DB record keeps the original skip-to-next '
      'behavior', () async {
    await touch('${base}_001.jpg');

    final f = await UploadController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: {'${base}_001.jpg'},
    );
    expect(p.basename(f.path), '${base}_002.jpg');
  });

  test('recorded files skip, the first orphan after them is taken', () async {
    await touch('${base}_001.jpg'); // recorded — completed earlier batch
    await touch('${base}_002.jpg'); // orphan — died mid-copy
    final f = await UploadController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: {'${base}_001.jpg'},
    );
    expect(p.basename(f.path), '${base}_002.jpg');
  });

  test('a reserved name is never returned, even as an orphan', () async {
    await touch('${base}_001.jpg'); // orphan on disk...
    final reserved = {'${base}_001.jpg'}; // ...but claimed by this batch
    final f = await UploadController.generateUniqueTargetFile(
      dir, base, '.jpg',
      reservedNames: reserved,
      recordedFilenames: const {},
    );
    expect(p.basename(f.path), '${base}_002.jpg');
    expect(reserved, containsAll({'${base}_001.jpg', '${base}_002.jpg'}));
  });

  test('null recordedFilenames disables the orphan check (original '
      'behavior: on-disk always skips to the next suffix)', () async {
    await touch('${base}_001.jpg');
    final f = await UploadController.generateUniqueTargetFile(
      dir, base, '.jpg',
    );
    expect(p.basename(f.path), '${base}_002.jpg');
  });
}
