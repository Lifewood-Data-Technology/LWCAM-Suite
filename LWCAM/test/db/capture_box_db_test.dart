import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/models/metadata_template.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Mandatory-field completeness is template-driven (metadata_template.dart);
// these DB-layer tests use the built-in standard template, which reproduces
// the old spec §8.1 rules exactly.
final _standardTemplate = MetadataTemplate.standard();

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

CaptureFolder _folder(int boxId, {String? volume = 'V file no. 1'}) {
  return CaptureFolder(
    boxId: boxId,
    coverTag: 'Cover Will Be Captured',
    title: 'WWI Medical Files',
    volume: volume,
    startDate: '1914',
    endDate: '1918',
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<UploadStatsDB> freshDb(String prefix) async {
    final base = await _tempDir(prefix);
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() => db.debugCloseAllForTests());
    return db;
  }

  group('schema', () {
    test('fresh device DB has the three capture-box tables + template_json/project_key/record_type',
        () async {
      final db = await freshDb('cap_fresh_');
      final database = await db.getDatabase('devA');
      final tables = (await database
              .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
          .map((r) => r['name'] as String)
          .toSet();
      expect(tables,
          containsAll(['capture_boxes', 'capture_folders', 'capture_images']));
      // v2 added the stable-schema migration (_migrateStableSchemaV2); a fresh
      // onCreate still lands directly on the current version.
      expect(await database.getVersion(), 2);
      // Cloud-mirroring columns (LWCam_database_20260720.sql) + local-only.
      final boxColumns = (await database.rawQuery('PRAGMA table_info(capture_boxes)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(
          boxColumns,
          containsAll([
            'box_name', 'user_id', 'project_id', 'updated_at',
            'transfer_start_at', 'transfer_end_at', 'transferred_to',
            'renamed_from', 'project_key', 'template_json', //
          ]));
      final folderColumns = (await database.rawQuery('PRAGMA table_info(capture_folders)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(
          folderColumns,
          containsAll([
            'record_type', 'place', 'language', 'record_custodian',
            'capture_operator_id', 'capture_operator_name',
            'digitizing_entity', 'source_created_at', 'source_updated_at', //
          ]));
      final imageColumns = (await database.rawQuery('PRAGMA table_info(capture_images)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(
          imageColumns,
          containsAll([
            'image_name', 'device_id', 'folder_id', 'file_format',
            'image_created_at', 'image_updated_at', 'box_id', //
          ]));
      final uploadColumns = (await database.rawQuery('PRAGMA table_info(upload_records)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(
          uploadColumns,
          containsAll([
            'place',
            'language',
            'record_custodian',
            'digitizing_entity',
            'capture_operator_id',
            'capture_operator_name',
          ]));
    });
  });

  group('boxes', () {
    test('insert/get/markTransferred round-trip with ordering', () async {
      final db = await freshDb('cap_box_');
      final id1 = await db.insertCaptureBox(
          deviceId: 'devA', boxDetails: 'BOX 1', scanningOpr: 'alice');
      final id2 = await db.insertCaptureBox(
          deviceId: 'devA', boxDetails: 'BOX 2', scanningOpr: 'alice');
      await db.markCaptureBoxTransferred(deviceId: 'devA', boxId: id1);

      final boxes = await db.getCaptureBoxes('devA');
      expect(boxes.length, 2);
      // Open boxes first.
      expect(boxes.first.id, id2);
      expect(boxes.first.isTransferred, isFalse);
      expect(boxes.last.id, id1);
      expect(boxes.last.isTransferred, isTrue);
      expect(boxes.last.transferredAt, isNotNull);

      final byId = await db.getCaptureBoxById(deviceId: 'devA', boxId: id1);
      expect(byId!.boxDetails, 'BOX 1');
    });

    test('updateCaptureBoxDetails renames the box', () async {
      final db = await freshDb('cap_rename_');
      final id = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'WRONG NAME');
      await db.updateCaptureBoxDetails(
          deviceId: 'devA', boxId: id, boxDetails: 'CORRECT 9095 231429-231448');
      final box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.boxDetails, 'CORRECT 9095 231429-231448');
    });

    test('insertCaptureBox(projectKey:) round-trips through CaptureBox.fromDbMap', () async {
      final db = await freshDb('cap_project_');
      final id = await db.insertCaptureBox(
          deviceId: 'devA', boxDetails: 'BOX 1', projectKey: 'p123');
      final box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.projectKey, 'p123');
    });

    test('insertCaptureBox(templateJson:) round-trips through CaptureBox.fromDbMap', () async {
      final db = await freshDb('cap_template_');
      final templateJson = '{"version":1,"fields":[]}';
      final id = await db.insertCaptureBox(
          deviceId: 'devA', boxDetails: 'BOX 1', templateJson: templateJson);
      final box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.templateJson, templateJson);

      // A legacy box created without a snapshot round-trips to null.
      final legacyId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'BOX 2');
      final legacyBox = await db.getCaptureBoxById(deviceId: 'devA', boxId: legacyId);
      expect(legacyBox!.templateJson, isNull);
    });

    test('setBoxTransferState round-trips through CaptureBox.fromDbMap and '
        'is cleared by markCaptureBoxTransferred', () async {
      final db = await freshDb('cap_transfer_state_');
      final id = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'BOX 1');

      // Fresh box: no transfer attempted yet.
      var box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.lastTransferState, isNull);
      expect(box.lastTransferError, isNull);

      await db.setBoxTransferState(
          deviceId: 'devA', boxId: id, state: 'failed', error: 'NAS unreachable');
      box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.lastTransferState, 'failed');
      expect(box.lastTransferError, 'NAS unreachable');

      // A later run persists 'running'; a full success then clears the slate.
      await db.setBoxTransferState(deviceId: 'devA', boxId: id, state: 'running');
      await db.markCaptureBoxTransferred(deviceId: 'devA', boxId: id);
      box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.isTransferred, isTrue);
      expect(box.lastTransferState, isNull);
      expect(box.lastTransferError, isNull);
    });

    test('setBoxTransferState(state: null) clears an earlier marker', () async {
      final db = await freshDb('cap_transfer_state_clear_');
      final id = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'BOX 1');
      await db.setBoxTransferState(
          deviceId: 'devA', boxId: id, state: 'partial', error: 'Transferred 3/10.');
      await db.setBoxTransferState(deviceId: 'devA', boxId: id, state: null);
      final box = await db.getCaptureBoxById(deviceId: 'devA', boxId: id);
      expect(box!.lastTransferState, isNull);
      expect(box.lastTransferError, isNull);
    });

    test('getCaptureBoxes(projectKey:) filters per project; null returns all', () async {
      final db = await freshDb('cap_project_filter_');
      await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'A1', projectKey: 'p1');
      await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'A2', projectKey: 'p1');
      await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B1', projectKey: 'p2');
      await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'Legacy'); // no project

      final p1Boxes = await db.getCaptureBoxes('devA', projectKey: 'p1');
      expect(p1Boxes.map((b) => b.boxDetails).toSet(), {'A1', 'A2'});

      final p2Boxes = await db.getCaptureBoxes('devA', projectKey: 'p2');
      expect(p2Boxes.map((b) => b.boxDetails).toSet(), {'B1'});

      // Legacy NULL-key boxes never match a project filter.
      expect(p1Boxes.any((b) => b.boxDetails == 'Legacy'), isFalse);

      final all = await db.getCaptureBoxes('devA');
      expect(all.map((b) => b.boxDetails).toSet(), {'A1', 'A2', 'B1', 'Legacy'});
    });
  });

  group('folders', () {
    test('folder_seq allocates 1..N in creation order', () async {
      final db = await freshDb('cap_seq_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);
      await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId, volume: 'V file no. 2'), isComplete: true);
      await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId, volume: 'V file no. 3'), isComplete: true);

      final folders = await db.getCaptureFolders(deviceId: 'devA', boxId: boxId);
      expect(folders.map((f) => f.folderSeq), [1, 2, 3]);
      expect(folders.map((f) => f.volume), ['V file no. 1', 'V file no. 2', 'V file no. 3']);
      expect(folders.every((f) => _standardTemplate.isCompleteOf(f)), isTrue);
    });

    test('updateCaptureFolderMetadata rewrites fields + is_complete', () async {
      final db = await freshDb('cap_upd_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final fid = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);

      final loaded = (await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)).single;
      // Blank a mandatory field → draft.
      final draftFolder = CaptureFolder(id: fid, boxId: boxId, volume: loaded.volume);
      await db.updateCaptureFolderMetadata(
        deviceId: 'devA',
        folder: draftFolder,
        isComplete: _standardTemplate.isCompleteOf(draftFolder),
      );
      final draft = (await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)).single;
      expect(_standardTemplate.isCompleteOf(draft), isFalse);
      expect(_standardTemplate.missingMandatoryFieldsOf(draft), isNot(contains('Volume')));
    });

    // Record Type is the eighth keyed field. insertCaptureFolder writes it
    // (via toDbMap) but updateCaptureFolderMetadata listed its columns by hand
    // and left it out, so a template that makes Record Type an editable
    // dropdown lost the operator's choice the moment they re-saved the folder.
    // It only surfaced in the export, which is the worst place to find it.
    test('updateCaptureFolderMetadata persists a keyed Record Type', () async {
      final db = await freshDb('cap_rt_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final fid = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);

      final loaded = (await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)).single;
      await db.updateCaptureFolderMetadata(
        deviceId: 'devA',
        folder: CaptureFolder(
          id: fid,
          boxId: boxId,
          volume: loaded.volume,
          title: loaded.title,
          recordType: 'Parish Register',
        ),
        isComplete: true,
      );
      final reloaded = (await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)).single;
      expect(reloaded.recordType, 'Parish Register');
    });

    // Transfer prep used to overwrite the Volume with an "(unknown file [n])"
    // placeholder, so the stored value could differ from what was keyed. The
    // Volume is the operator's text and prep must not touch it.
    test('updateCaptureFolderName persists the name and leaves Volume alone',
        () async {
      final db = await freshDb('cap_name_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final fid = await db.insertCaptureFolder(
          deviceId: 'devA',
          folder: _folder(boxId, volume: 'Register 12'),
          isComplete: true);
      await db.updateCaptureFolderName(
        deviceId: 'devA',
        folderId: fid,
        folderName: 'Register 12',
      );
      final f = (await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)).single;
      expect(f.folderName, 'Register 12');
      expect(f.volume, 'Register 12');
    });

    test('deleteCaptureFolder refuses when images are assigned', () async {
      final db = await freshDb('cap_del_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final fid = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);
      await db.assignImageToFolder(
          deviceId: 'devA', boxId: boxId, folderId: fid, deviceFilename: 'IMG_1.jpg');

      expect(await db.deleteCaptureFolder(deviceId: 'devA', folderId: fid), isFalse);
      expect((await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)), hasLength(1));

      await db.unassignImage(deviceId: 'devA', deviceFilename: 'IMG_1.jpg');
      expect(await db.deleteCaptureFolder(deviceId: 'devA', folderId: fid), isTrue);
      expect((await db.getCaptureFolders(deviceId: 'devA', boxId: boxId)), isEmpty);
    });

    test('deleteCaptureBox refuses while any image is assigned, then removes box + folders',
        () async {
      final db = await freshDb('cap_delbox_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final f1 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);
      await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId, volume: 'V file no. 2'), isComplete: false);
      await db.assignImageToFolder(
          deviceId: 'devA', boxId: boxId, folderId: f1, deviceFilename: 'IMG_1.jpg');

      expect(await db.deleteCaptureBox(deviceId: 'devA', boxId: boxId), isFalse);
      expect(await db.getCaptureBoxById(deviceId: 'devA', boxId: boxId), isNotNull);
      expect(await db.getCaptureFolders(deviceId: 'devA', boxId: boxId), hasLength(2));

      await db.unassignImage(deviceId: 'devA', deviceFilename: 'IMG_1.jpg');
      expect(await db.deleteCaptureBox(deviceId: 'devA', boxId: boxId), isTrue);
      expect(await db.getCaptureBoxById(deviceId: 'devA', boxId: boxId), isNull);
      expect(await db.getCaptureFolders(deviceId: 'devA', boxId: boxId), isEmpty);
    });
  });

  group('image assignments', () {
    test('assign is unique per filename; duplicate returns false', () async {
      final db = await freshDb('cap_assign_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final f1 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);
      final f2 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId, volume: 'V file no. 2'), isComplete: true);

      expect(
          await db.assignImageToFolder(
              deviceId: 'devA', boxId: boxId, folderId: f1, deviceFilename: 'IMG_1.jpg'),
          isTrue);
      // Same filename again — anywhere — is refused, not thrown.
      expect(
          await db.assignImageToFolder(
              deviceId: 'devA', boxId: boxId, folderId: f2, deviceFilename: 'IMG_1.jpg'),
          isFalse);

      final map = await db.getAssignmentsForBox(deviceId: 'devA', boxId: boxId);
      expect(map, {'IMG_1.jpg': f1});
    });

    test('unassign frees the filename for a later box', () async {
      final db = await freshDb('cap_unassign_');
      final b1 = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B1');
      final f1 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(b1), isComplete: true);
      await db.assignImageToFolder(
          deviceId: 'devA', boxId: b1, folderId: f1, deviceFilename: 'IMG_1.jpg');
      await db.unassignImage(deviceId: 'devA', deviceFilename: 'IMG_1.jpg');

      final b2 = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B2');
      final f2 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(b2), isComplete: true);
      expect(
          await db.assignImageToFolder(
              deviceId: 'devA', boxId: b2, folderId: f2, deviceFilename: 'IMG_1.jpg'),
          isTrue);
    });

    test(
      'unassignImage refuses a transferred row (only QC may delete it) but '
      'still deletes an untransferred one',
      () async {
        final db = await freshDb('cap_unassign_transferred_');
        final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
        final f1 = await db.insertCaptureFolder(
            deviceId: 'devA', folder: _folder(boxId), isComplete: true);
        final f2 = await db.insertCaptureFolder(
            deviceId: 'devA', folder: _folder(boxId, volume: 'V file no. 2'), isComplete: true);
        await db.assignImageToFolder(
            deviceId: 'devA', boxId: boxId, folderId: f1, deviceFilename: 'IMG_1.jpg');
        await db.assignImageToFolder(
            deviceId: 'devA', boxId: boxId, folderId: f2, deviceFilename: 'IMG_2.jpg');
        await db.reportCaptureImageTransferName(
          deviceId: 'devA',
          deviceName: 'IMG_1.jpg',
          finalName: 'SAX01_IMG_1_001.jpg',
        );

        // Transferred — refused, row stays.
        expect(
          await db.unassignImage(deviceId: 'devA', deviceFilename: 'IMG_1.jpg'),
          isFalse,
        );
        expect(
          await db.getAssignmentsForBox(deviceId: 'devA', boxId: boxId),
          containsPair('IMG_1.jpg', f1),
        );

        // Untransferred — removed as normal.
        expect(
          await db.unassignImage(deviceId: 'devA', deviceFilename: 'IMG_2.jpg'),
          isTrue,
        );
        expect(
          await db.getAssignmentsForBox(deviceId: 'devA', boxId: boxId),
          isNot(contains('IMG_2.jpg')),
        );
      },
    );

    test('countImagesPerFolder groups correctly', () async {
      final db = await freshDb('cap_count_');
      final boxId = await db.insertCaptureBox(deviceId: 'devA', boxDetails: 'B');
      final f1 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId), isComplete: true);
      final f2 = await db.insertCaptureFolder(
          deviceId: 'devA', folder: _folder(boxId, volume: 'V file no. 2'), isComplete: true);
      for (final n in ['a.jpg', 'b.jpg', 'c.jpg']) {
        await db.assignImageToFolder(
            deviceId: 'devA', boxId: boxId, folderId: f1, deviceFilename: n);
      }
      await db.assignImageToFolder(
          deviceId: 'devA', boxId: boxId, folderId: f2, deviceFilename: 'd.jpg');

      final counts = await db.countImagesPerFolder(deviceId: 'devA', boxId: boxId);
      expect(counts, {f1: 3, f2: 1});
    });
  });
}
