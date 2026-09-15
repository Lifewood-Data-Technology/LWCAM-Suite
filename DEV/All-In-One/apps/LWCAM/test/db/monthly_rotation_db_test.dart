import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Future<UploadStatsDB> _freshDb(String prefix, {bool syncEnabled = false}) async {
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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('monthly DB rotation', () {
    test('first insertUploadRecord creates the monthly file with the right '
        'schema/indexes; stable DB upload_records stays untouched', () async {
      final db = await _freshDb('monthly_create_');
      const deviceId = 'SAX01';

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_1.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 7, 18),
      );

      final monthly =
          await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 7, 18));
      expect(await monthly.query('upload_records'), hasLength(1));

      final indexNames = (await monthly
              .rawQuery("SELECT name FROM sqlite_master WHERE type='index'"))
          .map((r) => r['name'] as String)
          .toSet();
      expect(
        indexNames,
        containsAll({
          'idx_ur_device_filename',
          'idx_ur_opr_created',
          'idx_ds_device_opr_date',
        }),
      );
      // Monthly files no longer carry an outbox — upload_records left the
      // sync pipeline, so the stable DB holds the only sync_outbox.
      final monthlyTables = (await monthly
              .rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
          .map((r) => r['name'] as String)
          .toSet();
      expect(monthlyTables, isNot(contains('sync_outbox')));

      final stable = await db.getDatabase(deviceId);
      expect(await stable.query('upload_records'), isEmpty);
    });

    test('month routing: two inserts in different months land in two '
        'separate files, each with its own daily_summary', () async {
      final db = await _freshDb('monthly_routing_');
      const deviceId = 'SAX01';

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_JAN.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 1, 5),
      );
      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_MAR.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 3, 9),
      );

      final jan = await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 1, 5));
      final mar = await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 3, 9));

      expect((await jan.query('upload_records')).single['filename'], 'IMG_JAN.jpg');
      expect((await mar.query('upload_records')).single['filename'], 'IMG_MAR.jpg');
      expect((await jan.query('daily_summary')).single['date'], '2026-01-05');
      expect((await mar.query('daily_summary')).single['date'], '2026-03-09');
    });

    test('a session spanning a month rollover just opens/creates the new '
        'month file on its own — no explicit rollover handling needed',
        () async {
      final db = await _freshDb('monthly_rollover_');
      const deviceId = 'SAX01';

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_JUL.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 7, 31, 23, 59),
      );
      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_AUG.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 8, 1, 0, 1),
      );

      final jul = await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 7, 31));
      final aug = await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 8, 1));
      expect((await jul.query('upload_records')).single['filename'], 'IMG_JUL.jpg');
      expect((await aug.query('upload_records')).single['filename'], 'IMG_AUG.jpg');
    });

    test('dedup spans months + the stable DB legacy archive: a filename '
        'already recorded anywhere is skipped, a fresh one still inserts',
        () async {
      final base = await _tempDir('monthly_dedup_');
      const deviceId = 'SAX01';

      // Hand-build a stable DB with a LEGACY upload_records row (as if
      // written before this device ever rotated).
      final stablePath = p.join(base.path, 'lwcam_stats_$deviceId.db');
      final legacyDb = await openDatabase(
        stablePath,
        version: 1,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE upload_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT, scanning_opr TEXT, device_id TEXT,
              box_details TEXT, filename TEXT, format TEXT, created_at TEXT)
          ''');
          await d.execute('''
            CREATE TABLE daily_summary (
              id INTEGER PRIMARY KEY AUTOINCREMENT, scanning_opr TEXT, device_id TEXT,
              date TEXT, total_count INTEGER)
          ''');
          await d.execute('''
            CREATE TABLE replacement_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT, original_filename TEXT)
          ''');
        },
      );
      await legacyDb.insert('upload_records', {
        'scanning_opr': 'alice',
        'device_id': deviceId,
        'box_details': 'BOX-1',
        'filename': 'IMG_LEGACY.jpg',
        'format': 'jpg',
        'created_at': DateTime(2025, 12, 1).toIso8601String(),
      });
      await legacyDb.close();

      // Hand-build a PREVIOUS monthly file with another already-recorded
      // filename.
      final prevMonthPath = p.join(base.path, 'lwcam_stats_${deviceId}_2026-05.db');
      final prevDb = await openDatabase(
        prevMonthPath,
        version: 1,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE upload_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT, scanning_opr TEXT, device_id TEXT,
              box_details TEXT, filename TEXT, format TEXT, created_at TEXT)
          ''');
        },
      );
      await prevDb.insert('upload_records', {
        'scanning_opr': 'alice',
        'device_id': deviceId,
        'box_details': 'BOX-1',
        'filename': 'IMG_MAY.jpg',
        'format': 'jpg',
        'created_at': DateTime(2026, 5, 1).toIso8601String(),
      });
      await prevDb.close();

      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      addTearDown(() => db.debugCloseAllForTests());

      // Re-inserting the legacy filename (targeting its own historical
      // month) is skipped.
      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_LEGACY.jpg',
        format: 'jpg',
        createdAt: DateTime(2025, 12, 1),
      );
      // Re-inserting the May filename, dated for its OWN recorded month, is
      // caught — dedup checks the target month's own file.
      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_MAY.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 5, 1),
      );
      // A genuinely new filename still inserts (dated "now").
      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_NEW.jpg',
        format: 'jpg',
        createdAt: DateTime.now(),
      );

      final stable = await db.getDatabase(deviceId);
      expect(await stable.query('upload_records'), hasLength(1)); // legacy row untouched

      final may = await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 5, 1));
      expect(await may.query('upload_records'), hasLength(1)); // not duplicated

      final currentMonth = await db.getMonthlyDatabase(deviceId);
      final currentFilenames = (await currentMonth.query('upload_records'))
          .map((r) => r['filename'] as String)
          .toSet();
      expect(currentFilenames, {'IMG_NEW.jpg'});
    });

    test('getUploadedBaseNames unions the stable legacy archive with every '
        'monthly file', () async {
      final base = await _tempDir('monthly_basenames_');
      const deviceId = 'SAX01';

      final stablePath = p.join(base.path, 'lwcam_stats_$deviceId.db');
      final legacyDb = await openDatabase(
        stablePath,
        version: 1,
        onCreate: (d, v) async {
          await d.execute('''
            CREATE TABLE upload_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT, scanning_opr TEXT, device_id TEXT,
              box_details TEXT, filename TEXT, format TEXT, created_at TEXT)
          ''');
          await d.execute('''
            CREATE TABLE daily_summary (
              id INTEGER PRIMARY KEY AUTOINCREMENT, scanning_opr TEXT, device_id TEXT,
              date TEXT, total_count INTEGER)
          ''');
          await d.execute('''
            CREATE TABLE replacement_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT, device_id TEXT, original_filename TEXT)
          ''');
        },
      );
      await legacyDb.insert('upload_records', {
        'scanning_opr': 'alice', 'device_id': deviceId, 'box_details': 'BOX-1',
        'filename': '${deviceId}_IMG_20251201_100000_001.jpg', 'format': 'jpg',
        'created_at': DateTime(2025, 12, 1).toIso8601String(),
      });
      await legacyDb.close();

      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      addTearDown(() => db.debugCloseAllForTests());

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: '${deviceId}_IMG_20260718_100000_001.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 7, 18),
      );

      final baseNames = await db.getUploadedBaseNames(deviceId);
      expect(
        baseNames,
        containsAll({
          '${deviceId}_IMG_20251201_100000',
          '${deviceId}_IMG_20260718_100000',
        }),
      );
    });

    test('insertUploadRecord with sync ON writes the record but NO outbox row '
        'anywhere — upload_records is local-only now', () async {
      final db = await _freshDb('monthly_outbox_atomic_', syncEnabled: true);
      const deviceId = 'SAX01';

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_1.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 4, 4),
      );

      final monthly = await db.getMonthlyDatabase(deviceId, forDate: DateTime(2026, 4, 4));
      expect(await monthly.query('upload_records'), hasLength(1));

      final stable = await db.getDatabase(deviceId);
      expect(
        await stable.query('sync_outbox', where: "entity = 'upload_records'"),
        isEmpty,
      );
    });

    test('getOutboxDatabases never includes a monthly file — only stable DBs '
        'carry an outbox', () async {
      final db = await _freshDb('monthly_outbox_sources_', syncEnabled: true);
      const deviceId = 'SAX01';

      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_1.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 4, 4),
      );

      final sources = await db.getOutboxDatabases(deviceId);
      expect(sources, hasLength(1));
      final stable = await db.getDatabase(deviceId);
      expect(sources.single, same(stable));
    });
  });
}
