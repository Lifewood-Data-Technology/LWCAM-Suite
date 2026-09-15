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

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('fresh device DB has the 8 keyed-metadata snapshot columns on upload_records', () async {
    final base = await _tempDir('meta_fresh_');
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() => db.debugCloseAllForTests());

    final database = await db.getDatabase('devFresh');
    final cols = (await database.rawQuery('PRAGMA table_info(upload_records)'))
        .map((r) => r['name'] as String)
        .toSet();
    expect(cols, containsAll(['cover_tag', 'image_tags', 'title', 'volume', 'start_date', 'end_date', 'archival_ref_no', 'record_type']));
  });

  test('insertUploadRecord persists metadata snapshot columns', () async {
    final base = await _tempDir('meta_snapshot_');
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() => db.debugCloseAllForTests());
    const dev = 'devSnapshot';

    await db.insertUploadRecord(
      deviceId: dev,
      scanningOpr: 'alice',
      boxDetails: 'BOX-1',
      filename: 'SAX01_IMG_x_001.jpg',
      format: 'jpg',
      createdAt: DateTime(2026, 2, 2),
      coverTag: 'Cover Will Be Captured',
      title: 'WWII Medical Files',
      volume: 'Vol Z',
      startDate: '1939',
      endDate: '1945',
      recordType: 'Military Medical Records',
    );
    // Monthly rotation: upload_records lives in the createdAt month's file.
    final database = await db.getMonthlyDatabase(dev, forDate: DateTime(2026, 2, 2));
    final row = (await database.query('upload_records')).single;
    expect(row['title'], 'WWII Medical Files');
    expect(row['record_type'], 'Military Medical Records');
    expect(row['start_date'], '1939');
  });
}
