import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
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
}
