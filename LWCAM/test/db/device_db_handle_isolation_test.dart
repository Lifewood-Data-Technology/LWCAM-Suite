import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Pins that one device's DB handle can never be served for another device.
///
/// The singleton used to hold ONE handle plus a `_currentDeviceId` string,
/// closing and reopening on every switch. The id was assigned before the open
/// finished, so two concurrent switches to different devices could leave the
/// cached id naming one device and the cached handle pointing at another
/// device's file — after which every query for the "matching" id silently ran
/// against the wrong database. Login can trigger exactly that interleaving —
/// two device DB opens racing each other — so a still-open box vanished from
/// the box list after an account switch (observed live 2026-07-31).

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

/// The device id every row in [deviceId]'s DB carries, read back through a
/// freshly acquired handle.
Future<List<String>> _boxOwners(UploadStatsDB db, String deviceId) async {
  final handle = await db.getDatabase(deviceId);
  final rows = await handle.query('capture_boxes', columns: ['device_id']);
  return rows.map((r) => r['device_id'] as String).toList();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('per-device DB handle isolation', () {
    test('concurrent getDatabase calls for different devices each return their '
        'OWN database', () async {
      final db = await _freshDb('handle_race_');

      // The interleaving from login: several device ids opened at once.
      final handles = await Future.wait([
        db.getDatabase('SAX04'),
        db.getDatabase('SAX01'),
        db.getDatabase('SAX07'),
      ]);

      expect(handles[0].path, contains('lwcam_stats_SAX04.db'));
      expect(handles[1].path, contains('lwcam_stats_SAX01.db'));
      expect(handles[2].path, contains('lwcam_stats_SAX07.db'));

      // Distinct files ⇒ distinct handles.
      expect(handles.map((h) => h.path).toSet(), hasLength(3));
    });

    test('concurrent calls for the SAME device share one handle (no leaked '
        'duplicate open)', () async {
      final db = await _freshDb('handle_single_flight_');

      final handles = await Future.wait([
        db.getDatabase('SAX01'),
        db.getDatabase('SAX01'),
        db.getDatabase('SAX01'),
      ]);

      expect(handles[1], same(handles[0]));
      expect(handles[2], same(handles[0]));
    });

    test("a box captured on one device stays visible after the other device's "
        'DB is opened concurrently', () async {
      final db = await _freshDb('handle_box_visibility_');

      // SAX04 captures a box and leaves it OPEN (no transfer).
      final boxId = await db.insertCaptureBox(
        deviceId: 'SAX04',
        boxDetails: '111 2222-3333',
        scanningOpr: 'lance',
        projectKey: 'pk1',
        projectId: 'PRJ-1',
      );

      // Operator switches to SAX01, which captures and transfers its own box.
      // Both opens are in flight at once, exactly as login triggers them.
      await Future.wait([
        db.getDatabase('SAX01'),
        db.getDatabase('SAX04'),
      ]);
      await db.insertCaptureBox(
        deviceId: 'SAX01',
        boxDetails: '222 3333-4444',
        scanningOpr: 'jamie',
        projectKey: 'pk1',
        projectId: 'PRJ-1',
      );

      // Back to SAX04: the box must still be there, in SAX04's own DB.
      final boxes = await db.getCaptureBoxes('SAX04', projectKey: 'pk1');
      expect(boxes.map((b) => b.id), contains(boxId));
      expect(boxes.single.boxDetails, '111 2222-3333');

      // And neither DB may have absorbed the other's rows.
      expect(await _boxOwners(db, 'SAX04'), ['SAX04']);
      expect(await _boxOwners(db, 'SAX01'), ['SAX01']);
    });
  });
}
