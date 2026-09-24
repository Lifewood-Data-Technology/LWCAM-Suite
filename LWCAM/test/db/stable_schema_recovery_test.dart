import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/sync_models.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v1 capture tables migrate to the current schema', () async {
    final base = await _tempDir('stable_migration_');
    const deviceId = 'SAX-MIGRATE';
    final path = p.join(base.path, 'lwcam_stats_$deviceId.db');
    final legacy = await openDatabase(
      path,
      version: 1,
      onCreate: (db, _) async {
        await db.execute(
          'CREATE TABLE upload_records (id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT, filename TEXT)',
        );
        await db.execute(
          'CREATE TABLE daily_summary (id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT, date TEXT, total_count INTEGER)',
        );
        await db.execute(
          'CREATE TABLE replacement_records (id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT, original_filename TEXT)',
        );
        await db.execute('''CREATE TABLE capture_boxes (
        id INTEGER PRIMARY KEY, device_id TEXT, box_details TEXT, status TEXT,
        scanning_opr TEXT, created_at TEXT, transferred_at TEXT,
        last_active_folder_id INTEGER, project_key TEXT, template_json TEXT,
        last_transfer_state TEXT,
        last_transfer_error TEXT)''');
        await db.execute(
          '''CREATE TABLE capture_folders (
        id INTEGER PRIMARY KEY, box_id INTEGER, folder_seq INTEGER,
        cover_tag TEXT, image_tags TEXT, title TEXT, volume TEXT,
        start_date TEXT, end_date TEXT, archival_ref_no TEXT, record_type TEXT,
        is_complete INTEGER, folder_name TEXT, created_at TEXT, updated_at TEXT)''',
        );
        await db.execute('''CREATE TABLE capture_folder_images (
        id INTEGER PRIMARY KEY, box_id INTEGER, folder_id INTEGER,
        device_filename TEXT UNIQUE, assigned_at TEXT)''');
        await db.execute('''CREATE TABLE sync_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT, entity_key TEXT,
        op TEXT, payload TEXT, created_at TEXT, updated_at TEXT,
        attempts INTEGER DEFAULT 0, last_error TEXT, next_attempt_at TEXT)''');
        await db.execute(
          'CREATE UNIQUE INDEX idx_outbox_entity_key '
          'ON sync_outbox(entity, entity_key)',
        );
      },
    );
    await legacy.insert('capture_boxes', {
      'id': 7,
      'device_id': deviceId,
      'box_details': 'BOX-OLD',
      'status': 'transferred',
      'scanning_opr': 'operator',
      'created_at': '2026-07-01T00:00:00Z',
      'transferred_at': '2026-07-02T00:00:00Z',
      'project_key': 'project-key',
      'last_active_folder_id': 8,
      'template_json': '{"fields":[]}',
    });
    await legacy.insert('capture_boxes', {
      'id': 70,
      'device_id': deviceId,
      'box_details': 'ALREADY-SYNCED-HISTORY',
      'status': 'transferred',
      'scanning_opr': 'operator',
      'created_at': '2026-06-01T00:00:00Z',
      'transferred_at': '2026-06-02T00:00:00Z',
      'project_key': 'project-key',
    });
    await legacy.insert('capture_folders', {
      'id': 8,
      'box_id': 7,
      'folder_seq': 1,
      'folder_name': 'F-001',
      'is_complete': 1,
      'created_at': '2026-07-01T00:00:00Z',
      'updated_at': '2026-07-01T00:01:00Z',
    });
    await legacy.insert('capture_folder_images', {
      'id': 9,
      'box_id': 7,
      'folder_id': 8,
      'device_filename': 'IMG_1.jpg',
      'assigned_at': '2026-07-01T00:00:00Z',
    });
    await legacy.insert('sync_outbox', {
      'entity': 'capture_boxes',
      'entity_key': 'legacy-box-uid',
      'op': 'upsert',
      'payload': '{"id":7}',
      'created_at': '2026-07-01T00:00:00Z',
      'updated_at': '2026-07-01T00:01:00Z',
      'attempts': 2,
    });
    await legacy.close();

    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() => db.debugCloseAllForTests());
    final current = await db.getDatabase(deviceId);
    final migratedBox = (await current.query(
      'capture_boxes',
      where: 'id = ?',
      whereArgs: [7],
    )).single;
    expect(migratedBox['box_name'], 'BOX-OLD');
    expect(migratedBox['status'], 'TRANSFERRED');
    expect(migratedBox['last_active_folder_id'], 8);
    expect(migratedBox['template_json'], '{"fields":[]}');
    expect(
      (await current.query('capture_folders')).single['folder_name'],
      'F-001',
    );
    expect(
      (await current.query('capture_images')).single['image_name'],
      'IMG_1.jpg',
    );
    expect(
      (await current.rawQuery(
        "SELECT name FROM sqlite_master WHERE name='capture_folder_images'",
      )).isEmpty,
      isTrue,
    );
    expect(
      (await current.rawQuery(
        'PRAGMA table_info(capture_images)',
      )).any((r) => r['name'] == 'transferred_name'),
      isTrue,
    );
    final pending = await current.query('sync_outbox');
    expect(pending, hasLength(1));
    expect(pending.single['entity_key'], '7');
    expect(pending.single['attempts'], 2);
  });

  test(
    'snapshot rebuild preserves the damaged file, generates no outbox rows of '
    'its own, and CARRIES OVER the un-drained ones (they exist nowhere else — '
    'the PG snapshot being restored is by definition missing that work)',
    () async {
      final base = await _tempDir('stable_recovery_');
      const deviceId = 'SAX-RECOVER';
      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      db.syncEnabled = true;
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'OLD');
      await db.debugCloseAllForTests();

      await db.rebuildFromCaptureSnapshot(
        deviceId: deviceId,
        requireNonEmpty: true,
        pull:
            ({required onBoxes, required onFolders, required onImages}) async {
              await onBoxes(const [
                CaptureSnapshotBox(
                  id: 100,
                  boxName: 'RESTORED',
                  status: 'OPEN',
                  projectKey: 'pk',
                ),
              ]);
              await onFolders(const [
                CaptureSnapshotFolder(
                  id: 101,
                  boxId: 100,
                  folderSeq: 1,
                  folderName: 'RESTORED - 0001',
                ),
              ]);
              await onImages(const [
                CaptureSnapshotImage(
                  id: 102,
                  folderId: 101,
                  imageName: 'SAX-RECOVER_IMG_20260701_120000_001.jpg',
                  deviceId: deviceId,
                  fileFormat: 'jpg',
                ),
              ]);
              return const CaptureSnapshotCounts(
                boxes: 1,
                folders: 1,
                images: 1,
              );
            },
      );

      final current = await db.getDatabase(deviceId);
      expect(
        (await current.query('capture_boxes')).single['box_name'],
        'RESTORED',
      );
      expect(
        (await current.query('capture_images')).single['image_name'],
        'IMG_20260701_120000.jpg',
      );
      expect(
        (await current.query('capture_images')).single['transferred_name'],
        'SAX-RECOVER_IMG_20260701_120000_001.jpg',
      );
      // The pending push for the OLD box survives the rebuild...
      final outbox = await current.query('sync_outbox');
      expect(outbox, hasLength(1));
      expect(outbox.single['entity'], 'capture_boxes');
      // ...and the rebuild's own inserts add nothing (it writes rows straight
      // through, deliberately bypassing the outbox-enqueueing helpers — the
      // snapshot came FROM PostgreSQL, so echoing it back would be a loop).
      expect(outbox.single['entity_key'], isNot('100'));

      final backups = base
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'))
          .toList();
      expect(backups, isNotEmpty);
      db.syncEnabled = false;
      await db.debugCloseAllForTests();
    },
  );

  // The snapshot is pulled FROM PostgreSQL, so anything the cloud never had
  // is not in it. Promoting a replacement built only from that snapshot used
  // to silently destroy the local-only tables — un-drained sync_outbox rows
  // above all, which exist nowhere else at all.
  test(
    'snapshot rebuild carries over the local-only tables the cloud cannot '
    'restore (recapture history)',
    () async {
      final base = await _tempDir('stable_recovery_carryover_');
      const deviceId = 'SAX-CARRY';
      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);

      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'OLD');
      await db.insertReplacementRecord(
        deviceId: deviceId,
        sequenceIndex: 1,
        dateKey: '20260801',
        originalFilename: 'IMG_9.jpg',
        replacementFilename: 'IMG_9_r1.jpg',
        replacementLocalPath: 'C:/tmp/IMG_9_r1.jpg',
      );
      // upload_records/daily_summary are NOT seeded here: new rows rotate into
      // the monthly file, so the stable copy only ever holds the frozen
      // pre-rotation archive, which the public API cannot create. The
      // carry-over covers them the same way — this test pins the behaviour on
      // the table it can actually populate.
      await db.debugCloseAllForTests();

      await db.rebuildFromCaptureSnapshot(
        deviceId: deviceId,
        requireNonEmpty: true,
        pull:
            ({required onBoxes, required onFolders, required onImages}) async {
              await onBoxes(const [
                CaptureSnapshotBox(
                  id: 200,
                  boxName: 'RESTORED',
                  status: 'OPEN',
                  projectKey: 'pk',
                ),
              ]);
              await onFolders(const []);
              await onImages(const []);
              return const CaptureSnapshotCounts(
                boxes: 1,
                folders: 0,
                images: 0,
              );
            },
      );

      final current = await db.getDatabase(deviceId);
      expect(
        (await current.query('capture_boxes')).single['box_name'],
        'RESTORED',
        reason: 'the capture tables still come from the cloud snapshot',
      );
      expect(
        (await current.query('replacement_records')).single['original_filename'],
        'IMG_9.jpg',
        reason: 'recapture history is local-only and unrecoverable from PG',
      );
      await db.debugCloseAllForTests();
    },
  );

  test('failed recovery leaves the original database in place', () async {
    final base = await _tempDir('stable_recovery_failure_');
    const deviceId = 'SAX-RECOVER-FAIL';
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'ORIGINAL');

    await expectLater(
      db.rebuildFromCaptureSnapshot(
        deviceId: deviceId,
        requireNonEmpty: true,
        pull:
            ({required onBoxes, required onFolders, required onImages}) async {
              await onBoxes(const [
                CaptureSnapshotBox(
                  id: 1,
                  boxName: 'REPLACEMENT',
                  status: 'OPEN',
                ),
              ]);
              await onFolders(const [
                CaptureSnapshotFolder(id: 2, boxId: 1, folderSeq: 1),
              ]);
              await onImages(const [
                CaptureSnapshotImage(
                  id: 3,
                  folderId: 2,
                  imageName: 'not-reversible.jpg',
                  deviceId: deviceId,
                  fileFormat: 'jpg',
                ),
              ]);
              return const CaptureSnapshotCounts(
                boxes: 1,
                folders: 1,
                images: 1,
              );
            },
      ),
      throwsStateError,
    );

    final current = await db.getDatabase(deviceId);
    expect(
      (await current.query('capture_boxes')).single['box_name'],
      'ORIGINAL',
    );
    await db.debugCloseAllForTests();
  });

  test('empty cloud history cannot replace an existing database', () async {
    final base = await _tempDir('stable_recovery_empty_');
    const deviceId = 'SAX-RECOVER-EMPTY';
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'ORIGINAL');

    await expectLater(
      db.rebuildFromCaptureSnapshot(
        deviceId: deviceId,
        requireNonEmpty: true,
        pull:
            ({required onBoxes, required onFolders, required onImages}) async =>
                const CaptureSnapshotCounts(boxes: 0, folders: 0, images: 0),
      ),
      throwsStateError,
    );

    final current = await db.getDatabase(deviceId);
    expect(
      (await current.query('capture_boxes')).single['box_name'],
      'ORIGINAL',
    );
    await db.debugCloseAllForTests();
  });
}
