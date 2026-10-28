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
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('rework_lifecycle_');
    db = UploadStatsDB()..debugOverrideBaseFolderForTests(root.path);
  });
  tearDown(() async {
    await db.debugCloseAllForTests();
    await root.delete(recursive: true);
  });
  test('older completion preserves a newer applying generation', () async {
    final source = await File(p.join(root.path, 'generation.jpg')).writeAsBytes([1]);
    final target = p.join(root.path, 'generation-target.jpg');
    final first = await ColorReworkStore.stage(
      'station', target, source, ColorBinding.none('disabled'));
    await ColorReworkStore.beginApply('station', target);
    await source.writeAsBytes([2]);
    final newer = await ColorReworkStore.stage(
      'station', target, source, ColorBinding.none('disabled'));
    await ColorReworkStore.complete('station', target, staged: first);
    expect((await ColorReworkStore.recoverApplying('station', target))?.path,
        newer.path);
    await ColorReworkStore.complete('station', target, staged: newer);
    expect(await ColorReworkStore.pending('station', target), isNull);
  });
  test('guarded completion preserves an unreadable intent', () async {
    final source = await File(p.join(root.path, 'damaged.jpg')).writeAsBytes([1]);
    final target = p.join(root.path, 'damaged-target.jpg');
    final staged = await ColorReworkStore.stage(
      'station', target, source, ColorBinding.none('disabled'));
    final intent = File(p.join(staged.parent.path, 'intent.json'));
    await intent.writeAsString('{broken');
    await expectLater(ColorReworkStore.complete('station', target, staged: staged),
        throwsFormatException);
    expect(await intent.readAsString(), '{broken');
    expect(await staged.exists(), isTrue);
  });
  test('applying survives Undo, restaging and recovery', () async {
    final source = await File(p.join(root.path, 'shot.jpg')).writeAsBytes([1]);
    final target = p.join(root.path, 'target.jpg');
    final staged = await ColorReworkStore.stage(
      'station',
      target,
      source,
      ColorBinding.none('disabled'),
    );
    await ColorReworkStore.beginApply('station', target);
    await expectLater(ColorReworkStore.discardStaged(staged), throwsStateError);
    final replacement = await ColorReworkStore.stage(
      'station',
      target,
      source,
      ColorBinding.none('disabled'),
    );
    await expectLater(
      ColorReworkStore.discardStaged(replacement),
      throwsStateError,
    );
    expect(
      (await ColorReworkStore.recoverApplying('station', target))!.path,
      replacement.path,
    );
    await ColorReworkStore.complete('station', target, staged: replacement);
    expect(await ColorReworkStore.recoverApplying('station', target), isNull);
  });
  test(
    'interrupted capture slot restores overlay and binding idempotently',
    () async {
      final source = await File(p.join(root.path, 'new.jpg')).writeAsBytes([1]);
      final staged = await ColorReworkStore.stage(
        'station',
        'capture-slot:old.jpg',
        source,
        ColorBinding.none('disabled'),
      );
      await ColorReworkStore.beginApply('station', 'capture-slot:old.jpg');
      final recovered = await ColorReworkStore.recoverCaptureSlot(
        'station',
        'old.jpg',
        dateKey: '2026-10-27',
        username: 'operator',
      );
      expect(recovered!.path, staged.path);
      expect(
        (await db.colorBindingFor('station', 'old.jpg'))['reason'],
        'disabled',
      );
      expect(await db.getReplacementRecords('station'), hasLength(1));
      expect(
        await ColorReworkStore.recoverCaptureSlot(
          'station',
          'old.jpg',
          dateKey: '2026-10-27',
          username: 'operator',
        ),
        isNull,
      );
      expect(await db.getReplacementRecords('station'), hasLength(1));
    },
  );
  test(
    'retention preserves pending and referenced photos but prunes completed copies',
    () async {
      final source = await File(p.join(root.path, 'new.jpg')).writeAsBytes([1]);
      final pending = await ColorReworkStore.stage(
        'station',
        'pending',
        source,
        ColorBinding.none('disabled'),
      );
      final done = await ColorReworkStore.stage(
        'station',
        'done',
        source,
        ColorBinding.none('disabled'),
      );
      await ColorReworkStore.complete('station', 'done', staged: done);
      final overlay = await ColorReworkStore.stage(
        'station',
        'capture-slot:old.jpg',
        source,
        ColorBinding.none('disabled'),
      );
      await ColorReworkStore.beginApply('station', 'capture-slot:old.jpg');
      await ColorReworkStore.recoverCaptureSlot(
        'station',
        'old.jpg',
        dateKey: '2026-10-27',
        username: 'operator',
      );
      await ColorReworkStore.prune(
        'station',
        now: DateTime.now().add(const Duration(days: 31)),
      );
      expect(await pending.exists(), isTrue);
      expect(await overlay.exists(), isTrue);
      expect(await done.exists(), isFalse);
    },
  );
}
