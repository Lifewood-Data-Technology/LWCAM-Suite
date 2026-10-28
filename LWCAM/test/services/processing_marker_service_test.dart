import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/processing_marker_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

CaptureFolder _folder(int boxId) => CaptureFolder(
  boxId: boxId,
  coverTag: 'Cover',
  title: 'T',
  volume: 'V file no. 1',
  startDate: '1914',
  endDate: '1918',
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<UploadStatsDB> freshDb(String prefix) async {
    final base = await _tempDir(prefix);
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() {
      return db.debugCloseAllForTests();
    });
    return db;
  }

  group('buildFolderMarkerPayload', () {
    test('carries the box natural keys + folder identity', () {
      final payload = buildFolderMarkerPayload(
        boxKeys: {
          'project_key': 'pabc',
          'project_id': 'PRJ-1',
          'box_name': 'BOX-1',
          'renamed_from': null,
          'device_id': 'SAX01',
        },
        folderSeq: 3,
        folderName: 'BOX-1 - 4471 - 0001',
        now: DateTime(2026, 7, 22),
      );
      expect(payload['version'], 1);
      expect(payload['project_key'], 'pabc');
      expect(payload['project_id'], 'PRJ-1');
      expect(payload['box_name'], 'BOX-1');
      expect(payload['device_id'], 'SAX01');
      expect(payload['folder_seq'], 3);
      expect(payload['folder_name'], 'BOX-1 - 4471 - 0001');
      expect(payload['created_at'], startsWith('2026-07-22'));
    });
  });

  test('reworkReadinessHeld reads the marker and fails closed on damage',
      () async {
    final dir = await _tempDir('marker_readiness_');
    expect(await reworkReadinessHeld(dir.path), isFalse);
    final marker = File(p.join(dir.path, kProcessingMarkerName));
    await marker.writeAsString(jsonEncode({'rework_in_progress': true}));
    expect(await reworkReadinessHeld(dir.path), isTrue);
    await marker.writeAsString(jsonEncode({'rework_in_progress': false}));
    expect(await reworkReadinessHeld(dir.path), isFalse);
    await marker.writeAsString('broken');
    await expectLater(reworkReadinessHeld(dir.path), throwsStateError);
  });

  group('writeBoxProcessingMarkers', () {
    Future<(UploadStatsDB, int)> boxWithFolders(
      String prefix,
      List<String> names,
    ) async {
      final db = await freshDb(prefix);
      final boxId = await db.insertCaptureBox(
        deviceId: 'SAX01',
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
        projectKey: 'pabc',
      );
      for (final name in names) {
        final id = await db.insertCaptureFolder(
          deviceId: 'SAX01',
          folder: _folder(boxId),
          isComplete: true,
        );
        await db.updateCaptureFolderName(
          deviceId: 'SAX01',
          folderId: id,
          folderName: name,
        );
      }
      return (db, boxId);
    }

    test('writes only into the box\'s persisted day dir — a same-named '
        'folder under another day dir is not the box\'s and gets no marker',
        () async {
      final (db, boxId) = await boxWithFolders('marker_', ['F-ONE', 'F-TWO']);
      final root = await _tempDir('marker_dest_');
      final dest = await db.markCaptureBoxTransferStarted(
        deviceId: 'SAX01',
        boxId: boxId,
        destinationRoot: root.path,
      );
      Directory(p.join(dest, 'F-ONE')).createSync(recursive: true);
      Directory(p.join(dest, 'F-TWO')).createSync(recursive: true);
      // Another box / another PC / an older split retry: same NAME, other day.
      final decoy = Directory(p.join(root.path, '20990101', 'F-ONE'))
        ..createSync(recursive: true);

      final result = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(result.isSuccess, isTrue);
      expect(result.writtenMarkers, 2);
      expect(result.failedWrites, 0);

      final m1 = File(p.join(dest, 'F-ONE', kProcessingMarkerName));
      expect(m1.existsSync(), isTrue);
      expect(
        File(p.join(dest, 'F-TWO', kProcessingMarkerName)).existsSync(),
        isTrue,
      );
      expect(File(p.join(decoy.path, kProcessingMarkerName)).existsSync(),
          isFalse);

      final payload = jsonDecode(m1.readAsStringSync()) as Map;
      expect(payload['project_key'], 'pabc');
      expect(payload['box_name'], 'BOX-1');
      expect(payload['folder_name'], 'F-ONE');
      expect(payload['folder_seq'], isNotNull);
      expect(payload['image_count'], 0, reason: 'no images in this folder');
      expect(
        Directory(p.join(dest, 'F-ONE'))
            .listSync()
            .map((e) => p.basename(e.path))
            .toList(),
        [kProcessingMarkerName],
        reason: 'no temp file left behind',
      );

      // Idempotent rewrite (the retry path re-runs markTransferred).
      expect(
        (await writeBoxProcessingMarkers(
          db: db,
          deviceId: 'SAX01',
          boxId: boxId,
          legacyRoot: root.path,
        )).isSuccess,
        isTrue,
      );
      expect(m1.existsSync(), isTrue);
    });

    test('image_count counts only image files LWIP would read', () async {
      final (db, boxId) = await boxWithFolders('marker_count_', ['F-ONE']);
      final root = await _tempDir('marker_count_dest_');
      final dest = await db.markCaptureBoxTransferStarted(
        deviceId: 'SAX01',
        boxId: boxId,
        destinationRoot: root.path,
      );
      final folder = Directory(p.join(dest, 'F-ONE'))..createSync(recursive: true);
      for (final n in ['a.jpg', 'b.JPG', 'c.tif', 'd.jpg.part', 'e.json', 'f.txt']) {
        File(p.join(folder.path, n)).writeAsStringSync('x');
      }
      final result = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(result.isSuccess, isTrue);
      final payload = jsonDecode(
        File(p.join(folder.path, kProcessingMarkerName)).readAsStringSync(),
      ) as Map;
      expect(payload['image_count'], 3);
    });

    test('refuses to overwrite a marker carrying another folder\'s identity '
        '(two PCs, one NAS, same day, same Volume)', () async {
      final (db, boxId) = await boxWithFolders('marker_foreign_', ['F-ONE']);
      final root = await _tempDir('marker_foreign_dest_');
      final dest = await db.markCaptureBoxTransferStarted(
        deviceId: 'SAX01',
        boxId: boxId,
        destinationRoot: root.path,
      );
      final marker = File(p.join(dest, 'F-ONE', kProcessingMarkerName))
        ..createSync(recursive: true);
      final foreign = jsonEncode(buildFolderMarkerPayload(
        boxKeys: {
          'project_key': 'pabc',
          'project_id': 'PRJ-1',
          'box_name': 'BOX-OTHER-PC',
          'device_id': 'SAX02',
        },
        folderSeq: 1,
        folderName: 'F-ONE',
      ));
      marker.writeAsStringSync(foreign);

      final result = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(result.isSuccess, isFalse);
      expect(result.failedWrites, 1);
      expect(result.writtenMarkers, 0);
      expect(marker.readAsStringSync(), foreign); // untouched
    });

    test('legacy: a box copied before the day dir was persisted falls back '
        'to scanning the root\'s day dirs by folder name', () async {
      final (db, boxId) = await boxWithFolders('marker_legacy_', ['F-ONE']);
      final root = await _tempDir('marker_legacy_dest_');
      // Older builds wrote the bare root on success only.
      await db.markCaptureBoxTransferred(
        deviceId: 'SAX01',
        boxId: boxId,
        transferredTo: root.path,
      );
      Directory(p.join(root.path, '20260722', 'F-ONE'))
          .createSync(recursive: true);
      Directory(p.join(root.path, 'logs')).createSync(recursive: true);

      final result = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(result.isSuccess, isTrue);
      expect(result.writtenMarkers, 1);
      expect(
        File(p.join(root.path, '20260722', 'F-ONE', kProcessingMarkerName))
            .existsSync(),
        isTrue,
      );
      expect(Directory(p.join(root.path, 'logs')).listSync(), isEmpty);
    });

    test('missing folder dirs and blank destinations stay retryable', () async {
      final (db, boxId) = await boxWithFolders('marker_skip_', ['GHOST']);
      final root = await _tempDir('marker_skip_dest_');
      final dest = await db.markCaptureBoxTransferStarted(
        deviceId: 'SAX01',
        boxId: boxId,
        destinationRoot: root.path,
      );
      Directory(dest).createSync(recursive: true); // no GHOST subdir
      final missing = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(missing.isSuccess, isFalse);
      expect(missing.missingFolders, 1);
      expect(
        File(p.join(dest, 'GHOST', kProcessingMarkerName)).existsSync(),
        isFalse,
      );

      // No persisted day dir AND no root to fall back to.
      final boxId2 = await db.insertCaptureBox(
        deviceId: 'SAX01',
        boxDetails: 'BOX-2',
        projectKey: 'pabc',
      );
      final f = await db.insertCaptureFolder(
        deviceId: 'SAX01',
        folder: _folder(boxId2),
        isComplete: true,
      );
      await db.updateCaptureFolderName(
        deviceId: 'SAX01',
        folderId: f,
        folderName: 'GHOST',
      );
      final blank = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId2,
        legacyRoot: '   ',
      );
      expect(blank.isSuccess, isFalse);
      expect(blank.failedWrites, 1);
    });

    test('a recovered unbound page names the cause and can be accepted',
        () async {
      final (db, boxId) = await boxWithFolders('marker_colour_', ['F-ONE']);
      final folders = await db.getCaptureFolders(
        deviceId: 'SAX01',
        boxId: boxId,
      );
      final folderId = folders.single.id;
      await db.assignImageToFolder(
        deviceId: 'SAX01',
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'a.jpg',
      );
      final root = await _tempDir('marker_colour_dest_');
      final dest = await db.markCaptureBoxTransferStarted(
        deviceId: 'SAX01',
        boxId: boxId,
        destinationRoot: root.path,
      );
      final folderDir = Directory(p.join(dest, 'F-ONE'))
        ..createSync(recursive: true);
      File(p.join(folderDir.path, 'a.jpg')).writeAsBytesSync([1, 2, 3]);
      final raw = await db.getDatabase('SAX01');
      await raw.delete('color_bindings');
      await raw.insert('color_integrity', {
        'id': 1,
        'reason': 'damaged ledger',
      });

      final blocked = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(blocked.failedWrites, 1);
      expect(blocked.folderFailures.single, contains('damaged ledger'));
      expect(
        File(p.join(folderDir.path, kProcessingMarkerName)).existsSync(),
        isFalse,
      );

      await db.bindHistoricalIfUnbound('SAX01', folderId);
      final accepted = await writeBoxProcessingMarkers(
        db: db,
        deviceId: 'SAX01',
        boxId: boxId,
        legacyRoot: root.path,
      );
      expect(accepted.isSuccess, isTrue);
      final marker = jsonDecode(
        File(p.join(folderDir.path, kProcessingMarkerName)).readAsStringSync(),
      ) as Map;
      expect(
        (marker['color_calibration'] as Map)['images']['a.jpg']['reason'],
        'historical',
      );
    });
  });
}
