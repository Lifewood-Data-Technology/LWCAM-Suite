import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/color_capture_session.dart';
import 'package:lwcam/services/color_rework_store.dart';
import 'package:lwcam/services/processing_marker_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late UploadStatsDB db;
  const folderKey = 'project|BOX|1';
  const cloudFolder = r'C:\LWIP\2.Batches\20261028\Volume';
  late String target;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('metadata_rework_');
    db = UploadStatsDB()..debugOverrideBaseFolderForTests(root.path);
    // Deliberately absent: local checks must never need this input directory.
    target = p.join(
      root.path,
      'offline-input',
      '20261028',
      'Volume',
      'page.jpg',
    );
  });
  tearDown(() async {
    await db.debugCloseAllForTests();
    await root.delete(recursive: true);
  });

  Future<File> stage({String? path, String key = folderKey}) async {
    final shot = await File(p.join(root.path, 'shot.jpg')).writeAsBytes([1, 2]);
    return ColorReworkStore.stage(
      'station',
      path ?? target,
      shot,
      ColorBinding.none('disabled'),
      folderKey: key,
    );
  }

  Future<void> check({Iterable<File> completing = const []}) =>
      ColorReworkStore.assertMetadataSafe(
        'station',
        folderKey: folderKey,
        folderPath: cloudFolder,
        completing: completing,
      );

  test('no intent and no input directory allow metadata', () async {
    await check();
    expect(await Directory(p.dirname(target)).exists(), isFalse);
  });

  test(
    'unapplied abandoned staging allows metadata without source bytes',
    () async {
      final staged = await stage();
      await staged.delete();
      await File('${staged.path}.color.json').delete();
      await check();
    },
  );

  test('normal Undo allows metadata with the share absent', () async {
    // Production discard uses the explicit not-started protocol too.
    final staged = await stage();
    await ColorReworkStore.discardStaged(staged);
    await check();
  });

  test(
    'applying blocks metadata before any remote marker could be written',
    () async {
      await stage();
      await ColorReworkStore.beginApply('station', target);
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'applying survives a fresh local read and a changed share path',
    () async {
      await stage(path: p.join(root.path, 'old-share', 'page.jpg'));
      await ColorReworkStore.beginApply(
        'station',
        p.join(root.path, 'old-share', 'page.jpg'),
      );
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'an applying sibling not in the current worklist blocks the folder',
    () async {
      final sibling = p.join(p.dirname(target), 'sibling.jpg');
      await stage(path: sibling);
      await ColorReworkStore.beginApply('station', sibling);
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'only the successfully installed generation can finish with metadata',
    () async {
      final first = await stage();
      await ColorReworkStore.beginApply('station', target);
      await check(completing: [first]);
      final newer = await stage();
      await expectLater(check(completing: [first]), throwsStateError);
      await check(completing: [newer]);
    },
  );

  test('another folder and another device do not block metadata', () async {
    final other = p.join(root.path, 'other', '20261028', 'Other', 'page.jpg');
    await stage(path: other, key: 'project|BOX|2');
    await ColorReworkStore.beginApply('station', other);
    final shot = File(p.join(root.path, 'shot.jpg'));
    await ColorReworkStore.stage(
      'other-station',
      target,
      shot,
      ColorBinding.none('disabled'),
      folderKey: folderKey,
    );
    await ColorReworkStore.beginApply('other-station', target);
    await check();
  });

  test(
    'legacy intent without folder identity matches across input/output roots',
    () async {
      final staged = await stage();
      final intent = File(p.join(staged.parent.path, 'intent.json'));
      final data = jsonDecode(await intent.readAsString()) as Map;
      data.remove('folder_key');
      data['applying'] = true;
      await intent.writeAsString(jsonEncode(data));
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'legacy ambiguous intent with unavailable source needs recovery',
    () async {
      final staged = await stage();
      final intent = File(p.join(staged.parent.path, 'intent.json'));
      final data = jsonDecode(await intent.readAsString()) as Map;
      data.remove('apply_protocol');
      await intent.writeAsString(jsonEncode(data));
      await expectLater(check(), throwsStateError);
      expect(await intent.exists(), isTrue);
    },
  );

  test(
    'corrupt owned intent cannot be mistaken for no interrupted work',
    () async {
      final staged = await stage();
      await File(
        p.join(staged.parent.path, 'intent.json'),
      ).writeAsString('{bad');
      await expectLater(check(), throwsStateError);
    },
  );

  Future<File> legacy({bool held = false}) async {
    await Directory(p.dirname(target)).create(recursive: true);
    await File(target).writeAsBytes([9]);
    await File(
      p.join(p.dirname(target), kProcessingMarkerName),
    ).writeAsString(jsonEncode({'rework_in_progress': held}));
    final staged = await stage();
    final intent = File(p.join(staged.parent.path, 'intent.json'));
    final data = jsonDecode(await intent.readAsString()) as Map;
    data.remove('apply_protocol');
    await intent.writeAsString(jsonEncode(data));
    return staged;
  }

  test('readable legacy abandoned staging remains recoverable', () async {
    final staged = await legacy();
    await staged.delete();
    await check();
  });

  test(
    'legacy held marker blocks metadata even before the photo changed',
    () async {
      await legacy(held: true);
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'restaging legacy held marker preserves the interrupted operation',
    () async {
      await legacy(held: true);
      await stage();
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'restaging ambiguous legacy work offline retains its original intent',
    () async {
      final staged = await stage();
      final intent = File(p.join(staged.parent.path, 'intent.json'));
      final data = jsonDecode(await intent.readAsString()) as Map;
      data.remove('apply_protocol');
      await intent.writeAsString(jsonEncode(data));
      final before = await intent.readAsString();
      await expectLater(stage(), throwsStateError);
      expect(await intent.readAsString(), before);
    },
  );

  test(
    'committed receipt permits metadata after failed intent cleanup',
    () async {
      final staged = await stage();
      await ColorReworkStore.beginApply('station', target);
      final local = await db.getDatabase('station');
      await local.transaction(
        (txn) => ColorReworkStore.recordCommitted(txn, staged),
      );
      await check();
      expect(
        await ColorReworkStore.recoverApplying('station', target),
        isNull,
        reason: 'page entry must not resurrect an already committed photo',
      );
    },
  );

  test(
    'rolled back receipt cannot exempt an uncommitted replacement',
    () async {
      final staged = await stage();
      await ColorReworkStore.beginApply('station', target);
      final local = await db.getDatabase('station');
      await expectLater(
        local.transaction((txn) async {
          await ColorReworkStore.recordCommitted(txn, staged);
          throw StateError('closure rollback');
        }),
        throwsStateError,
      );
      await expectLater(check(), throwsStateError);
    },
  );

  test(
    'old committed receipt never exempts a newer applying generation',
    () async {
      final first = await stage();
      await ColorReworkStore.beginApply('station', target);
      final local = await db.getDatabase('station');
      await local.transaction(
        (txn) => ColorReworkStore.recordCommitted(txn, first),
      );
      await stage();
      await ColorReworkStore.beginApply('station', target);
      await expectLater(check(), throwsStateError);
      expect(
        await ColorReworkStore.recoverApplying('station', target),
        isNotNull,
      );
    },
  );

  test(
    'restaging after committed cleanup failure starts an unapplied generation',
    () async {
      final first = await stage();
      await ColorReworkStore.beginApply('station', target);
      final local = await db.getDatabase('station');
      await local.transaction(
        (txn) => ColorReworkStore.recordCommitted(txn, first),
      );
      final next = await stage();
      await check();
      expect(await ColorReworkStore.recoverApplying('station', target), isNull);
      await ColorReworkStore.discardStaged(next);
    },
  );

  test(
    'committed recovery does not require the old staged bytes to survive',
    () async {
      final first = await stage();
      await ColorReworkStore.beginApply('station', target);
      final local = await db.getDatabase('station');
      await local.transaction(
        (txn) => ColorReworkStore.recordCommitted(txn, first),
      );
      await first.delete();
      await File('${first.path}.color.json').delete();
      expect(await ColorReworkStore.recoverApplying('station', target), isNull);
      await check();
    },
  );
}
