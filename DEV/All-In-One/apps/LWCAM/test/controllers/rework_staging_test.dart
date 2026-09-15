import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';

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
}
