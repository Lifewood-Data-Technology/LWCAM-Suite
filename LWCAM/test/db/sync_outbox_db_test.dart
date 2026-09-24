import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

/// Rows in [deviceId]'s OWN outbox. Deliberately reads that one stable DB
/// rather than `getOutboxDatabases`, which spans every device on the PC (see
/// its doc) and would therefore report another device's rows as this one's —
/// which is exactly what the device-handoff tests below must tell apart.
Future<List<Map<String, dynamic>>> _outboxRows(
  UploadStatsDB db,
  String deviceId, {
  String? entity,
}) async {
  final source = await db.getDatabase(deviceId);
  final rows = await source.query(
    'sync_outbox',
    where: entity == null ? null : 'entity = ?',
    whereArgs: entity == null ? null : [entity],
  );
  return rows
      .map(
        (r) => {
          ...r,
          'decoded_payload': r['payload'] == null
              ? null
              : jsonDecode(r['payload'] as String),
        },
      )
      .toList();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('schema', () {
    test(
      'fresh device DB has sync_outbox with a unique (entity, entity_key) index',
      () async {
        final base = await _tempDir('sync_fresh_');
        final db = UploadStatsDB();
        db.debugOverrideBaseFolderForTests(base.path);
        addTearDown(() => db.debugCloseAllForTests());

        final fresh = await db.getDatabase('devFresh9');
        expect(await fresh.getVersion(), 2);

        final tables = (await fresh.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table'",
        )).map((r) => r['name'] as String).toSet();
        expect(tables, contains('sync_outbox'));

        final indexes =
            (await fresh.rawQuery(
                  "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_outbox_entity_key'",
                )).single['sql']
                as String;
        expect(indexes, contains('UNIQUE'));

        // Natural keys replaced the old box_uid/folder_uid columns — the sink
        // resolves cloud ids from (project_id, box_name)/(box, folder_seq).
        final columns = (await fresh.rawQuery(
          'PRAGMA table_info(capture_boxes)',
        )).map((r) => r['name'] as String).toSet();
        expect(columns, isNot(contains('box_uid')));
        expect(
          columns,
          containsAll(['box_name', 'project_id', 'renamed_from']),
        );
        final folderColumns = (await fresh.rawQuery(
          'PRAGMA table_info(capture_folders)',
        )).map((r) => r['name'] as String).toSet();
        expect(folderColumns, isNot(contains('folder_uid')));
      },
    );
  });

  group('outbox hooks', () {
    Future<UploadStatsDB> freshDb(
      String prefix, {
      required bool syncEnabled,
    }) async {
      final base = await _tempDir(prefix);
      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      db.syncEnabled = syncEnabled;
      addTearDown(() {
        db.syncEnabled = false; // don't leak into later tests via the singleton
        return db.debugCloseAllForTests();
      });
      return db;
    }

    test(
      'syncEnabled=false: every hooked write path enqueues nothing',
      () async {
        final db = await freshDb('hooks_off_', syncEnabled: false);
        const deviceId = 'devHooksOff';

        await db.insertUploadRecord(
          deviceId: deviceId,
          scanningOpr: 'alice',
          boxDetails: 'BOX-1',
          filename: 'IMG_1.jpg',
          format: 'jpg',
          createdAt: DateTime(2026, 1, 1),
        );
        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
        );
        await db.updateCaptureBoxDetails(
          deviceId: deviceId,
          boxId: boxId,
          boxDetails: 'BOX-1-renamed',
        );
        await db.markCaptureBoxTransferred(deviceId: deviceId, boxId: boxId);
        final folderId = await db.insertCaptureFolder(
          deviceId: deviceId,
          folder: _folder(boxId),
          isComplete: false,
        );
        await db.updateCaptureFolderMetadata(
          deviceId: deviceId,
          folder: _folder(boxId).copyWith(id: folderId, title: 'Updated'),
          isComplete: true,
        );
        await db.updateCaptureFolderName(
          deviceId: deviceId,
          folderId: folderId,
          folderName: 'F001',
        );
        await db.deleteCaptureFolder(deviceId: deviceId, folderId: folderId);
        await db.insertReplacementRecord(
          deviceId: deviceId,
          sequenceIndex: 1,
          dateKey: '20260101',
          originalFilename: 'IMG_2.jpg',
          replacementFilename: 'IMG_2_r1.jpg',
          replacementLocalPath: 'C:/tmp/IMG_2_r1.jpg',
        );
        await db.markReplacementRecordSuperseded(
          deviceId: deviceId,
          originalFilename: 'IMG_2.jpg',
          replacementFilename: 'IMG_2_r1.jpg',
        );
        await db.markReplacementRecordsSuperseded(
          deviceId: deviceId,
          originalFilename: 'IMG_2.jpg',
        );

        expect(await _outboxRows(db, deviceId), isEmpty);
      },
    );

    test('insertUploadRecord enqueues NOTHING — upload_records left the sync '
        'pipeline (capture_images replaced it)', () async {
      final db = await freshDb('hooks_upload_', syncEnabled: true);
      const deviceId = 'devUpload';

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_1.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 1, 1),
      );

      expect(await _outboxRows(db, deviceId), isEmpty);
    });

    test('insertCaptureBox enqueues an upsert keyed by the local row id, '
        'payload in cloud shape (box_name, CAPS status, project_id)', () async {
      final db = await freshDb('hooks_box_insert_', syncEnabled: true);
      const deviceId = 'devBox';

      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        scanningOpr: 'alice',
        projectId: 'PRJ-1',
      );

      final rows = await _outboxRows(db, deviceId, entity: 'capture_boxes');
      expect(rows, hasLength(1));
      expect(rows.single['entity_key'], '$boxId');
      expect(rows.single['op'], 'upsert');
      final payload = rows.single['decoded_payload'] as Map;
      expect(payload['box_name'], 'BOX-1');
      expect(payload['status'], 'OPEN');
      expect(payload['user_id'], 'alice');
      expect(payload['project_id'], 'PRJ-1');
    });

    test(
      'updateCaptureBoxDetails and markCaptureBoxTransferred coalesce into a '
      'single pending outbox row carrying the latest snapshot + renamed_from',
      () async {
        final db = await freshDb('hooks_box_coalesce_', syncEnabled: true);
        const deviceId = 'devBoxCoalesce';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
        );
        await db.updateCaptureBoxDetails(
          deviceId: deviceId,
          boxId: boxId,
          boxDetails: 'BOX-1-renamed',
        );
        await db.markCaptureBoxTransferred(
          deviceId: deviceId,
          boxId: boxId,
          transferredTo: r'D:\dest',
        );

        final rows = await _outboxRows(db, deviceId, entity: 'capture_boxes');
        expect(rows, hasLength(1)); // insert + 2 updates -> 1 coalesced row
        final payload = rows.single['decoded_payload'] as Map;
        expect(payload['box_name'], 'BOX-1-renamed');
        // The sink's rename fixup needs the name PG last saw.
        expect(payload['renamed_from'], 'BOX-1');
        expect(payload['status'], 'TRANSFERRED');
        expect(payload['transferred_to'], r'D:\dest');
        expect(payload['transfer_end_at'], isNotNull);
      },
    );

    test(
      'a second rename keeps the ORIGINAL renamed_from (only-if-null rule)',
      () async {
        final db = await freshDb('hooks_box_rename2_', syncEnabled: true);
        const deviceId = 'devBoxRename2';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'A',
        );
        await db.updateCaptureBoxDetails(
          deviceId: deviceId,
          boxId: boxId,
          boxDetails: 'B',
        );
        await db.updateCaptureBoxDetails(
          deviceId: deviceId,
          boxId: boxId,
          boxDetails: 'C',
        );

        final rows = await _outboxRows(db, deviceId, entity: 'capture_boxes');
        final payload = rows.single['decoded_payload'] as Map;
        expect(payload['box_name'], 'C');
        expect(payload['renamed_from'], 'A');
      },
    );

    test(
      'markCaptureBoxTransferStarted stamps transfer_start_at and enqueues',
      () async {
        final db = await freshDb('hooks_box_start_', syncEnabled: true);
        const deviceId = 'devBoxStart';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
        );
        final dest = await db.markCaptureBoxTransferStarted(
          deviceId: deviceId,
          boxId: boxId,
          destinationRoot: r'D:\dest',
        );

        final rows = await _outboxRows(db, deviceId, entity: 'capture_boxes');
        final payload = rows.single['decoded_payload'] as Map;
        expect(payload['transfer_start_at'], isNotNull);
        expect(payload['status'], 'OPEN');
        expect(payload['transferred_to'], dest);
        expect(dest, matches(RegExp(r'^D:\\dest\\\d{8}$')));
      },
    );

    test(
      'markCaptureBoxTransferStarted fixes the destination day dir once: a '
      'retry (even from another root) reuses it, a legacy bare root is replaced',
      () async {
        final db = await freshDb('hooks_box_dest_', syncEnabled: false);
        const deviceId = 'devBoxDest';
        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
        );

        final first = await db.markCaptureBoxTransferStarted(
          deviceId: deviceId,
          boxId: boxId,
          destinationRoot: r'D:\dest',
        );
        final retry = await db.markCaptureBoxTransferStarted(
          deviceId: deviceId,
          boxId: boxId,
          destinationRoot: r'E:\moved',
        );
        expect(retry, first);
        final box = await db.getCaptureBoxById(deviceId: deviceId, boxId: boxId);
        expect(box!.transferredTo, first);

        // A box transferred by an older build holds the bare root.
        final legacyId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-OLD',
        );
        await db.markCaptureBoxTransferred(
          deviceId: deviceId,
          boxId: legacyId,
          transferredTo: r'D:\dest',
        );
        final fixed = await db.markCaptureBoxTransferStarted(
          deviceId: deviceId,
          boxId: legacyId,
          destinationRoot: r'D:\dest',
        );
        expect(fixed, matches(RegExp(r'^D:\\dest\\\d{8}$')));
      },
    );

    test("insertCaptureFolder's payload carries the parent box's natural keys "
        'and the operator stamps', () async {
      final db = await freshDb('hooks_folder_insert_', syncEnabled: true);
      const deviceId = 'devFolder';

      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: false,
        captureOperatorName: 'alice',
      );

      final rows = await _outboxRows(db, deviceId, entity: 'capture_folders');
      final folderRow = rows.singleWhere((r) => r['entity_key'] == '$folderId');
      final payload = folderRow['decoded_payload'] as Map;
      expect(payload['box_name'], 'BOX-1');
      expect(payload['project_id'], 'PRJ-1');
      expect(payload['device_id'], deviceId);
      expect(payload['title'], 'WWI Medical Files');
      expect(payload['capture_operator_id'], deviceId);
      expect(payload['capture_operator_name'], 'alice');
      expect(payload['source_created_at'], isNotNull);
    });

    test(
      'updateCaptureFolderMetadata and updateCaptureFolderName coalesce into a '
      "single pending row that still carries the parent's natural keys",
      () async {
        final db = await freshDb('hooks_folder_coalesce_', syncEnabled: true);
        const deviceId = 'devFolderCoalesce';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
        );
        final folderId = await db.insertCaptureFolder(
          deviceId: deviceId,
          folder: _folder(boxId),
          isComplete: false,
        );
        await db.updateCaptureFolderMetadata(
          deviceId: deviceId,
          folder: _folder(boxId).copyWith(id: folderId, title: 'Updated Title'),
          isComplete: true,
        );
        await db.updateCaptureFolderName(
          deviceId: deviceId,
          folderId: folderId,
          folderName: 'F001',
        );

        final rows = await _outboxRows(db, deviceId, entity: 'capture_folders');
        expect(rows, hasLength(1));
        final payload = rows.single['decoded_payload'] as Map;
        expect(payload['title'], 'Updated Title');
        expect(payload['folder_name'], 'F001');
        // Regression guard: a coalesced update must not drop the FK keys the
        // initial insert carried — the payload is re-joined fresh every time,
        // not sourced from whichever write happened to run last.
        expect(payload['box_name'], 'BOX-1');
      },
    );

    test('deleteCaptureFolder after insert coalesces to a single delete op '
        'carrying the cloud natural key', () async {
      final db = await freshDb('hooks_folder_delete_', syncEnabled: true);
      const deviceId = 'devFolderDelete';

      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: false,
      );

      final deleted = await db.deleteCaptureFolder(
        deviceId: deviceId,
        folderId: folderId,
      );
      expect(deleted, isTrue);

      final rows = await _outboxRows(db, deviceId, entity: 'capture_folders');
      expect(rows, hasLength(1));
      expect(rows.single['entity_key'], '$folderId');
      expect(rows.single['op'], 'delete');
      // Delete ops carry the key payload — the sink soft-deletes by
      // (box, folder_seq), which no longer exists locally after the delete.
      final payload = rows.single['decoded_payload'] as Map;
      expect(payload['folder_seq'], 1);
      expect(payload['box_name'], 'BOX-1');
      expect(payload['project_id'], 'PRJ-1');
    });

    test('deleteCaptureBox coalesces the box and each folder into delete ops '
        'that carry the cloud natural key', () async {
      final db = await freshDb('hooks_box_delete_', syncEnabled: true);
      const deviceId = 'devBoxDelete';

      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: false,
      );

      expect(await db.deleteCaptureBox(deviceId: deviceId, boxId: boxId), isTrue);

      // One row per entity: the pending upserts were REPLACED, not joined.
      final boxRows = await _outboxRows(db, deviceId, entity: 'capture_boxes');
      expect(boxRows, hasLength(1));
      expect(boxRows.single['entity_key'], '$boxId');
      expect(boxRows.single['op'], 'delete');
      final boxPayload = boxRows.single['decoded_payload'] as Map;
      // The sink resolves the PG row by these, under the owner's scope.
      expect(boxPayload['box_name'], 'BOX-1');
      expect(boxPayload['project_id'], 'PRJ-1');
      expect(boxPayload['device_id'], deviceId);

      final folderRows =
          await _outboxRows(db, deviceId, entity: 'capture_folders');
      expect(folderRows, hasLength(1));
      expect(folderRows.single['entity_key'], '$folderId');
      expect(folderRows.single['op'], 'delete');
    });

    test(
      'assignImageToFolder enqueues a capture_images upsert with parent '
      'keys + file_format; unassignImage coalesces it into a delete',
      () async {
        final db = await freshDb('hooks_image_', syncEnabled: true);
        const deviceId = 'devImage';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
          projectId: 'PRJ-1',
        );
        final folderId = await db.insertCaptureFolder(
          deviceId: deviceId,
          folder: _folder(boxId),
          isComplete: false,
        );
        final ok = await db.assignImageToFolder(
          deviceId: deviceId,
          boxId: boxId,
          folderId: folderId,
          deviceFilename: 'IMG_1.JPG',
        );
        expect(ok, isTrue);

        var rows = await _outboxRows(db, deviceId, entity: 'capture_images');
        expect(rows, hasLength(1));
        expect(rows.single['entity_key'], '$folderId|IMG_1.JPG');
        expect(rows.single['op'], 'upsert');
        var payload = rows.single['decoded_payload'] as Map;
        expect(payload['image_name'], 'IMG_1.JPG');
        expect(payload['file_format'], 'jpg'); // extension lowercased
        expect(payload['folder_seq'], 1);
        expect(payload['box_name'], 'BOX-1');
        expect(payload['project_id'], 'PRJ-1');

        await db.unassignImage(deviceId: deviceId, deviceFilename: 'IMG_1.JPG');
        rows = await _outboxRows(db, deviceId, entity: 'capture_images');
        expect(rows, hasLength(1)); // coalesced — same (entity, key)
        expect(rows.single['op'], 'delete');
        payload = rows.single['decoded_payload'] as Map;
        expect(payload['image_name'], 'IMG_1.JPG');
        expect(payload['folder_seq'], 1);
      },
    );

    // Capture records the DEVICE filename immediately so the productivity
    // dashboard sees the image right away, but the transfer writes it as
    // <deviceId>_<stem>_<NNN>.ext — a suffix allocated against destination disk
    // state, so unknowable at capture. QC/export resolve files by the CLOUD
    // image_name, so the cloud row must carry the final name. The LOCAL row
    // keeps the device name as its stable identity and stores the copied name
    // separately for later deletes and recovery.
    test(
      'reportCaptureImageTransferName sends the final name (with '
      'image_renamed_from) to the cloud while retaining the local identity',
      () async {
        final db = await freshDb('hooks_image_rename_', syncEnabled: true);
        const deviceId = 'devImageRename';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
          projectId: 'PRJ-1',
        );
        final folderId = await db.insertCaptureFolder(
          deviceId: deviceId,
          folder: _folder(boxId),
          isComplete: false,
        );
        await db.assignImageToFolder(
          deviceId: deviceId,
          boxId: boxId,
          folderId: folderId,
          deviceFilename: 'IMG_20260729_112403.jpg',
        );

        final reported = await db.reportCaptureImageTransferName(
          deviceId: deviceId,
          deviceName: 'IMG_20260729_112403.jpg',
          finalName: 'SAX04_IMG_20260729_112403_001.jpg',
        );
        expect(reported, isTrue);

        // LOCAL identity remains stable; the copied name is persisted beside it.
        final stable = await db.getDatabase(deviceId);
        final images = await stable.query('capture_images');
        expect(images, hasLength(1));
        expect(images.single['image_name'], 'IMG_20260729_112403.jpg');
        expect(
          images.single['transferred_name'],
          'SAX04_IMG_20260729_112403_001.jpg',
        );
        expect(images.single['folder_id'], folderId);

        final rows = await _outboxRows(db, deviceId, entity: 'capture_images');
        expect(rows, hasLength(1)); // rename coalesces the original stable key
        final renamedRow = rows.firstWhere(
          (r) => (r['decoded_payload'] as Map)['image_renamed_from'] != null,
        );
        final payload = renamedRow['decoded_payload'] as Map;
        expect(payload['image_name'], 'SAX04_IMG_20260729_112403_001.jpg');
        expect(payload['image_renamed_from'], 'IMG_20260729_112403.jpg');
        // 'renamed_from' must stay the parent BOX's field, untouched.
        expect(payload['renamed_from'], isNull);
        // Natural keys must still be present or the sink can't resolve the folder.
        expect(payload['folder_seq'], 1);
        expect(payload['box_name'], 'BOX-1');
        expect(payload['project_id'], 'PRJ-1');
        // box_id is local-only and must never reach the wire.
        expect(payload.containsKey('box_id'), isFalse);

        // Fix 10: once transferred, only QC may delete — LWCAM refuses and
        // enqueues nothing more (the rename upsert above stays the last op).
        final removed = await db.unassignImage(
          deviceId: deviceId,
          deviceFilename: 'IMG_20260729_112403.jpg',
        );
        expect(removed, isFalse);
        final rowsAfterRefusal = await _outboxRows(
          db,
          deviceId,
          entity: 'capture_images',
        );
        expect(rowsAfterRefusal, hasLength(1));
        expect(rowsAfterRefusal.single['op'], 'upsert');

        // An untransferred image still deletes normally.
        await db.assignImageToFolder(
          deviceId: deviceId,
          boxId: boxId,
          folderId: folderId,
          deviceFilename: 'IMG_untransferred.jpg',
        );
        final removedUntransferred = await db.unassignImage(
          deviceId: deviceId,
          deviceFilename: 'IMG_untransferred.jpg',
        );
        expect(removedUntransferred, isTrue);
        final deleteRows = await _outboxRows(
          db,
          deviceId,
          entity: 'capture_images',
        ).then(
          (rows) => rows.where((r) => r['op'] == 'delete').toList(),
        );
        final deletePayload = deleteRows.single['decoded_payload'] as Map;
        expect(deletePayload['image_name'], 'IMG_untransferred.jpg');
      },
    );

    // The QC -> capture rework channel. rework_logs is append-only: QC appends
    // an OPEN row per rejected image, LWCAM appends a CLOSED row once the
    // recaptured image has transferred. Going through the outbox (rather than a
    // direct PG write) means the closure survives an offline recapture and
    // inherits the retry/backoff.
    test('enqueueReworkClosed carries the natural keys the sink needs and '
        'coalesces per (folder, image)', () async {
      final db = await freshDb('hooks_rework_', syncEnabled: true);
      const deviceId = 'devRework';

      Future<void> close(String imageName, {String? comment}) =>
          db.enqueueReworkClosed(
            deviceId: deviceId,
            projectKey: 'pk1',
            projectId: 'PRJ-1',
            boxName: 'BOX-9',
            folderSeq: 3,
            folderName: 'BOX-9 - 1 - 0001',
            imageName: imageName,
            assignedUsername: 'Jamie',
            comment: comment,
          );

      await close('SAX01_a_001.jpg');
      await close('SAX01_b_001.jpg', comment: 'Recaptured after blur');

      final rows = await _outboxRows(db, deviceId, entity: 'rework_logs');
      expect(rows, hasLength(2));
      final first = rows.firstWhere(
        (r) => (r['decoded_payload'] as Map)['image_name'] == 'SAX01_a_001.jpg',
      );
      expect(first['entity_key'], 'pk1|BOX-9|3|SAX01_a_001.jpg');
      final payload = first['decoded_payload'] as Map;
      // Everything the sink resolves ids from.
      expect(payload['project_key'], 'pk1');
      expect(payload['box_name'], 'BOX-9');
      expect(payload['folder_seq'], 3);
      expect(payload['image_name'], 'SAX01_a_001.jpg');
      // assigned_uid comes from this (the sink's userId helper reads user_id).
      expect(payload['user_id'], 'Jamie');
      expect(payload['rework_type'], 'Recapture');
      expect(payload['rework_comments'], isNotEmpty);
      expect(payload['closed_at'], isNotNull);

      // Re-closing the same image coalesces instead of stacking duplicates.
      await close('SAX01_a_001.jpg');
      expect(
        await _outboxRows(db, deviceId, entity: 'rework_logs'),
        hasLength(2),
      );
    });

    test('enqueueReworkClosed records a metadata-only resolution', () async {
      final db = await freshDb('hooks_rework_meta_', syncEnabled: true);
      const deviceId = 'devReworkMeta';
      await db.enqueueReworkClosed(
        deviceId: deviceId,
        projectKey: 'pk1',
        projectId: 'PRJ-1',
        boxName: 'BOX-9',
        folderSeq: 3,
        folderName: 'BOX-9 - 1 - 0001',
        imageName: 'SAX01_a_001.jpg',
        assignedUsername: 'Jamie',
        reworkType: 'Metadata',
      );
      final rows = await _outboxRows(db, deviceId, entity: 'rework_logs');
      final payload = rows.single['decoded_payload'] as Map;
      // The audit trail has to distinguish "re-photographed" from "the keying was
      // wrong, the photo was fine" — an operator can close a row either way.
      expect(payload['rework_type'], 'Metadata');
      expect(payload['rework_comments'], contains('Metadata'));
    });

    // The folder side of a rework submit. Narrow by design: folderUpsertSql
    // would write every metadata column from the local row and revert QC's own
    // edits to the ones the operator never touched.
    test('enqueueFolderRework carries only the changed columns and coalesces '
        'per folder', () async {
      final db = await freshDb('hooks_folder_rework_', syncEnabled: true);
      const deviceId = 'devFolderRework';

      Future<void> submit(
        Map<String, Object?> changed, {
        bool reset = false,
        bool thumbnails = false,
      }) => db.enqueueFolderRework(
        deviceId: deviceId,
        projectKey: 'pk1',
        projectId: 'PRJ-1',
        boxName: 'BOX-9',
        folderSeq: 3,
        folderName: 'BOX-9 - 1 - 0001',
        changedMetadata: changed,
        resetQcStatus: reset,
        isCreatedThumbnail: thumbnails,
      );

      await submit({'title': 'Corrected'});
      var rows = await _outboxRows(
        db,
        deviceId,
        entity: 'capture_folder_rework',
      );
      expect(rows, hasLength(1));
      expect(rows.single['entity_key'], 'pk1|BOX-9|3');
      var payload = rows.single['decoded_payload'] as Map;
      expect(payload['metadata'], {'title': 'Corrected'});
      expect(payload['reset_qc_status'], false);
      expect(payload['project_key'], 'pk1');
      expect(payload['folder_seq'], 3);

      // A second submit for the same folder coalesces. That is safe only because
      // the patch is always computed against the cloud values read when the box
      // was opened, so the newer payload is a superset of the undrained older one
      // — hence both columns here, not just the second.
      await submit({
        'title': 'Corrected',
        'volume': 'file no. 12',
      }, reset: true);
      rows = await _outboxRows(db, deviceId, entity: 'capture_folder_rework');
      expect(rows, hasLength(1));
      payload = rows.single['decoded_payload'] as Map;
      expect(payload['metadata'], {
        'title': 'Corrected',
        'volume': 'file no. 12',
      });
      expect(payload['reset_qc_status'], true);
    });

    test('enqueueFolderRework skips a submit that changes nothing', () async {
      final db = await freshDb('hooks_folder_rework_noop_', syncEnabled: true);
      await db.enqueueFolderRework(
        deviceId: 'devNoop',
        projectKey: 'pk1',
        projectId: 'PRJ-1',
        boxName: 'BOX-9',
        folderSeq: 3,
        folderName: 'F',
        changedMetadata: const {},
        resetQcStatus: false,
        isCreatedThumbnail: false,
      );
      expect(await _outboxRows(db, 'devNoop'), isEmpty);
    });

    test('enqueueReworkClosed enqueues nothing when sync is off', () async {
      final db = await freshDb('hooks_rework_off_', syncEnabled: false);
      await db.enqueueReworkClosed(
        deviceId: 'devReworkOff',
        projectKey: 'pk1',
        projectId: 'PRJ-1',
        boxName: 'BOX-9',
        folderSeq: 1,
        folderName: 'F',
        imageName: 'a.jpg',
        assignedUsername: 'Jamie',
      );
      expect(await _outboxRows(db, 'devReworkOff'), isEmpty);
    });

    // The processing report agent can be re-bound to a different device id at
    // login (shared PC). The drain only reads the CURRENT device's outbox, so
    // reports pending under the old id stranded silently — the 2026-07-29
    // incident (handover §7.8). Each link of the fix is pinned separately.
    group('processing report device-id handoff', () {
      Map<String, dynamic> identity(int seq) => {
        'project_key': 'pk1',
        'project_id': 'PRJ-1',
        'box_name': 'BOX-9',
        'device_id': 'SAX04',
        'folder_seq': seq,
        'folder_name': 'F00$seq',
      };

      test('the dedupe ledger is machine-global: a report recorded under one '
          'device id is still deduped after a device switch', () async {
        final db = await freshDb('ledger_global_', syncEnabled: true);
        await db.recordFolderProcessing(
          deviceId: 'SAX04',
          identity: identity(1),
          folderPath: r'C:\out\F001',
          thumbnailPath: r'C:\out\F001\thumbs',
          isCreatedThumbnail: true,
          inputPath: r'C:\in\F001',
          fingerprint: 'fp-1',
        );
        // No deviceId parameter — the ledger no longer belongs to any device.
        expect(
          await db.isProcessingReported(
            inputPath: r'C:\in\F001',
            fingerprint: 'fp-1',
          ),
          isTrue,
        );
        // The ledger row must NOT live in the reporting device's own DB…
        final sax04 = await db.getDatabase('SAX04');
        expect(await sax04.query('processing_ledger'), isEmpty);
        // …but in the machine-global one.
        final ledger = await db.getDatabase(
          UploadStatsDB.processingLedgerDeviceId,
        );
        expect(await ledger.query('processing_ledger'), hasLength(1));
        // The OUTBOX row stays with the reporting device (that DB is drained
        // while the binding is current).
        expect(
          await _outboxRows(db, 'SAX04', entity: 'capture_folder_processing'),
          hasLength(1),
        );
      });

      test('migratePendingProcessingOutbox moves pending reports to the new '
          'device, resets backoff, and leaves other entities behind', () async {
        final db = await freshDb('migrate_pending_', syncEnabled: true);
        for (final seq in [1, 2]) {
          await db.recordFolderProcessing(
            deviceId: 'SAX04',
            identity: identity(seq),
            folderPath: 'C:/out/F00$seq',
            thumbnailPath: 'C:/out/F00$seq/thumbs',
            isCreatedThumbnail: false,
            inputPath: 'C:/in/F00$seq',
            fingerprint: 'fp-$seq',
          );
        }
        // A non-processing row must NOT migrate.
        await db.insertCaptureBox(
          deviceId: 'SAX04',
          boxDetails: 'BOX-9',
          projectId: 'PRJ-1',
        );
        // Simulate the backoff stamp a failed drain leaves behind.
        final sax04 = await db.getDatabase('SAX04');
        await sax04.update('sync_outbox', {
          'attempts': 6,
          'last_error': 'boom',
          'next_attempt_at': '2099-01-01',
        }, where: "entity = 'capture_folder_processing'");

        final moved = await db.migratePendingProcessingOutbox(
          from: 'SAX04',
          to: 'SAX01',
        );
        expect(moved, 2);

        final arrived = await _outboxRows(
          db,
          'SAX01',
          entity: 'capture_folder_processing',
        );
        expect(arrived, hasLength(2));
        for (final row in arrived) {
          expect(row['attempts'], 0, reason: 'backoff must reset on arrival');
          expect(row['last_error'], isNull);
          expect(row['next_attempt_at'], isNull);
        }
        expect(
          await _outboxRows(db, 'SAX04', entity: 'capture_folder_processing'),
          isEmpty,
        );
        // The box upsert stays in its own device's outbox.
        expect(
          await _outboxRows(db, 'SAX04', entity: 'capture_boxes'),
          hasLength(1),
        );
        // Idempotent: nothing left to move.
        expect(
          await db.migratePendingProcessingOutbox(from: 'SAX04', to: 'SAX01'),
          0,
        );
        expect(
          await db.migratePendingProcessingOutbox(from: 'SAX01', to: 'SAX01'),
          0,
        );
      });

      test('migratePendingProcessingOutbox never loses a row enqueued '
          'concurrently with its own SELECT-then-DELETE — the DELETE is '
          'scoped to the exact ids just copied, not the whole entity',
          () async {
        final db = await freshDb('migrate_race_', syncEnabled: true);
        await db.recordFolderProcessing(
          deviceId: 'SAX04',
          identity: identity(1),
          folderPath: 'C:/out/F001',
          thumbnailPath: 'C:/out/F001/thumbs',
          isCreatedThumbnail: false,
          inputPath: 'C:/in/F001',
          fingerprint: 'fp-1',
        );

        // Fired unawaited so its own awaits can interleave with the
        // migration's SELECT-then-DELETE window — the old ProcessingReportService
        // timer is confirmed still armed during migration, so this race is real.
        final racer = db.recordFolderProcessing(
          deviceId: 'SAX04',
          identity: identity(2),
          folderPath: 'C:/out/F002',
          thumbnailPath: 'C:/out/F002/thumbs',
          isCreatedThumbnail: false,
          inputPath: 'C:/in/F002',
          fingerprint: 'fp-2',
        );

        await db.migratePendingProcessingOutbox(from: 'SAX04', to: 'SAX01');
        await racer;

        // Regardless of exactly when the racer's row landed, both reports
        // must be accounted for somewhere — never silently dropped by an
        // unscoped "delete everything of this entity".
        final remaining = await _outboxRows(
          db,
          'SAX04',
          entity: 'capture_folder_processing',
        );
        final arrived = await _outboxRows(
          db,
          'SAX01',
          entity: 'capture_folder_processing',
        );
        expect(remaining.length + arrived.length, 2);
      });
    });

    // Template-derived metadata (a mapped Start Date, fixed Place, …) is
    // computed at transfer prep — it is NOT keyed onto the row by the form.
    // The outbox snapshots the ROW, so unless these values are persisted the
    // cloud capture_folders (which QC and the export read) never sees them.
    // This is the July-29 NULL-dates bug (HANDOVER_CHANGES §7.4).
    test('updateCaptureFolderEffectiveValues lands derived metadata on the row '
        'AND in the coalesced outbox payload', () async {
      final db = await freshDb('hooks_effective_', syncEnabled: true);
      const deviceId = 'devEffective';

      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
      );
      // Keyed by the form: title/volume/archival. Dates are template-mapped,
      // so the form leaves them NULL — exactly the bug's starting state.
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: CaptureFolder(
          boxId: boxId,
          coverTag: 'Cover Will Be Captured',
          title: 'WWII Medical Files',
          volume: 'V file no. 1',
          archivalRefNo: '8888',
        ),
        isComplete: true,
      );

      await db.updateCaptureFolderEffectiveValues(
        deviceId: deviceId,
        folderId: folderId,
        startDate: '1939',
        endDate: '1945',
        recordType: 'Military Medical Records',
        place: 'South Africa',
        language: 'English',
        recordCustodian: 'South Africa Department of Defense',
        digitizingEntity: 'Lifewood',
        captureOperatorId: 'cis.user.MM38-RXW3',
        captureOperatorName: 'lifewoodza01',
      );

      final stable = await db.getDatabase(deviceId);
      final row = (await stable.query(
        'capture_folders',
        where: 'id = ?',
        whereArgs: [folderId],
      )).single;
      expect(row['start_date'], '1939');
      expect(row['end_date'], '1945');
      expect(row['record_type'], 'Military Medical Records');
      expect(row['place'], 'South Africa');
      expect(row['capture_operator_name'], 'lifewoodza01');
      // Form-owned columns untouched.
      expect(row['title'], 'WWII Medical Files');
      expect(row['archival_ref_no'], '8888');

      // One coalesced upsert whose payload carries the derived values — this
      // payload is exactly what folderUpsertSql binds verbatim into the TEXT
      // start_date/end_date columns at the sink.
      final rows = await _outboxRows(db, deviceId, entity: 'capture_folders');
      expect(rows, hasLength(1));
      final payload = rows.single['decoded_payload'] as Map;
      expect(payload['start_date'], '1939');
      expect(payload['end_date'], '1945');
      expect(payload['record_type'], 'Military Medical Records');
      expect(payload['language'], 'English');
      expect(payload['digitizing_entity'], 'Lifewood');
      expect(payload['title'], 'WWII Medical Files');
    });

    test('reportCaptureImageTransferName is a no-op when there is nothing to '
        'report', () async {
      final db = await freshDb('hooks_image_rename_noop_', syncEnabled: true);
      const deviceId = 'devImageRenameNoop';

      // Normal Mode keeps no capture_images rows; an unchanged name (no
      // suffixing happened) must not enqueue anything. Neither may throw.
      expect(
        await db.reportCaptureImageTransferName(
          deviceId: deviceId,
          deviceName: 'IMG_1.jpg',
          finalName: 'SAX04_IMG_1_001.jpg',
        ),
        isFalse,
      );
      expect(
        await db.reportCaptureImageTransferName(
          deviceId: deviceId,
          deviceName: 'same.jpg',
          finalName: 'same.jpg',
        ),
        isFalse,
      );
      expect(
        await _outboxRows(db, deviceId, entity: 'capture_images'),
        isEmpty,
      );
    });

    test(
      'a duplicate assignImageToFolder returns false and enqueues nothing new',
      () async {
        final db = await freshDb('hooks_image_dup_', syncEnabled: true);
        const deviceId = 'devImageDup';

        final boxId = await db.insertCaptureBox(
          deviceId: deviceId,
          boxDetails: 'BOX-1',
        );
        final folderId = await db.insertCaptureFolder(
          deviceId: deviceId,
          folder: _folder(boxId),
          isComplete: false,
        );
        expect(
          await db.assignImageToFolder(
            deviceId: deviceId,
            boxId: boxId,
            folderId: folderId,
            deviceFilename: 'IMG_1.jpg',
          ),
          isTrue,
        );
        expect(
          await db.assignImageToFolder(
            deviceId: deviceId,
            boxId: boxId,
            folderId: folderId,
            deviceFilename: 'IMG_1.jpg',
          ),
          isFalse,
        );

        final rows = await _outboxRows(db, deviceId, entity: 'capture_images');
        expect(rows, hasLength(1));
      },
    );

    test('deleteCaptureFolder refuses (and enqueues nothing) when images are '
        'assigned', () async {
      final db = await freshDb(
        'hooks_folder_delete_refuse_',
        syncEnabled: true,
      );
      const deviceId = 'devFolderDeleteRefuse';

      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: false,
      );
      await db.assignImageToFolder(
        deviceId: deviceId,
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'IMG_1.jpg',
      );

      final deleted = await db.deleteCaptureFolder(
        deviceId: deviceId,
        folderId: folderId,
      );
      expect(deleted, isFalse);

      final rows = await _outboxRows(db, deviceId, entity: 'capture_folders');
      // Only the insert's upsert — no delete was enqueued for the refusal.
      expect(rows, hasLength(1));
      expect(rows.single['op'], 'upsert');
    });

    test('insertReplacementRecord enqueues nothing — replacements are '
        'local-only, never synced', () async {
      final db = await freshDb('hooks_replacement_insert_', syncEnabled: true);
      const deviceId = 'devReplacement';

      await db.insertReplacementRecord(
        deviceId: deviceId,
        sequenceIndex: 1,
        dateKey: '20260101',
        originalFilename: 'IMG_1.jpg',
        replacementFilename: 'IMG_1_r1.jpg',
        replacementLocalPath: 'C:/tmp/IMG_1_r1.jpg',
      );

      final row = (await (await db.getDatabase(
        deviceId,
      )).query('replacement_records')).single;
      expect(row['original_filename'], 'IMG_1.jpg');
      expect(
        await _outboxRows(db, deviceId, entity: 'replacement_records'),
        isEmpty,
      );
    });

    test('markReplacementRecordSuperseded and markReplacementRecordsSuperseded '
        '(bulk) enqueue nothing even with syncEnabled=true', () async {
      final db = await freshDb(
        'hooks_replacement_supersede_',
        syncEnabled: true,
      );
      const deviceId = 'devReplacementSupersede';

      await db.insertReplacementRecord(
        deviceId: deviceId,
        sequenceIndex: 1,
        dateKey: '20260101',
        originalFilename: 'IMG_1.jpg',
        replacementFilename: 'IMG_1_r1.jpg',
        replacementLocalPath: 'C:/tmp/IMG_1_r1.jpg',
      );
      await db.insertReplacementRecord(
        deviceId: deviceId,
        sequenceIndex: 1,
        dateKey: '20260101',
        originalFilename: 'IMG_1.jpg',
        replacementFilename: 'IMG_1_r2.jpg',
        replacementLocalPath: 'C:/tmp/IMG_1_r2.jpg',
      );

      await db.markReplacementRecordSuperseded(
        deviceId: deviceId,
        originalFilename: 'IMG_1.jpg',
        replacementFilename: 'IMG_1_r1.jpg',
      );
      final supersededCount = await db.markReplacementRecordsSuperseded(
        deviceId: deviceId,
        originalFilename: 'IMG_1.jpg',
      );
      // r1 was already superseded above; the bulk call only catches r2.
      expect(supersededCount, 1);

      expect(
        await _outboxRows(db, deviceId, entity: 'replacement_records'),
        isEmpty,
      );
    });
  });

  group('processing reports (LWIP)', () {
    Future<UploadStatsDB> freshDb(
      String prefix, {
      required bool syncEnabled,
    }) async {
      final base = await _tempDir(prefix);
      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      db.syncEnabled = syncEnabled;
      addTearDown(() {
        db.syncEnabled = false;
        return db.debugCloseAllForTests();
      });
      return db;
    }

    Future<Map<String, dynamic>> folderRow(
      UploadStatsDB db,
      String deviceId,
      int id,
    ) async => (await (await db.getDatabase(
      deviceId,
    )).query('capture_folders', where: 'id = ?', whereArgs: [id])).single;

    test('records the processing entity, ledgers it, resets qc_status, and '
        'mirrors the six pipeline columns onto the local folder row', () async {
      final db = await freshDb('proc_same_', syncEnabled: true);
      const deviceId = 'devProc';
      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
        projectKey: 'pabc',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: true,
      );
      // Simulate an earlier QC verdict that reprocessing must reset.
      await (await db.getDatabase(deviceId)).update(
        'capture_folders',
        {'qc_status': 'PASS'},
        where: 'id = ?',
        whereArgs: [folderId],
      );

      await db.recordFolderProcessing(
        deviceId: deviceId,
        identity: {
          'project_key': 'pabc',
          'project_id': 'PRJ-1',
          'box_name': 'BOX-1',
          'device_id': deviceId,
          'folder_seq': 1,
          'folder_name': 'F001',
        },
        folderPath: r'D:\CAP_processed\20260722\F001',
        thumbnailPath: r'D:\CAP_processed\20260722\F001\thumbs',
        isCreatedThumbnail: true,
        inputPath: r'D:\CAP\20260722\F001',
        fingerprint: 'fp1',
      );

      final rows = await _outboxRows(
        db,
        deviceId,
        entity: 'capture_folder_processing',
      );
      expect(rows, hasLength(1));
      expect(rows.single['entity_key'], 'pabc|BOX-1|1');
      expect(rows.single['op'], 'upsert');
      final payload = rows.single['decoded_payload'] as Map;
      expect(payload['project_key'], 'pabc');
      expect(payload['box_name'], 'BOX-1');
      expect(payload['folder_seq'], 1);
      expect(payload['folder_path'], r'D:\CAP_processed\20260722\F001');
      expect(payload['is_created_thumbnail'], true);

      expect(
        await db.isProcessingReported(
          inputPath: r'D:\CAP\20260722\F001',
          fingerprint: 'fp1',
        ),
        isTrue,
      );

      final row = await folderRow(db, deviceId, folderId);
      expect(row['is_deskewed'], 1);
      expect(row['is_cropped'], 1);
      expect(row['is_created_thumbnail'], 1);
      expect(row['folder_path'], r'D:\CAP_processed\20260722\F001');
      expect(row['thumbnail_path'], endsWith('thumbs'));
      expect(row['qc_status'], 'PENDING'); // reset from PASS
    });

    test('on a folder absent locally (split-PC) it still enqueues + ledgers, '
        'with no local mirror update and no throw', () async {
      final db = await freshDb('proc_split_', syncEnabled: true);
      const deviceId = 'PROCESSING';
      await db.recordFolderProcessing(
        deviceId: deviceId,
        identity: {
          'project_key': 'pxyz',
          'project_id': 'PRJ-9',
          'box_name': 'BOX-9',
          'device_id': 'SAX07',
          'folder_seq': 2,
          'folder_name': 'F002',
        },
        folderPath: r'\\nas\proc\20260722\F002',
        thumbnailPath: r'\\nas\proc\20260722\F002\thumbs',
        isCreatedThumbnail: false,
        inputPath: r'\\nas\cap\20260722\F002',
        fingerprint: 'fp2',
      );

      final rows = await _outboxRows(
        db,
        deviceId,
        entity: 'capture_folder_processing',
      );
      expect(rows, hasLength(1));
      expect(
        (rows.single['decoded_payload'] as Map)['is_created_thumbnail'],
        false,
      );
      // No capture_folders exist on this processing-only device DB.
      expect(
        await (await db.getDatabase(deviceId)).query('capture_folders'),
        isEmpty,
      );
    });

    test(
      'a re-transfer (new fingerprint) re-reports, coalescing the outbox row '
      'to the latest; the ledger keeps both fingerprints',
      () async {
        final db = await freshDb('proc_reproc_', syncEnabled: true);
        const deviceId = 'devReproc';
        final identity = {
          'project_key': 'pabc',
          'project_id': 'PRJ-1',
          'box_name': 'BOX-1',
          'device_id': deviceId,
          'folder_seq': 1,
          'folder_name': 'F001',
        };
        await db.recordFolderProcessing(
          deviceId: deviceId,
          identity: identity,
          folderPath: 'p1',
          thumbnailPath: 't1',
          isCreatedThumbnail: true,
          inputPath: 'in',
          fingerprint: 'fp1',
        );
        await db.recordFolderProcessing(
          deviceId: deviceId,
          identity: identity,
          folderPath: 'p2',
          thumbnailPath: 't2',
          isCreatedThumbnail: true,
          inputPath: 'in',
          fingerprint: 'fp2',
        );

        final rows = await _outboxRows(
          db,
          deviceId,
          entity: 'capture_folder_processing',
        );
        expect(rows, hasLength(1)); // same entity_key → coalesced
        expect((rows.single['decoded_payload'] as Map)['folder_path'], 'p2');

        expect(
          await db.isProcessingReported(inputPath: 'in', fingerprint: 'fp1'),
          isTrue,
        );
        expect(
          await db.isProcessingReported(inputPath: 'in', fingerprint: 'fp2'),
          isTrue,
        );
        expect(
          await db.isProcessingReported(inputPath: 'in', fingerprint: 'fp3'),
          isFalse,
        );
      },
    );

    test('with sync OFF it still ledgers + mirrors locally but enqueues no '
        'outbox row (offline site gets local updates only)', () async {
      final db = await freshDb('proc_off_', syncEnabled: false);
      const deviceId = 'devProcOff';
      final boxId = await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
        projectKey: 'pabc',
      );
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: true,
      );

      await db.recordFolderProcessing(
        deviceId: deviceId,
        identity: {'project_key': 'pabc', 'box_name': 'BOX-1', 'folder_seq': 1},
        folderPath: 'p',
        thumbnailPath: 't',
        isCreatedThumbnail: true,
        inputPath: 'in',
        fingerprint: 'fp1',
      );

      expect(
        await _outboxRows(db, deviceId, entity: 'capture_folder_processing'),
        isEmpty,
      );
      expect(
        await db.isProcessingReported(inputPath: 'in', fingerprint: 'fp1'),
        isTrue,
      );
      expect((await folderRow(db, deviceId, folderId))['is_deskewed'], 1);
    });
  });
}
