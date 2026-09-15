import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

Future<Set<String>> _indexNames(dynamic db) async {
  final rows =
      await db.rawQuery("SELECT name FROM sqlite_master WHERE type='index'");
  return rows.map<String>((r) => r['name'] as String).toSet();
}

const _deviceIndexes = {
  'idx_ur_device_filename',
  'idx_ur_opr_created',
  'idx_ds_device_opr_date',
  'idx_rr_device_original',
  'idx_ci_box',
};

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('device DB indexes', () {
    test('fresh device DB has all five hot-query indexes', () async {
      final base = await _tempDir('idx_fresh_');
      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      addTearDown(() => db.debugCloseAllForTests());

      final fresh = await db.getDatabase('devFresh10');
      expect(await fresh.getVersion(), 2);
      expect(await _indexNames(fresh), containsAll(_deviceIndexes));
    });

    test('re-opening a device DB keeps the indexes (idempotent)', () async {
      final base = await _tempDir('idx_reopen_');
      final db = UploadStatsDB();
      db.debugOverrideBaseFolderForTests(base.path);
      addTearDown(() => db.debugCloseAllForTests());

      final first = await db.getDatabase('devReopen');
      expect(await _indexNames(first), containsAll(_deviceIndexes));

      await db.debugCloseAllForTests();
      final second = await db.getDatabase('devReopen');
      expect(await second.getVersion(), 2);
      expect(await _indexNames(second), containsAll(_deviceIndexes));
    });
  });
}
