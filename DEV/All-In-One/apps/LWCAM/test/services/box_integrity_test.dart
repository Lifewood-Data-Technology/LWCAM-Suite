import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/box_integrity.dart';
import 'package:lwcam/services/image_name_mapping.dart';
import 'package:lwcam/services/orphan_image_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _dev = 'SAX04';
// A device filename with a parseable timestamp → base 'SAX04_IMG_20260720_100000'.
const _phoneName = 'PHONE_20260720_100000.jpg';
const _destName = 'SAX04_IMG_20260720_100000_001.jpg'; // recorded on transfer

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Future<File> _sourceImage() async {
  final dir = await _tempDir('bi_src_');
  final f = File(p.join(dir.path, _phoneName));
  await f.writeAsString('PIX');
  return f;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('cloud rework name maps back to the local thumbnail name', () {
    expect(
      localImageNameForCloudImage(_dev, _destName, const [
        _phoneName,
        'PHONE_20260720_100001.jpg',
      ]),
      _phoneName,
    );
    expect(
      localImageNameForCloudImage(_dev, 'unmatched.jpg', const [_phoneName]),
      'unmatched.jpg',
    );
  });

  test(
    'standard transfer names reverse without a cloud source-name column',
    () {
      expect(
        sourceImageNameFromCloudImage(
          _dev,
          'SAX04_IMG_20260720_100000_001.jpg',
        ),
        'IMG_20260720_100000.jpg',
      );
      expect(
        sourceImageNameFromCloudImage(_dev, 'SAX04_IMG_20260720_100000.jpg'),
        'IMG_20260720_100000.jpg',
      );
      expect(
        sourceImageNameFromCloudImage(_dev, 'IMG_20260720_100000.jpg'),
        'IMG_20260720_100000.jpg',
      );
      expect(sourceImageNameFromCloudImage(_dev, 'other.jpg'), isNull);
      expect(
        sourceImageNameFromCloudImage(
          _dev,
          'SAX99_IMG_20260720_100000_001.jpg',
        ),
        isNull,
      );
    },
  );

  late UploadStatsDB db;
  late OrphanImageStore store;
  late Directory boxImagesRoot;

  // Test double for the durable-store resolver (no path_provider in tests).
  Future<Directory> resolveBoxDir(String deviceId, int boxId) async {
    final dir = Directory(p.join(boxImagesRoot.path, deviceId, 'box_$boxId'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<int> heal() => healOrphanImages(
    db: db,
    store: store,
    deviceId: _dev,
    boxImagesDirResolver: resolveBoxDir,
  );

  setUp(() async {
    final base = await _tempDir('bi_db_');
    db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() => db.debugCloseAllForTests());
    // One STABLE orphan base per test — a fresh dir per call would make stash
    // and heal look in different places.
    final orphanBase = await _tempDir('bi_orphan_');
    store = OrphanImageStore(resolveBaseDir: () async => orphanBase);
    boxImagesRoot = await _tempDir('bi_boximages_');
  });

  CaptureFolder folderFor(int boxId) => CaptureFolder(
    boxId: boxId,
    coverTag: 'Cover Will Be Captured',
    title: 'WWI Medical Files',
    volume: 'V file no. 1',
    startDate: '1914',
    endDate: '1918',
  );

  group('healOrphanImages', () {
    test(
      'happy path: intent-known orphan is assigned, filed, and de-stashed',
      () async {
        final boxId = await db.insertCaptureBox(
          deviceId: _dev,
          boxDetails: 'BOX 1',
        );
        final folderId = await db.insertCaptureFolder(
          deviceId: _dev,
          folder: folderFor(boxId),
          isComplete: true,
        );
        await store.stash(
          source: await _sourceImage(),
          deviceId: _dev,
          deviceFilename: _phoneName,
          boxId: boxId,
          folderId: folderId,
          reason: 'db-error',
        );

        final healed = await heal();

        expect(healed, 1);
        final assignments = await db.getAssignmentsForBox(
          deviceId: _dev,
          boxId: boxId,
        );
        expect(assignments.containsKey(_phoneName), isTrue);
        expect(await store.list(_dev), isEmpty);
        final landed = File(
          p.join((await resolveBoxDir(_dev, boxId)).path, _phoneName),
        );
        expect(landed.existsSync(), isTrue);
      },
    );

    test('folder gone → demoted to intent-unknown', () async {
      final boxId = await db.insertCaptureBox(
        deviceId: _dev,
        boxDetails: 'BOX 1',
      );
      await store.stash(
        source: await _sourceImage(),
        deviceId: _dev,
        deviceFilename: _phoneName,
        boxId: boxId,
        folderId: 99999, // no such folder
        reason: 'db-error',
      );

      expect(await heal(), 0);
      final e = (await store.list(_dev)).single;
      expect(e.intentKnown, isFalse);
      expect(e.note, 'folder-missing');
    });

    test('box already transferred → demoted', () async {
      final boxId = await db.insertCaptureBox(
        deviceId: _dev,
        boxDetails: 'BOX 1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: _dev,
        folder: folderFor(boxId),
        isComplete: true,
      );
      await db.markCaptureBoxTransferred(deviceId: _dev, boxId: boxId);
      await store.stash(
        source: await _sourceImage(),
        deviceId: _dev,
        deviceFilename: _phoneName,
        boxId: boxId,
        folderId: folderId,
        reason: 'db-error',
      );

      expect(await heal(), 0);
      final e = (await store.list(_dev)).single;
      expect(e.intentKnown, isFalse);
      expect(e.note, 'box-transferred');
    });

    test(
      'already assigned to the intended box → duplicate discarded',
      () async {
        final boxId = await db.insertCaptureBox(
          deviceId: _dev,
          boxDetails: 'BOX 1',
        );
        final folderId = await db.insertCaptureFolder(
          deviceId: _dev,
          folder: folderFor(boxId),
          isComplete: true,
        );
        await db.assignImageToFolder(
          deviceId: _dev,
          boxId: boxId,
          folderId: folderId,
          deviceFilename: _phoneName,
        );
        await store.stash(
          source: await _sourceImage(),
          deviceId: _dev,
          deviceFilename: _phoneName,
          boxId: boxId,
          folderId: folderId,
          reason: 'db-error',
        );

        expect(await heal(), 0); // not a fresh assignment
        expect(await store.list(_dev), isEmpty); // duplicate stash dropped
        final landed = File(
          p.join((await resolveBoxDir(_dev, boxId)).path, _phoneName),
        );
        expect(landed.existsSync(), isTrue); // durable copy ensured
      },
    );

    test('already assigned to a DIFFERENT box → demoted (conflict)', () async {
      final boxA = await db.insertCaptureBox(
        deviceId: _dev,
        boxDetails: 'BOX A',
      );
      final folderA = await db.insertCaptureFolder(
        deviceId: _dev,
        folder: folderFor(boxA),
        isComplete: true,
      );
      await db.assignImageToFolder(
        deviceId: _dev,
        boxId: boxA,
        folderId: folderA,
        deviceFilename: _phoneName,
      );

      final boxB = await db.insertCaptureBox(
        deviceId: _dev,
        boxDetails: 'BOX B',
      );
      final folderB = await db.insertCaptureFolder(
        deviceId: _dev,
        folder: folderFor(boxB),
        isComplete: true,
      );
      await store.stash(
        source: await _sourceImage(),
        deviceId: _dev,
        deviceFilename: _phoneName,
        boxId: boxB,
        folderId: folderB,
        reason: 'db-error',
      );

      expect(await heal(), 0);
      final e = (await store.list(_dev)).single;
      expect(e.intentKnown, isFalse);
      expect(e.note, 'assigned-elsewhere');
    });

    test('intent-unknown entries are left untouched', () async {
      await store.stash(
        source: await _sourceImage(),
        deviceId: _dev,
        deviceFilename: _phoneName,
        reason: 'no-active-folder',
      ); // no boxId/folderId
      expect(await heal(), 0);
      expect(await store.list(_dev), hasLength(1));
    });
  });

  group('verifyBoxComplete', () {
    Future<int> boxWithAssignedImage() async {
      final boxId = await db.insertCaptureBox(
        deviceId: _dev,
        boxDetails: 'BOX 1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: _dev,
        folder: folderFor(boxId),
        isComplete: true,
      );
      await db.assignImageToFolder(
        deviceId: _dev,
        boxId: boxId,
        folderId: folderId,
        deviceFilename: _phoneName,
      );
      return boxId;
    }

    Future<String?> verify(int boxId) =>
        verifyBoxComplete(db: db, store: store, deviceId: _dev, boxId: boxId);

    test(
      'all assigned images recorded + no orphans → null (complete)',
      () async {
        final boxId = await boxWithAssignedImage();
        await db.insertUploadRecord(
          deviceId: _dev,
          scanningOpr: 'alice',
          boxDetails: 'BOX 1',
          filename: _destName,
          format: 'jpg',
          createdAt: DateTime(2026, 7, 20),
        );
        expect(await verify(boxId), isNull);
      },
    );

    test('an assigned image with no upload record → "not verified"', () async {
      final boxId = await boxWithAssignedImage();
      final issue = await verify(boxId);
      expect(issue, contains('1 image(s) not verified'));
    });

    test('an intent-known orphan targeting the box → "unresolved"', () async {
      final boxId = await boxWithAssignedImage();
      await db.insertUploadRecord(
        deviceId: _dev,
        scanningOpr: 'alice',
        boxDetails: 'BOX 1',
        filename: _destName,
        format: 'jpg',
        createdAt: DateTime(2026, 7, 20),
      );
      await store.stash(
        source: await _sourceImage(),
        deviceId: _dev,
        deviceFilename: 'OTHER_20260720_110000.jpg',
        boxId: boxId,
        folderId: 1,
        reason: 'db-error',
      );
      final issue = await verify(boxId);
      expect(issue, contains('1 unresolved image(s)'));
    });

    test('an orphan targeting a DIFFERENT box is ignored', () async {
      final boxId = await boxWithAssignedImage();
      await db.insertUploadRecord(
        deviceId: _dev,
        scanningOpr: 'alice',
        boxDetails: 'BOX 1',
        filename: _destName,
        format: 'jpg',
        createdAt: DateTime(2026, 7, 20),
      );
      await store.stash(
        source: await _sourceImage(),
        deviceId: _dev,
        deviceFilename: 'OTHER_20260720_110000.jpg',
        boxId: boxId + 777,
        folderId: 1,
        reason: 'db-error',
      );
      expect(await verify(boxId), isNull);
    });

    test('an assigned name with no parseable base is not flagged', () async {
      final boxId = await db.insertCaptureBox(
        deviceId: _dev,
        boxDetails: 'BOX 1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: _dev,
        folder: folderFor(boxId),
        isComplete: true,
      );
      await db.assignImageToFolder(
        deviceId: _dev,
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'no_timestamp.jpg',
      );
      expect(await verify(boxId), isNull);
    });
  });
}
