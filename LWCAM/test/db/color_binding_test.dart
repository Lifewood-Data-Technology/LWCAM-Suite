import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late UploadStatsDB store;
  late Directory root;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('color_bind_');
    store = UploadStatsDB()..debugOverrideBaseFolderForTests(root.path);
  });
  tearDown(() async {
    await store.debugCloseAllForTests();
    await root.delete(recursive: true);
  });
  Map<String, dynamic> binding(String value) => {
    'profile': sha256.convert(utf8.encode(value)).toString(),
    'payload': value,
    'bound_at': '2026-10-19T10:00:00',
  };
  test(
    'v2 migration keeps old records and marks legacy pages historical',
    () async {
      final db = await store.getDatabase('station');
      for (final table in [
        'color_profiles',
        'color_bindings',
        'color_integrity',
        'color_pending',
      ]) {
        await db.execute('DROP TABLE $table');
      }
      await db.setVersion(2);
      await store.debugCloseAllForTests();
      final reopened = await store.getDatabase('station');
      expect(await reopened.getVersion(), 3);
      expect(
        (await store.colorBindingFor('station', 'old.jpg'))['reason'],
        'historical',
      );
    },
  );
  test('page snapshots survive restart and later profile changes', () async {
    final first = binding('{"profile_id":"first"}');
    final second = binding('{"profile_id":"second"}');
    await store.saveColorBinding('station', 'a.jpg', first);
    await store.saveColorBinding('station', 'b.jpg', second);
    await store.debugCloseAllForTests();
    expect(await store.colorBindingFor('station', 'a.jpg'), first);
    expect(await store.colorBindingFor('station', 'b.jpg'), second);
  });
  test(
    'tampered or missing profile cannot silently disable correction',
    () async {
      final value = binding('{"profile_id":"first"}');
      await store.saveColorBinding('station', 'a.jpg', value);
      final db = await store.getDatabase('station');
      await db.update('color_profiles', {'payload': '{}'});
      await expectLater(
        store.colorBindingFor('station', 'a.jpg'),
        throwsStateError,
      );
      await db.delete('color_profiles');
      await expectLater(
        store.colorBindingFor('station', 'a.jpg'),
        throwsStateError,
      );
      await expectLater(
        store.saveColorBinding('station', 'b.jpg', {...value, 'payload': '{}'}),
        throwsStateError,
      );
    },
  );
  test(
    'interrupted replacement blocks transfer until binding commit',
    () async {
      final first = binding('{"profile_id":"first"}');
      await store.saveColorBinding('station', 'a.jpg', first);
      await store.markColorReplacementPending('station', 'a.jpg');
      await store.debugCloseAllForTests();
      await expectLater(
        store.colorBindingFor('station', 'a.jpg'),
        throwsStateError,
      );
      final replacement = binding('{"profile_id":"replacement"}');
      await store.saveColorBinding('station', 'a.jpg', replacement);
      expect(await store.colorBindingFor('station', 'a.jpg'), replacement);
    },
  );
  test(
    'incomplete recovery blocks marker data instead of losing calibration',
    () async {
      final db = await store.getDatabase('station');
      await db.insert('color_integrity', {'id': 1, 'reason': 'damaged ledger'});
      await expectLater(
        store.colorBindingFor('station', 'a.jpg'),
        throwsStateError,
      );
    },
  );
  test(
    'recovery integrity is checked per folder and can be resolved explicitly',
    () async {
      final boxId = await store.insertCaptureBox(
        deviceId: 'station',
        boxDetails: 'BOX',
      );
      final folderId = await store.insertCaptureFolder(
        deviceId: 'station',
        folder: CaptureFolder(boxId: boxId, title: 'T', volume: 'V'),
        isComplete: true,
      );
      await store.assignImageToFolder(
        deviceId: 'station',
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'a.jpg',
      );
      final db = await store.getDatabase('station');
      await db.delete('color_bindings');
      await db.insert('color_integrity', {
        'id': 1,
        'reason': 'damaged ledger',
      });

      final check = await store.checkFolderColorCalibration('station', folderId);
      expect(check.issues, hasLength(1));
      expect(check.issues.single.kind, ColorCalibrationIssueKind.unknownBinding);
      expect(check.issues.single.reason, 'damaged ledger');

      expect(
        await store.bindHistoricalIfUnbound('station', folderId),
        1,
      );
      final after = await store.checkFolderColorCalibration('station', folderId);
      expect(after.issues, isEmpty);
      expect(after.marker['images']['a.jpg']['reason'], 'historical');
      expect(
        await store.clearColorIntegrityIfOpenPagesBound('station'),
        isTrue,
      );
      expect(await db.query('color_integrity'), isEmpty);
    },
  );
  test(
    'a mixed folder keeps the bound profile and only resolves the unbound page',
    () async {
      final boxId = await store.insertCaptureBox(
        deviceId: 'station',
        boxDetails: 'BOX',
      );
      final folderId = await store.insertCaptureFolder(
        deviceId: 'station',
        folder: CaptureFolder(boxId: boxId, title: 'T', volume: 'V'),
        isComplete: true,
      );
      final payload = '{"profile_id":"p"}';
      final hash = sha256.convert(utf8.encode(payload)).toString();
      await store.assignImageToFolder(
        deviceId: 'station',
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'a.jpg',
        colorBinding: {
          'profile': hash,
          'payload': payload,
          'bound_at': '2026-10-19T10:00:00',
        },
      );
      await store.assignImageToFolder(
        deviceId: 'station',
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'b.jpg',
      );
      final db = await store.getDatabase('station');
      await db.delete(
        'color_bindings',
        where: 'image_name = ?',
        whereArgs: ['b.jpg'],
      );
      await db.insert('color_integrity', {'id': 1, 'reason': 'lost'});

      final check = await store.checkFolderColorCalibration('station', folderId);
      expect(check.issues.single.imageName, 'b.jpg');
      expect(check.marker['images']['a.jpg']['profile'], hash);
      expect(check.marker['profiles'][hash], payload);
      expect(check.marker['images'].containsKey('b.jpg'), isFalse);

      expect(await store.bindHistoricalIfUnbound('station', folderId), 1);
      final after = await store.checkFolderColorCalibration('station', folderId);
      expect(after.issues, isEmpty);
      expect(after.marker['images']['a.jpg']['profile'], hash);
      expect(after.marker['images']['b.jpg']['reason'], 'historical');
    },
  );
  test('a damaged profile stays blocking and is never overwritten', () async {
    final boxId = await store.insertCaptureBox(
      deviceId: 'station',
      boxDetails: 'BOX',
    );
    final folderId = await store.insertCaptureFolder(
      deviceId: 'station',
      folder: CaptureFolder(boxId: boxId, title: 'T', volume: 'V'),
      isComplete: true,
    );
    final payload = '{"profile_id":"p"}';
    final hash = sha256.convert(utf8.encode(payload)).toString();
    await store.assignImageToFolder(
      deviceId: 'station',
      boxId: boxId,
      folderId: folderId,
      deviceFilename: 'a.jpg',
      colorBinding: {'profile': hash, 'payload': payload},
    );
    final db = await store.getDatabase('station');
    await db.delete('color_profiles');
    await db.insert('color_integrity', {'id': 1, 'reason': 'lost'});

    final check = await store.checkFolderColorCalibration('station', folderId);
    expect(check.issues.single.kind, ColorCalibrationIssueKind.damagedBinding);
    expect(await store.bindHistoricalIfUnbound('station', folderId), 0);
    expect(await db.query('color_bindings'), hasLength(1));
    await expectLater(
      store.folderColorCalibration('station', folderId),
      throwsStateError,
    );
    expect(
      await store.clearColorIntegrityIfOpenPagesBound('station'),
      isFalse,
    );
  });
  test('an interrupted recapture aborts the whole historical accept', () async {
    final boxId = await store.insertCaptureBox(
      deviceId: 'station',
      boxDetails: 'BOX',
    );
    final folderId = await store.insertCaptureFolder(
      deviceId: 'station',
      folder: CaptureFolder(boxId: boxId, title: 'T', volume: 'V'),
      isComplete: true,
    );
    await store.assignImageToFolder(
      deviceId: 'station',
      boxId: boxId,
      folderId: folderId,
      deviceFilename: 'a.jpg',
    );
    final db = await store.getDatabase('station');
    await db.delete('color_bindings');
    await db.insert('color_integrity', {'id': 1, 'reason': 'lost'});
    await store.markColorReplacementPending('station', 'a.jpg');

    final check = await store.checkFolderColorCalibration('station', folderId);
    expect(check.issues.single.kind, ColorCalibrationIssueKind.pendingRecapture);
    await expectLater(
      store.bindHistoricalIfUnbound('station', folderId),
      throwsStateError,
    );
    expect(await db.query('color_bindings'), isEmpty);
  });
  test('integrity clears only when every OPEN page is bound', () async {
    final firstBox = await store.insertCaptureBox(
      deviceId: 'station',
      boxDetails: 'FIRST',
    );
    final firstFolder = await store.insertCaptureFolder(
      deviceId: 'station',
      folder: CaptureFolder(boxId: firstBox, title: 'T', volume: 'V'),
      isComplete: true,
    );
    await store.assignImageToFolder(
      deviceId: 'station',
      boxId: firstBox,
      folderId: firstFolder,
      deviceFilename: 'a.jpg',
    );
    final secondBox = await store.insertCaptureBox(
      deviceId: 'station',
      boxDetails: 'SECOND',
    );
    final secondFolder = await store.insertCaptureFolder(
      deviceId: 'station',
      folder: CaptureFolder(boxId: secondBox, title: 'T', volume: 'V'),
      isComplete: true,
    );
    await store.assignImageToFolder(
      deviceId: 'station',
      boxId: secondBox,
      folderId: secondFolder,
      deviceFilename: 'b.jpg',
    );
    final db = await store.getDatabase('station');
    await db.delete('color_bindings');
    await db.insert('color_integrity', {'id': 1, 'reason': 'lost'});

    await store.bindHistoricalIfUnbound('station', firstFolder);
    expect(
      await store.clearColorIntegrityIfOpenPagesBound('station'),
      isFalse,
      reason: 'the second OPEN box is still unbound',
    );
    await store.bindHistoricalIfUnbound('station', secondFolder);
    expect(await store.clearColorIntegrityIfOpenPagesBound('station'), isTrue);
    expect(await db.query('color_integrity'), isEmpty);
  });

  test(
    'folder preflight reads only its own pages and their profiles',
    () async {
      final boxId = await store.insertCaptureBox(
        deviceId: 'station',
        boxDetails: 'BOX',
      );
      Future<int> folderWith(List<String> names, String volume) async {
        final folderId = await store.insertCaptureFolder(
          deviceId: 'station',
          folder: CaptureFolder(boxId: boxId, title: 'T', volume: volume),
          isComplete: true,
        );
        for (final name in names) {
          await store.assignImageToFolder(
            deviceId: 'station',
            boxId: boxId,
            folderId: folderId,
            deviceFilename: name,
            colorBinding: binding('{"shared":1}'),
          );
        }
        return folderId;
      }

      final mine = await folderWith(['a.jpg', 'b.jpg'], 'A');
      await folderWith(['c.jpg', 'd.jpg'], 'B');
      final db = await store.getDatabase('station');
      // Another folder's damaged binding and pending page are not this
      // folder's problem; history from other folders is not read at all.
      await db.update('color_bindings', {'binding_json': '{bad'},
          where: 'image_name = ?', whereArgs: ['c.jpg']);
      await store.markColorReplacementPending('station', 'd.jpg');
      for (var i = 0; i < 1500; i++) {
        await db.insert('color_bindings', {
          'image_name': 'history_$i.jpg',
          'binding_json': jsonEncode({'profile': null, 'reason': 'historical'}),
        });
      }

      final check = await store.checkFolderColorCalibration('station', mine);
      expect(check.issues, isEmpty);
      final shared = binding('{"shared":1}')['profile'] as String;
      expect(check.marker['profiles'], {shared: '{"shared":1}'});
      expect((check.marker['images'] as Map).keys.toSet(), {'a.jpg', 'b.jpg'});

      // A referenced profile that is really missing is still reported.
      await db.delete('color_profiles');
      final broken = await store.checkFolderColorCalibration('station', mine);
      expect(broken.issues.map((i) => i.reason).toSet(), {'missing profile payload'});
    },
  );
}
