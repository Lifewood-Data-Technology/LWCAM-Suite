import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/color_capture_session.dart';
import 'package:lwcam/services/color_rework_store.dart';
import 'package:path/path.dart' as p;

/// Staged recaptures used to live on _GalleryPageState, which is disposed the
/// moment the operator steps back to the box list — so three recaptured photos
/// were silently discarded by a there-and-back navigation and had to be shot
/// again (reported 2026-07-30). Re-photographing is the expensive part of
/// rework, so the staging now belongs to the session controller and these tests
/// pin when it may and may not be thrown away.
void main() {
  late BoxSessionController session;
  late Directory staging;

  setUp(() async {
    session = BoxSessionController(AuthController());
    staging = await Directory.systemTemp.createTemp('rework_staging_test_');
    addTearDown(() async {
      if (await staging.exists()) await staging.delete(recursive: true);
    });
  });

  Future<File> stage(String imageName) async {
    final f = File('${staging.path}/$imageName')..writeAsStringSync('photo');
    session.reworkStaged[imageName] = f;
    return f;
  }

  test('staged photos and their files survive until explicitly cleared',
      () async {
    final file = await stage('SAX01_a_001.jpg');
    session.reworkStagingDir = staging;
    session.reworkStagedBoxId = 7;
    session.reworkMetadataFixed.add('SAX01_a_002.jpg');

    // Nothing about disposing the capture page touches this state.
    expect(session.reworkStaged, hasLength(1));
    expect(await file.exists(), isTrue);
    expect(session.reworkMetadataFixed, contains('SAX01_a_002.jpg'));
  });

  test('clearReworkStaging drops the marks and deletes the files', () async {
    final file = await stage('SAX01_a_001.jpg');
    session.reworkStagingDir = staging;
    session.reworkStagedBoxId = 7;
    session.reworkMetadataFixed.add('SAX01_a_002.jpg');

    await session.clearReworkStaging();

    expect(session.reworkStaged, isEmpty);
    expect(session.reworkMetadataFixed, isEmpty);
    expect(session.reworkStagedBoxId, isNull);
    expect(session.reworkStagingDir, isNull);
    expect(await file.exists(), isFalse);
    expect(await staging.exists(), isFalse);
  });

  // After a submit the photos have been written into LWIP's input folder, so
  // the staging dir is dropped but its files must not be deleted out from under
  // the writes that just consumed them.
  test('clearReworkStaging(keepFiles: true) leaves the files alone', () async {
    final file = await stage('SAX01_a_001.jpg');
    session.reworkStagingDir = staging;

    await session.clearReworkStaging(keepFiles: true);

    expect(session.reworkStaged, isEmpty);
    expect(session.reworkStagingDir, isNull);
    expect(await file.exists(), isTrue);
  });

  test('clearing is safe when nothing was ever staged', () async {
    await session.clearReworkStaging();
    expect(session.reworkStaged, isEmpty);
    expect(session.reworkStagingDir, isNull);
  });

  test('clearReworkStaging also clears the closed set', () async {
    session.reworkClosed.add('a.jpg');
    await session.clearReworkStaging();
    expect(session.reworkClosed, isEmpty);
  });

  test('clearReworkStaging discards the durable intent of a staged page',
      () async {
    final root = await Directory.systemTemp.createTemp('rework_store_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    UploadStatsDB().debugOverrideBaseFolderForTests(root.path);
    final source = File(p.join(root.path, 'shot.jpg'))
      ..writeAsBytesSync([1, 2, 3]);
    final durable = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('disabled'),
    );
    session.reworkStaged['a.jpg'] = durable;
    session.reworkStagingDir = staging;
    session.reworkStagedBoxId = 7;
    expect(
      await ColorReworkStore.pending('station', 'target.jpg'),
      isNotNull,
    );

    await session.clearReworkStaging();

    expect(
      await ColorReworkStore.pending('station', 'target.jpg'),
      isNull,
      reason: 'a box switch must never leave the discarded photo selectable',
    );
    expect(
      await durable.exists(),
      isTrue,
      reason: 'photo cleanup belongs to the deferred task-lifecycle PR',
    );
    expect(session.reworkStaged, isEmpty);
  });
}
