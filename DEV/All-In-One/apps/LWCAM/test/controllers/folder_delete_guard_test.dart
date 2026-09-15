import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/orphan_image_store.dart';

/// A mis-created empty folder can now be deleted from the gallery. Both of the
/// refusals below happen BEFORE the database is touched, which is what lets
/// them be tested without one - and both matter:
///
/// * the active folder: openBox always makes some folder active, so deleting
///   the active one is how a box would reach zero folders, and a capture with
///   no folder to land in stashes as an orphan;
/// * an orphan targeting the folder: that IS a captured image whose assignment
///   write failed, so the folder is not empty even though capture_images says
///   it is - the UI's image count cannot see it.
void main() {
  late BoxSessionController session;
  late Directory orphanDir;

  CaptureFolder folder(int id) =>
      CaptureFolder(boxId: 1, id: id, folderSeq: id);

  setUp(() async {
    orphanDir = await Directory.systemTemp.createTemp('folder_delete_test_');
    addTearDown(() async {
      if (await orphanDir.exists()) await orphanDir.delete(recursive: true);
    });
    final auth = AuthController();
    auth.deviceId.value = 'devA';
    // Constructed directly, never Get.put: onInit would open the real DB.
    session = BoxSessionController(
      auth,
      orphanStore: OrphanImageStore(resolveBaseDir: () async => orphanDir),
    );
    session.activeBox.value = CaptureBox(
      id: 1,
      deviceId: 'devA',
      boxDetails: 'BOX-9',
    );
    session.foldersOfActiveBox.value = [folder(1), folder(2)];
  });

  test('refuses to delete the folder that is active for capture', () async {
    session.activeFolder.value = folder(2);

    await expectLater(
      session.deleteFolder(folder(2)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Make another folder active'),
        ),
      ),
    );
  });

  test('refuses while an unresolved orphan still targets the folder', () async {
    session.activeFolder.value = folder(1);
    final captured = File('${orphanDir.path}/shot.jpg')
      ..writeAsStringSync('photo');
    await session.orphanStore.stash(
      source: captured,
      deviceId: 'devA',
      deviceFilename: 'IMG_0001.jpg',
      boxId: 1,
      folderId: 2,
      reason: 'assignment-failed',
    );

    await expectLater(
      session.deleteFolder(folder(2)),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('unresolved image(s)'),
        ),
      ),
    );
  });

  test('an orphan belonging to ANOTHER folder does not block this one',
      () async {
    session.activeFolder.value = folder(1);
    final captured = File('${orphanDir.path}/shot.jpg')
      ..writeAsStringSync('photo');
    await session.orphanStore.stash(
      source: captured,
      deviceId: 'devA',
      deviceFilename: 'IMG_0001.jpg',
      boxId: 1,
      folderId: 1,
      reason: 'assignment-failed',
    );

    // The orphan filter is folder-scoped, not box-scoped: folder 2 passes both
    // pre-DB guards and gets as far as the database, which this test has no
    // business opening (it fails on the unset sqflite factory). Not reaching
    // either refusal is the assertion.
    await expectLater(
      session.deleteFolder(folder(2)),
      throwsA(
        predicate(
          (e) =>
              !e.toString().contains('unresolved image(s)') &&
              !e.toString().contains('Make another folder active'),
          'is not one of deleteFolder\'s own refusals',
        ),
      ),
    );
  });
}
