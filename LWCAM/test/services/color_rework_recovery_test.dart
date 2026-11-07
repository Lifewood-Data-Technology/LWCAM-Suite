import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/color_capture_session.dart';
import 'package:lwcam/services/color_rework_store.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory root;
  late UploadStatsDB db;
  const folderKey = 'project|BOX|1';
  const otherKey = 'project|BOX|2';
  const cloudFolder = r'C:\LWIP\2.Batches\20261028\Volume';

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('rework_recovery_');
    db = UploadStatsDB()..debugOverrideBaseFolderForTests(root.path);
  });
  tearDown(() async {
    await db.debugCloseAllForTests();
    await root.delete(recursive: true);
  });

  String inFolder(String base, String page) =>
      p.join(root.path, base, '20261028', 'Volume', page);
  String inOtherFolder(String page) =>
      p.join(root.path, 'input', '20261027', 'Other', page);

  Future<File> stage(String target, {String key = folderKey, List<int>? bytes}) async {
    final shot = await File(p.join(root.path, 'shot.jpg')).writeAsBytes(bytes ?? [1, 2]);
    return ColorReworkStore.stage('station', target, shot,
        ColorBinding.none('disabled'), folderKey: key);
  }

  Future<void> check({Iterable<File> completing = const []}) =>
      ColorReworkStore.assertMetadataSafe('station',
          folderKey: folderKey, folderPath: cloudFolder, completing: completing);

  File intentOf(File staged) => File(p.join(staged.parent.path, 'intent.json'));
  File ownerOf(File staged) => File(p.join(staged.parent.path, 'owner.json'));

  group('ownership of unreadable records', () {
    test('new records carry a verifiable owner', () async {
      final staged = await stage(inFolder('input', 'page.jpg'));
      final owner = jsonDecode(await ownerOf(staged).readAsString()) as Map;
      expect(owner['device_id'], 'station');
      expect(owner['target'], inFolder('input', 'page.jpg'));
      expect(owner['folder_key'], folderKey);
    });

    test('a corrupt intent of another folder does not block this folder',
        () async {
      final other = await stage(inOtherFolder('a.jpg'), key: otherKey);
      await ColorReworkStore.beginApply('station', inOtherFolder('a.jpg'));
      await intentOf(other).writeAsString('{bad');
      await check();
      // ...but still blocks its own folder, by page and record.
      await expectLater(
        ColorReworkStore.assertMetadataSafe('station', folderKey: otherKey,
            folderPath: r'C:\LWIP\2.Batches\20261027\Other'),
        throwsA(predicate((e) => '$e'.contains('a.jpg') &&
            '$e'.contains(other.parent.path))),
      );
    });

    test('a corrupt intent of this folder blocks and names the page', () async {
      final staged = await stage(inFolder('input', 'page.jpg'));
      await intentOf(staged).writeAsString('{bad');
      await expectLater(check(), throwsA(predicate((e) =>
          '$e'.contains('page.jpg') && '$e'.contains(staged.parent.path))));
    });

    test('a corrupt intent with a stale folder key still blocks by path',
        () async {
      final staged = await stage(inFolder('input', 'page.jpg'), key: otherKey);
      await intentOf(staged).writeAsString('{bad');
      await expectLater(check(), throwsStateError);
    });

    test('unknown legacy ownership blocks every folder, naming the record',
        () async {
      final staged = await stage(inOtherFolder('a.jpg'), key: otherKey);
      await ownerOf(staged).writeAsString(jsonEncode({'device_id': 'station'}));
      await intentOf(staged).writeAsString('{bad');
      await expectLater(check(), throwsA(predicate((e) =>
          '$e'.contains('cannot be attributed') &&
          '$e'.contains(staged.parent.path))));
    });

    test('an owner whose target does not match its record is not trusted',
        () async {
      final staged = await stage(inOtherFolder('a.jpg'), key: otherKey);
      await ownerOf(staged).writeAsString(jsonEncode({
        'device_id': 'station',
        'target': inOtherFolder('elsewhere.jpg'),
        'folder_key': otherKey,
      }));
      await intentOf(staged).writeAsString('{bad');
      await expectLater(check(), throwsA(predicate(
          (e) => '$e'.contains('cannot be attributed'))));
    });

    test('a readable intent proves ownership even with a corrupt owner',
        () async {
      final other = await stage(inOtherFolder('a.jpg'), key: otherKey);
      await ColorReworkStore.beginApply('station', inOtherFolder('a.jpg'));
      await ownerOf(other).writeAsString('{bad');
      await check();
      final mine = await stage(inFolder('input', 'page.jpg'));
      await ColorReworkStore.beginApply('station', inFolder('input', 'page.jpg'));
      await ownerOf(mine).writeAsString('{bad');
      await expectLater(check(), throwsStateError);
    });

    test('a completing generation does not exempt a corrupt record', () async {
      final staged = await stage(inFolder('input', 'page.jpg'));
      final sibling = await stage(inFolder('input', 'sib.jpg'));
      await intentOf(sibling).writeAsString('{bad');
      await expectLater(check(completing: [staged]), throwsStateError);
    });

    test('outstanding lists a hidden sibling by page', () async {
      await stage(inFolder('input', 'sib.jpg'));
      await ColorReworkStore.beginApply('station', inFolder('input', 'sib.jpg'));
      final records = await ColorReworkStore.outstanding('station',
          folderKey: folderKey, folderPath: cloudFolder);
      expect(records.map((r) => r.page), ['sib.jpg']);
    });
  });

  group('restaging over unknown state', () {
    test('an unreadable intent is preserved and its obligation kept', () async {
      final first = await stage(inFolder('input', 'page.jpg'));
      final before = '{bad';
      await intentOf(first).writeAsString(before);
      final next = await stage(inFolder('input', 'page.jpg'));
      final kept = first.parent.listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('intent.unreadable-'))
          .toList();
      expect(kept, hasLength(1));
      expect(await kept.single.readAsString(), before);
      final intent = jsonDecode(await intentOf(next).readAsString()) as Map;
      expect(intent['applying'], isTrue);
      await expectLater(ColorReworkStore.discardStaged(next), throwsStateError,
          reason: 'Undo cannot drop an obligation it cannot rule out');
    });

    test('an unsupported future protocol is never overwritten', () async {
      final first = await stage(inFolder('input', 'page.jpg'));
      final data = jsonDecode(await intentOf(first).readAsString()) as Map;
      data['apply_protocol'] = 3;
      await intentOf(first).writeAsString(jsonEncode(data));
      final before = await intentOf(first).readAsString();
      await expectLater(stage(inFolder('input', 'page.jpg')), throwsStateError);
      expect(await intentOf(first).readAsString(), before);
    });
  });

  group('capture-slot recovery is isolated per page', () {
    Future<File> applyingSlot(String name, int byte) async {
      final shot = await File(p.join(root.path, 'replacement_$byte.jpg'))
          .writeAsBytes([byte]);
      final staged = await ColorReworkStore.stage('station',
          'capture-slot:$name', shot, ColorBinding.none('disabled'));
      await ColorReworkStore.beginApply('station', 'capture-slot:$name');
      await db.markColorReplacementPending('station', name);
      return staged;
    }

    Future<bool> pending(String name) async {
      final raw = await db.getDatabase('station');
      return (await raw.query('color_pending',
              where: 'image_name = ?', whereArgs: [name]))
          .isNotEmpty;
    }

    test('a damaged page is reported, kept and later retaken', () async {
      await applyingSlot('good.jpg', 1);
      final damaged = await applyingSlot('bad.jpg', 2);
      await damaged.delete();
      final result = await ColorReworkStore.recoverCaptureSlots(
          'station', ['good.jpg', 'bad.jpg'],
          dateKeyFor: (_) => '2026-10-29', username: 'operator');
      expect(result.recovered.keys, ['good.jpg']);
      expect(result.failed.keys, ['bad.jpg']);
      expect(result.failed['bad.jpg'], contains(damaged.parent.path));
      expect(await pending('good.jpg'), isFalse);
      expect(await pending('bad.jpg'), isTrue,
          reason: 'transfer keeps refusing the damaged page');
      expect(await intentOf(damaged).exists(), isTrue);
      expect(await File('${damaged.path}.color.json').exists(), isTrue);

      // Retake: the new generation keeps the unresolved obligation.
      final retake = await applyingSlot('bad.jpg', 3);
      expect((jsonDecode(await intentOf(retake).readAsString()) as Map)['applying'], isTrue);
      // Interrupted again before completion: the next load recovers it.
      final again = await ColorReworkStore.recoverCaptureSlots(
          'station', ['bad.jpg'],
          dateKeyFor: (_) => '2026-10-29', username: 'operator');
      expect(again.recovered.keys, ['bad.jpg']);
      expect(await pending('bad.jpg'), isFalse);
      expect(await ColorReworkStore.recoverApplying('station', 'capture-slot:bad.jpg'), isNull);
    });

    test('an unreadable intent is reported, then superseded by a retake',
        () async {
      final broken = await applyingSlot('bad.jpg', 2);
      await intentOf(broken).writeAsString('{bad');
      final result = await ColorReworkStore.recoverCaptureSlots(
          'station', ['bad.jpg'],
          dateKeyFor: (_) => '2026-10-29', username: 'operator');
      expect(result.failed.keys, ['bad.jpg']);
      expect(await pending('bad.jpg'), isTrue);
      final retake = await applyingSlot('bad.jpg', 3);
      expect((jsonDecode(await intentOf(retake).readAsString()) as Map)['applying'], isTrue);
      await db.saveColorBinding('station', 'bad.jpg', ColorBinding.none('disabled').toJson());
      await ColorReworkStore.complete('station', 'capture-slot:bad.jpg', staged: retake);
      expect(await pending('bad.jpg'), isFalse);
      expect(retake.parent.listSync().any(
          (f) => p.basename(f.path).startsWith('intent.unreadable-')), isTrue);
    });
  });

  group('interrupted apply under a changed path', () {
    // Two paths to one directory: a junction stands for a remapped share.
    Future<bool> junction(String link, String target) async {
      await Directory(target).create(recursive: true);
      await Directory(p.dirname(link)).create(recursive: true);
      final r = await Process.run('cmd', ['/c', 'mklink', '/J', link, target]);
      return r.exitCode == 0;
    }

    late String oldTarget;
    late String newTarget;
    late File oldStaged;

    Future<void> interruptedAtOldPath({required bool sameFolder}) async {
      final real = p.join(root.path, 'share', '20261028', 'Volume');
      newTarget = p.join(real, 'page.jpg');
      final oldDir = p.join(root.path, 'old', '20261028', 'Volume');
      if (sameFolder) {
        if (!await junction(oldDir, real)) {
          markTestSkipped('mklink /J is unavailable');
          return;
        }
      } else {
        await Directory(oldDir).create(recursive: true);
        await Directory(real).create(recursive: true);
      }
      oldTarget = p.join(oldDir, 'page.jpg');
      oldStaged = await stage(oldTarget);
      await ColorReworkStore.beginApply('station', oldTarget);
    }

    Future<File?> relocate() => ColorReworkStore.relocateApplying('station',
        folderKey: folderKey, folderPath: cloudFolder, newTarget: newTarget);

    test('the same destination is continued and retired only by its commit',
        () async {
      await interruptedAtOldPath(sameFolder: true);
      final moved = await relocate();
      expect(moved, isNotNull);
      final intent = jsonDecode(await intentOf(moved!).readAsString()) as Map;
      expect(intent['applying'], isTrue);
      expect(intent['target'], newTarget);
      expect(await moved.readAsBytes(), await oldStaged.readAsBytes());
      expect(await ColorReworkStore.supersededGeneration(moved),
          isA<File>().having((f) => f.path, 'path', oldStaged.path));
      await expectLater(check(), throwsStateError);
      await expectLater(ColorReworkStore.discardStaged(moved), throwsStateError);
      // The submit's guard accepts the installed relocated generation.
      await check(completing: [moved]);

      // A rolled-back closure records nothing.
      final local = await db.getDatabase('station');
      await expectLater(local.transaction((txn) async {
        await ColorReworkStore.recordCommitted(txn, moved);
        await ColorReworkStore.recordCommitted(txn, oldStaged);
        throw StateError('rollback');
      }), throwsStateError);
      await expectLater(check(), throwsStateError);

      // A committed closure retires both, even if cleanup then fails.
      await local.transaction((txn) async {
        await ColorReworkStore.recordCommitted(txn, moved);
        await ColorReworkStore.recordCommitted(txn, oldStaged);
      });
      await check();
      await ColorReworkStore.complete('station', newTarget, staged: moved);
      await ColorReworkStore.completeGeneration(oldStaged);
      expect(await ColorReworkStore.outstanding('station',
          folderKey: folderKey, folderPath: cloudFolder), isEmpty);
    });

    test('a newer generation at the old path is not exempted', () async {
      await interruptedAtOldPath(sameFolder: true);
      final moved = (await relocate())!;
      await stage(oldTarget, bytes: [9]);
      await expectLater(check(completing: [moved]), throwsStateError);
    });

    test('an independent old location is refused and left intact', () async {
      await interruptedAtOldPath(sameFolder: false);
      final before = await intentOf(oldStaged).readAsString();
      await expectLater(relocate(), throwsA(predicate((e) =>
          '$e'.contains('page.jpg') && '$e'.contains(oldStaged.parent.path))));
      expect(await intentOf(oldStaged).readAsString(), before);
      expect(await ColorReworkStore.recoverApplying('station', newTarget), isNull);
      await expectLater(check(), throwsStateError);
    });

    test('an unreachable old location is refused', () async {
      await interruptedAtOldPath(sameFolder: false);
      await Directory(p.dirname(oldTarget)).delete(recursive: true);
      await expectLater(relocate(), throwsStateError);
      await expectLater(check(), throwsStateError);
    });

    test('damaged old bytes are never relocated', () async {
      await interruptedAtOldPath(sameFolder: true);
      await oldStaged.writeAsBytes([7, 7]);
      await expectLater(relocate(), throwsStateError);
      expect(await ColorReworkStore.recoverApplying('station', newTarget), isNull);
    });

    test('an existing record at the new path is not overwritten', () async {
      await interruptedAtOldPath(sameFolder: true);
      final fresh = await stage(newTarget, bytes: [5]);
      await expectLater(relocate(), throwsStateError);
      expect((jsonDecode(await intentOf(fresh).readAsString()) as Map)['file'],
          p.basename(fresh.path));
    });

    Future<Set<String>> receipts() async {
      final rows = await (await db.getDatabase('station')).query('sync_meta',
          where: "key LIKE 'rework_committed:%'");
      return rows.map((r) => '${r['key']}=${r['value']}').toSet();
    }

    String receipt(File staged) => 'rework_committed:'
        '${p.basename(staged.parent.path)}=${p.basename(staged.path)}';

    // The submit's closure transaction, as gallery_page records it.
    Future<void> close(File staged, {bool rollback = false}) async {
      final local = await db.getDatabase('station');
      await local.transaction((txn) async {
        await ColorReworkStore.recordCommitted(txn, staged);
        final old = await ColorReworkStore.supersededGeneration(staged);
        if (old != null) await ColorReworkStore.recordCommitted(txn, old);
        if (rollback) throw StateError('rollback');
      });
    }

    test('a retake keeps the old-generation obligation through restart and '
        'repeat, and retires it only by a committed closure', () async {
      await interruptedAtOldPath(sameFolder: true);
      final moved = (await relocate())!;
      final first = await stage(newTarget, bytes: [3]);
      expect(await ColorReworkStore.supersededGeneration(first),
          isA<File>().having((f) => f.path, 'path', oldStaged.path));
      // Restart: page entry recovers the newest generation, then a retake.
      expect((await ColorReworkStore.recoverApplying('station', newTarget))!.path,
          first.path);
      final second = await stage(newTarget, bytes: [4]);
      final intent = jsonDecode(await intentOf(second).readAsString()) as Map;
      expect(intent['applying'], isTrue);
      expect(intent['supersedes'], {
        'record': p.basename(oldStaged.parent.path),
        'file': p.basename(oldStaged.path),
      });
      expect(moved.parent.path, second.parent.path);
      await check(completing: [second]);

      await expectLater(close(second, rollback: true), throwsStateError);
      expect(await receipts(), isEmpty);
      await expectLater(check(), throwsStateError);
      expect(await intentOf(oldStaged).exists(), isTrue);

      await close(second);
      expect(await receipts(), {receipt(second), receipt(oldStaged)});
      await check();
      await ColorReworkStore.complete('station', newTarget, staged: second);
      await ColorReworkStore.completeGeneration(oldStaged);
      expect(await intentOf(oldStaged).exists(), isFalse);
      expect(await ColorReworkStore.outstanding('station',
          folderKey: folderKey, folderPath: cloudFolder), isEmpty);
    });

    test('a retake does not exempt a newer generation at the old path',
        () async {
      await interruptedAtOldPath(sameFolder: true);
      await relocate();
      final retake = await stage(newTarget, bytes: [3]);
      final newer = await stage(oldTarget, bytes: [9]);
      await ColorReworkStore.beginApply('station', oldTarget);
      await expectLater(check(completing: [retake]), throwsA(predicate(
          (e) => '$e'.contains(newer.parent.path))));
      // Its reference still names the exact old generation, never the newer.
      expect((await ColorReworkStore.supersededGeneration(retake))!.path,
          oldStaged.path);
    });

    test('a committed operation passes nothing to the next one', () async {
      await interruptedAtOldPath(sameFolder: true);
      final moved = (await relocate())!;
      await close(moved); // committed; both intents survive failed cleanup
      final next = await stage(newTarget, bytes: [6]);
      final intent = jsonDecode(await intentOf(next).readAsString()) as Map;
      expect(intent.containsKey('supersedes'), isFalse);
      expect(intent['applying'], isFalse);
      await check();
    });

    test('a retake after the old record was retired carries no reference',
        () async {
      await interruptedAtOldPath(sameFolder: true);
      await relocate();
      await intentOf(oldStaged).delete();
      final retake = await stage(newTarget, bytes: [3]);
      expect(await ColorReworkStore.supersededGeneration(retake), isNull);
      expect((jsonDecode(await intentOf(retake).readAsString()) as Map)['applying'],
          isTrue);
    });

    test('an invalid supersession reference is refused, not dropped', () async {
      await interruptedAtOldPath(sameFolder: true);
      final moved = (await relocate())!;
      final data = jsonDecode(await intentOf(moved).readAsString()) as Map;
      data['supersedes'] = {'record': p.basename(moved.parent.path), 'file': 'x.jpg'};
      await intentOf(moved).writeAsString(jsonEncode(data));
      final before = await intentOf(moved).readAsString();
      await expectLater(stage(newTarget, bytes: [3]), throwsStateError);
      expect(await intentOf(moved).readAsString(), before);
      await expectLater(ColorReworkStore.supersededGeneration(moved), throwsStateError);
    });
  });

  group('typed fields of readable records', () {
    const otherFolder = r'C:\LWIP\2.Batches\20261027\Other';
    Future<void> checkOther() => ColorReworkStore.assertMetadataSafe('station',
        folderKey: otherKey, folderPath: otherFolder);

    // An interrupted record of the other folder with [edit] applied to its
    // intent (and [owner] replacing its owner record).
    Future<File> otherWith(void Function(Map intent) edit, {Map? owner}) async {
      final staged = await stage(inOtherFolder('a.jpg'), key: otherKey);
      await ColorReworkStore.beginApply('station', inOtherFolder('a.jpg'));
      final data = jsonDecode(await intentOf(staged).readAsString()) as Map;
      edit(data);
      await intentOf(staged).writeAsString(jsonEncode(data));
      if (owner != null) await ownerOf(staged).writeAsString(jsonEncode(owner));
      return staged;
    }

    test('a wrong-type folder_key in another folder does not block this one',
        () async {
      final other = await otherWith((d) => d['folder_key'] = 73);
      await check();
      expect(await ColorReworkStore.outstanding('station',
          folderKey: folderKey, folderPath: cloudFolder), isEmpty);
      await expectLater(checkOther(), throwsA(predicate((e) =>
          '$e'.contains('a.jpg') && '$e'.contains(other.parent.path) &&
          '$e'.contains('folder_key is not text'))));
      final listed = await ColorReworkStore.outstanding('station',
          folderKey: otherKey, folderPath: otherFolder);
      expect(listed.map((r) => r.page), ['a.jpg']);
      expect(listed.single.problem, contains('folder_key'));
    });

    test('missing and null folder keys fall back to the verified owner',
        () async {
      for (final edit in <void Function(Map)>[
        (d) => d.remove('folder_key'),
        (d) => d['folder_key'] = null,
      ]) {
        final other = await otherWith(edit);
        await check();
        await expectLater(checkOther(), throwsA(predicate(
            (e) => '$e'.contains('interrupted recapture'))));
        await other.parent.delete(recursive: true);
      }
    });

    test('wrong-type generation and applying fields block only their folder',
        () async {
      for (final (edit, message) in <(void Function(Map), String)>[
        ((d) => d['file'] = 7, 'no valid generation file'),
        ((d) => d['applying'] = 'yes', 'applying state'),
      ]) {
        final other = await otherWith(edit);
        await check();
        await expectLater(checkOther(), throwsA(predicate((e) =>
            '$e'.contains(message) && '$e'.contains(other.parent.path))));
        expect((await ColorReworkStore.outstanding('station',
            folderKey: otherKey, folderPath: otherFolder)).single.page, 'a.jpg');
        await other.parent.delete(recursive: true);
      }
    });

    test('a wrong-type owner field blocks the record\'s own folder', () async {
      final other = await otherWith((_) {}, owner: {
        'device_id': 'station',
        'target': inOtherFolder('a.jpg'),
        'folder_key': 5,
      });
      await check();
      await expectLater(checkOther(), throwsA(predicate((e) =>
          '$e'.contains('owner folder_key is not text') &&
          '$e'.contains(other.parent.path))));
    });

    test('intent and owner naming different folders block both', () async {
      await otherWith((_) {}, owner: {
        'device_id': 'station',
        'target': inOtherFolder('a.jpg'),
        'folder_key': folderKey,
      });
      await expectLater(check(), throwsA(predicate(
          (e) => '$e'.contains('different folders'))));
      await expectLater(checkOther(), throwsStateError);
    });

    test('a corrupt folder key with no verified owner folder blocks every '
        'folder', () async {
      for (final owner in [
        {'device_id': 'station', 'target': inOtherFolder('a.jpg')},
        {'device_id': 'station', 'target': inOtherFolder('elsewhere.jpg'),
         'folder_key': otherKey},
      ]) {
        final other = await otherWith((d) => d['folder_key'] = 73, owner: owner);
        await expectLater(check(), throwsA(predicate((e) =>
            '$e'.contains('cannot be attributed') &&
            '$e'.contains(other.parent.path) && '$e'.contains('a.jpg'))));
        final listed = await ColorReworkStore.outstanding('station',
            folderKey: folderKey, folderPath: cloudFolder);
        expect(listed.single.unattributed, isTrue);
        await other.parent.delete(recursive: true);
      }
    });
  });

  group('owner device claims', () {
    // An interrupted record of this station for a sibling page of this folder.
    Future<File> sibling({bool unreadable = false, Map? owner}) async {
      final staged = await stage(inFolder('input', 'sib.jpg'));
      await ColorReworkStore.beginApply('station', inFolder('input', 'sib.jpg'));
      if (owner != null) await ownerOf(staged).writeAsString(jsonEncode(owner));
      if (unreadable) await intentOf(staged).writeAsString('{bad');
      return staged;
    }

    test('an owner naming another device without proof does not hide this '
        'station\'s record', () async {
      for (final (owner, unreadable) in [
        ({'device_id': 'other', 'target': inFolder('input', 'sib.jpg'),
          'folder_key': folderKey}, false),
        ({'device_id': 'other', 'target': inFolder('input', 'sib.jpg')}, true),
        ({'device_id': 'other'}, false),
      ]) {
        final staged = await sibling(owner: owner, unreadable: unreadable);
        await expectLater(check(), throwsA(predicate((e) =>
            '$e'.contains('names device other') &&
            '$e'.contains(staged.parent.path))));
        final listed = await ColorReworkStore.outstanding('station',
            folderKey: folderKey, folderPath: cloudFolder);
        expect(listed.single.directory.path, staged.parent.path);
        await staged.parent.delete(recursive: true);
      }
    });

    test('a contradicted owner with no proof either way blocks every folder',
        () async {
      final staged = await sibling(owner: {'device_id': 'other'},
          unreadable: true);
      await expectLater(
        ColorReworkStore.assertMetadataSafe('station',
            folderKey: otherKey, folderPath: r'C:\LWIP\2.Batches\20261027\Other'),
        throwsA(predicate((e) => '$e'.contains('cannot be attributed') &&
            '$e'.contains(staged.parent.path))),
      );
    });

    test('another device\'s record that proves itself stays isolated',
        () async {
      final shot = await File(p.join(root.path, 'theirs.jpg')).writeAsBytes([4]);
      for (final legacyOwner in [false, true]) {
        final theirs = await ColorReworkStore.stage('other',
            inFolder('input', 'sib.jpg'), shot, ColorBinding.none('disabled'),
            folderKey: folderKey);
        await ColorReworkStore.beginApply('other', inFolder('input', 'sib.jpg'));
        if (legacyOwner) {
          await ownerOf(theirs).writeAsString(jsonEncode({'device_id': 'other'}));
        }
        await check();
        expect(await ColorReworkStore.outstanding('station',
            folderKey: folderKey, folderPath: cloudFolder), isEmpty);
        await theirs.parent.delete(recursive: true);
      }
    });

    test('a retake repairs the owner record', () async {
      final staged = await sibling(owner: {'device_id': 'other'});
      final retake = await stage(inFolder('input', 'sib.jpg'), bytes: [5]);
      final owner = jsonDecode(await ownerOf(retake).readAsString()) as Map;
      expect(owner['device_id'], 'station');
      expect((jsonDecode(await intentOf(retake).readAsString()) as Map)['applying'],
          isTrue);
      expect(staged.parent.path, retake.parent.path);
    });
  });

  group('retake over an unusable generation', () {
    Future<File> interrupted(void Function(Map) damage) async {
      final staged = await stage(inFolder('input', 'page.jpg'));
      await ColorReworkStore.beginApply('station', inFolder('input', 'page.jpg'));
      final data = jsonDecode(await intentOf(staged).readAsString()) as Map;
      damage(data);
      await intentOf(staged).writeAsString(jsonEncode(data));
      return staged;
    }

    List<File> evidence(File staged) => staged.parent.listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).startsWith('intent.damaged-'))
        .toList();

    test('an invalid generation name is advised and replaced by a retake '
        'that keeps evidence and obligation', () async {
      for (final damage in <void Function(Map)>[
        (d) => d['file'] = 82,
        (d) => d.remove('file'),
        (d) => d['file'] = r'..\escape.jpg',
      ]) {
        final first = await interrupted(damage);
        final original = await intentOf(first).readAsString();
        await expectLater(check(), throwsA(predicate(
            (e) => '$e'.contains('Recapture that page'))));
        final retake = await stage(inFolder('input', 'page.jpg'), bytes: [6]);
        expect(evidence(retake), hasLength(1));
        expect(await evidence(retake).single.readAsString(), original);
        final active = jsonDecode(await intentOf(retake).readAsString()) as Map;
        expect(active['applying'], isTrue);
        expect(active['file'], p.basename(retake.path));
        await expectLater(ColorReworkStore.discardStaged(retake), throwsStateError);
        await expectLater(check(), throwsStateError,
            reason: 'still an interrupted recapture until it commits');
        await check(completing: [retake]);
        await retake.parent.delete(recursive: true);
      }
    });

    test('a refused retake is never advised, and leaves the record untouched',
        () async {
      for (final damage in <void Function(Map)>[
        (d) => d['apply_protocol'] = 3,
        (d) => d['applying'] = 'yes',
        (d) => d['supersedes'] = 'not a link',
      ]) {
        final first = await interrupted(damage);
        // An owner problem routes the record to the damaged-record message.
        await ownerOf(first).writeAsString(jsonEncode({
          'device_id': 'station', 'target': inFolder('input', 'page.jpg'),
          'folder_key': 5,
        }));
        final before = await intentOf(first).readAsString();
        await expectLater(check(), throwsA(predicate(
            (e) => !'$e'.contains('Recapture that page'))));
        await expectLater(stage(inFolder('input', 'page.jpg'), bytes: [6]),
            throwsStateError);
        expect(await intentOf(first).readAsString(), before);
        expect(evidence(first), isEmpty);
        await first.parent.delete(recursive: true);
      }
    });
  });
}
