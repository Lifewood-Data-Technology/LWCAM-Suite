import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_controller.dart';
import 'package:lwcam/models/qc_task.dart';

/// What the queue offers an operator once a review has finished.
///
/// The rule is "finish what you hold": a task still claimed is offered before a
/// fresh claim, so an operator cannot quietly accumulate locked folders by
/// answering yes repeatedly. And when there is nothing either way the operator is
/// NOT asked - a prompt whose only honest answer is "no" is just a click.
///
/// [QcNextUp] carries that decision on its own so it can be checked without a
/// widget or a live engine. `QcApiClient` has a private constructor and cannot be
/// faked (see the note in qc_ai_load_latest_test.dart), which is why the branch
/// lives in a value type rather than inline in the controller method.
QcTask taskWith({
  int folderId = 1,
  bool imageAvailable = true,
  String boxName = 'BOX-A',
}) =>
    QcTask.fromJson({
      'id': folderId,
      'boxName': boxName,
      'folderSeq': 1,
      'imageCount': 4,
      'imageAvailable': imageAvailable,
      'status': 'pending',
      'sourceHash': 'a' * 64,
      // folderName lives in metadata, and displayName falls back to it when no
      // title has been keyed - which is the usual state of a fresh folder.
      'metadata': <String, Object?>{
        'folderId': folderId,
        'folderName': '$boxName - folder $folderId',
      },
      'metadataTemplate': <String, Object?>{'fields': <Object?>[]},
      'images': <Object?>[],
    });

void main() {
  group('QcNextUp', () {
    test('a held task is something to move to', () {
      final next = QcNextUp(claimed: taskWith(folderId: 7));
      expect(next.hasSomething, isTrue);
      expect(next.claimed!.folderId, 7);
    });

    test('waiting work with nothing held is something to move to', () {
      const next = QcNextUp(claimableCount: 3);
      expect(next.hasSomething, isTrue);
      expect(next.claimed, isNull);
    });

    test('nothing held and nothing waiting means do not prompt', () {
      // The operator is sent to Available without being asked.
      const next = QcNextUp();
      expect(next.hasSomething, isFalse);
      expect(next.claimableCount, 0);
    });

    test('a held task wins even when Available also has work', () {
      // Both set at once should never happen - nextUpAfterCompletion returns
      // early when something is held, so the count is not even fetched - but the
      // preference has to be unambiguous if it ever does.
      final next = QcNextUp(claimed: taskWith(folderId: 9), claimableCount: 5);
      expect(next.claimed!.folderId, 9);
      expect(next.hasSomething, isTrue);
    });

    test('the default count is zero, so a bare instance prompts nothing', () {
      expect(const QcNextUp().claimableCount, 0);
    });
  });

  group('canOpenQcTask', () {
    // The gate the queue card hangs its onTap on. Tested here rather than as a
    // widget test because QcHomePage needs an AuthController and runs a live
    // engine health check on build, so a widget test would pass or fail
    // depending on whether a QC engine happens to be running on the machine.
    test('an Available folder is claim-only, never openable', () {
      expect(canOpenQcTask(QcScope.pending, taskWith()), isFalse);
    });

    test('a claimed folder is openable', () {
      expect(canOpenQcTask(QcScope.mine, taskWith()), isTrue);
    });

    test('a completed folder stays openable, read only', () {
      // Locking Available must not quietly lock this too: the read-only
      // completed view has no other entry point.
      expect(canOpenQcTask(QcScope.completed, taskWith()), isTrue);
    });

    // The folder that prompted this: a QC-inserted image does not survive a
    // capture rework, so the row outlives its file. Requiring EVERY page to be
    // readable meant the folder could not be opened - and opening it is the
    // only way to delete or replace the missing page. It was stuck with no
    // route out.
    QcTask partiallyReadable() => QcTask.fromJson({
          'id': 9,
          'status': 'pending',
          'sourceHash': 'a' * 64,
          'submittedAt': '2026-09-07T00:00:00Z',
          'imageAvailable': false,
          'metadata': {'boxName': 'BOX-A', 'folderName': 'Volume 2'},
          'images': [
            {'id': 1, 'filename': 'a.jpg', 'available': true, 'previewUrl': '/a'},
            {'id': 2, 'filename': 'b.jpg', 'available': false, 'previewUrl': '/b'},
          ],
        });

    test('a folder missing SOME pages can still be opened and fixed', () {
      final task = partiallyReadable();
      expect(task.imageAvailable, isFalse);
      expect(task.anyImageAvailable, isTrue);
      expect(task.missingImageCount, 1);
      expect(canOpenQcTask(QcScope.mine, task), isTrue);
      expect(canOpenQcTask(QcScope.completed, task), isTrue);
    });

    test('a folder missing some pages is still claim-only in Available', () {
      expect(canOpenQcTask(QcScope.pending, partiallyReadable()), isFalse);
    });

    test('an unreadable folder is never openable, in any scope', () {
      final unusable = taskWith(imageAvailable: false);
      for (final scope in QcScope.values) {
        expect(canOpenQcTask(scope, unusable), isFalse, reason: '$scope');
      }
    });
  });

  group('the task offered', () {
    test('an unreadable folder is not work anybody can do', () {
      // nextUpAfterCompletion filters on imageAvailable: offering a folder whose
      // images cannot be read would hand the operator a dead end, which is the
      // same reason its Claim button is disabled in the list.
      final unusable = taskWith(imageAvailable: false);
      expect(unusable.imageAvailable, isFalse);
    });

    test('displayName is what the prompt names the folder by', () {
      // The prompt quotes this, so it must not be empty for a normal task.
      expect(taskWith(boxName: 'BOX-Z').displayName, isNotEmpty);
    });
  });
}
