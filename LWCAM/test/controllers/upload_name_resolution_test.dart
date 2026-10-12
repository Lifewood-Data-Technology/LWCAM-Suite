import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/transfer_controller.dart';
import 'package:path/path.dart' as p;

/// TransferController.generateUniqueTargetFile is static and pure file I/O, so
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
    final f = await TransferController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: const {},
    );
    expect(p.basename(f.path), '${base}_001.jpg');
  });

  test('an on-disk file with NO DB record is never overwritten - the next '
      'suffix is taken', () async {
    await touch('${base}_001.jpg'); // another PC's image, or a torn old copy

    final f = await TransferController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: const {}, // nothing recorded here
    );
    expect(p.basename(f.path), '${base}_002.jpg');
    expect(await File(p.join(dir.path, '${base}_001.jpg')).readAsString(), 'x');
  });

  test('an on-disk file WITH a DB record keeps the original skip-to-next '
      'behavior', () async {
    await touch('${base}_001.jpg');

    final f = await TransferController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: {'${base}_001.jpg'},
    );
    expect(p.basename(f.path), '${base}_002.jpg');
  });

  test('recorded and unrecorded files both skip', () async {
    await touch('${base}_001.jpg');
    await touch('${base}_002.jpg');
    final f = await TransferController.generateUniqueTargetFile(
      dir, base, '.jpg',
      recordedFilenames: {'${base}_001.jpg'},
    );
    expect(p.basename(f.path), '${base}_003.jpg');
  });

  test('a reserved name is never returned', () async {
    await touch('${base}_001.jpg'); // orphan on disk...
    final reserved = {'${base}_001.jpg'}; // ...but claimed by this batch
    final f = await TransferController.generateUniqueTargetFile(
      dir, base, '.jpg',
      reservedNames: reserved,
      recordedFilenames: const {},
    );
    expect(p.basename(f.path), '${base}_002.jpg');
    expect(reserved, containsAll({'${base}_001.jpg', '${base}_002.jpg'}));
  });

  test('null recordedFilenames: on-disk always skips to the next suffix', () async {
    await touch('${base}_001.jpg');
    final f = await TransferController.generateUniqueTargetFile(
      dir, base, '.jpg',
    );
    expect(p.basename(f.path), '${base}_002.jpg');
  });
}
