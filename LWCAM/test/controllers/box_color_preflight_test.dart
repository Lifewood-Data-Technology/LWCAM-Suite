import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

CaptureFolder _folder(int boxId) => CaptureFolder(
  boxId: boxId,
  title: 'T',
  volume: 'V',
);

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late BoxSessionController session;
  late UploadStatsDB db;
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('color_preflight_');
    db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(root.path);
    final auth = AuthController();
    auth.deviceId.value = 'station';
    session = BoxSessionController(auth);
  });

  tearDown(() async {
    await db.debugCloseAllForTests();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<(int, int)> boxWithUnboundImage(String name) async {
    final boxId = await db.insertCaptureBox(
      deviceId: 'station',
      boxDetails: name,
    );
    final folderId = await db.insertCaptureFolder(
      deviceId: 'station',
      folder: _folder(boxId),
      isComplete: true,
    );
    await db.assignImageToFolder(
      deviceId: 'station',
      boxId: boxId,
      folderId: folderId,
      deviceFilename: '$name.jpg',
    );
    final raw = await db.getDatabase('station');
    await raw.delete(
      'color_bindings',
      where: 'image_name = ?',
      whereArgs: ['$name.jpg'],
    );
    return (boxId, folderId);
  }

  test('preflight aggregates the real reason and accept resolves the box',
      () async {
    final (boxId, _) = await boxWithUnboundImage('A');
    final raw = await db.getDatabase('station');
    await raw.insert('color_integrity', {
      'id': 1,
      'reason': 'damaged ledger',
    });
    final box = (await db.getCaptureBoxById(
      deviceId: 'station',
      boxId: boxId,
    ))!;

    final preflight = await session.colorCalibrationPreflight(box);
    expect(preflight.issues, hasLength(1));
    expect(preflight.issues.single.folderName, isNotEmpty);
    expect(preflight.issues.single.kind, ColorCalibrationIssueKind.unknownBinding);
    expect(preflight.issues.single.message, contains('damaged ledger'));
    expect(preflight.canContinueUncalibrated, isTrue);

    expect(
      await session.acceptUncalibratedColorBindings(box, preflight),
      1,
    );
    expect((await session.colorCalibrationPreflight(box)).hasIssues, isFalse);
    expect(await raw.query('color_integrity'), isEmpty);
  });

  test('a fully bound box can retire a stale recovery flag', () async {
    final (boxId, folderId) = await boxWithUnboundImage('BOUND');
    await db.bindHistoricalIfUnbound('station', folderId);
    final raw = await db.getDatabase('station');
    await raw.insert('color_integrity', {'id': 1, 'reason': 'old recovery'});
    final box = (await db.getCaptureBoxById(
      deviceId: 'station',
      boxId: boxId,
    ))!;

    expect((await session.colorCalibrationPreflight(box)).hasIssues, isFalse);
    expect(await session.clearResolvedColorIntegrity(), isTrue);
    expect(await raw.query('color_integrity'), isEmpty);
  });

  test('another OPEN box keeps the global flag but not this box', () async {
    final (firstBoxId, _) = await boxWithUnboundImage('FIRST');
    final (secondBoxId, _) = await boxWithUnboundImage('SECOND');
    final raw = await db.getDatabase('station');
    await raw.insert('color_integrity', {'id': 1, 'reason': 'lost'});
    final first = (await db.getCaptureBoxById(
      deviceId: 'station',
      boxId: firstBoxId,
    ))!;

    final preflight = await session.colorCalibrationPreflight(first);
    expect(await session.acceptUncalibratedColorBindings(first, preflight), 1);
    expect((await session.colorCalibrationPreflight(first)).hasIssues, isFalse);
    expect(
      await raw.query('color_integrity'),
      isNotEmpty,
      reason: 'the second OPEN box is still unresolved',
    );

    final second = (await db.getCaptureBoxById(
      deviceId: 'station',
      boxId: secondBoxId,
    ))!;
    final secondPreflight = await session.colorCalibrationPreflight(second);
    await session.acceptUncalibratedColorBindings(second, secondPreflight);
    expect(await raw.query('color_integrity'), isEmpty);
  });
}
