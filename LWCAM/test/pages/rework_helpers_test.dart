import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/pages/gallery_page.dart';
import 'package:lwcam/services/rework_service.dart';

ReworkItem _item({
  required int folderSeq,
  required String imageName,
  int reworkId = 0,
  int pageNumber = 0,
  int pageCount = 0,
}) =>
    ReworkItem(
      pageNumber: pageNumber,
      pageCount: pageCount,
      reworkId: reworkId,
      projectKey: 'pk1',
      projectId: 'PRJ-1',
      boxName: 'BOX-9',
      folderSeq: folderSeq,
      folderName: 'F$folderSeq',
      folderPath: r'D:\out\20260730\F1',
      qcStatus: 'REWORK',
      imageName: imageName,
      reason: 'blurry',
      reworkType: 'Recapture',
    );

CaptureFolder _folder(int seq) => CaptureFolder(boxId: 1, id: seq, folderSeq: seq);

void main() {
  // The tile shows only a device-prefixed filename whose tail ellipsizes away,
  // so the page number is the one fact that survives truncation. Zero means the
  // query could not place the image; the label then stays empty rather than
  // claiming "00 / 0".
  group('ReworkItem.pageLabel', () {
    test('pads to two digits and names the folder total', () {
      expect(
        _item(folderSeq: 1, imageName: 'a.jpg', pageNumber: 7, pageCount: 24)
            .pageLabel,
        '07 / 24',
      );
    });

    test('is empty when the position is unknown', () {
      expect(_item(folderSeq: 1, imageName: 'a.jpg').pageLabel, '');
    });
  });

  // gallery_page.dart itself is not unit-testable (ADB, scrcpy, a live phone),
  // so the parts of rework mode that can be wrong silently live out here.
  group('groupReworkByFolderSeq', () {
    // Keyed by folder_seq, NOT filename: assignments are keyed by the DEVICE
    // filename while rework_logs and LWIP's input folder use the final
    // transferred name. Matching on names would silently find nothing.
    test('groups items per folder, preserving order', () {
      final grouped = groupReworkByFolderSeq([
        _item(folderSeq: 1, imageName: 'a.jpg'),
        _item(folderSeq: 2, imageName: 'b.jpg'),
        _item(folderSeq: 1, imageName: 'c.jpg'),
      ]);
      expect(grouped.keys.toSet(), {1, 2});
      expect(grouped[1]!.map((i) => i.imageName).toList(), ['a.jpg', 'c.jpg']);
      expect(grouped[2]!, hasLength(1));
    });

    test('an empty worklist groups to nothing', () {
      expect(groupReworkByFolderSeq(const []), isEmpty);
    });
  });

  group('reworkFoldersFor', () {
    test('keeps only folders with open requests, in the box order', () {
      final folders = [_folder(1), _folder(2), _folder(3)];
      final byFolder = groupReworkByFolderSeq([
        _item(folderSeq: 3, imageName: 'c.jpg'),
        _item(folderSeq: 1, imageName: 'a.jpg'),
      ]);
      expect(
          reworkFoldersFor(folders, byFolder, boxId: 1)
              .map((f) => f.folderSeq)
              .toList(),
          [1, 3]);
    });

    // Separation children exist only in PG — QC minted their rows when it split
    // the folder, so they never sync into LWCAM's local capture_folders. The
    // grid must still render them: everything rework needs travels in the
    // worklist items, and id == 0 marks "no local row" so the metadata save
    // knows to skip the local write.
    test('synthesizes a placeholder for a folder with no local row', () {
      final byFolder = groupReworkByFolderSeq([
        _item(folderSeq: 99, imageName: 'a.jpg'),
      ]);
      final result = reworkFoldersFor([_folder(1)], byFolder, boxId: 7);
      expect(result, hasLength(1));
      expect(result.single.id, 0, reason: 'id 0 = not a local row');
      expect(result.single.boxId, 7);
      expect(result.single.folderSeq, 99);
      expect(result.single.folderName, 'F99');
    });

    test('local folders come first, placeholders after in seq order', () {
      final byFolder = groupReworkByFolderSeq([
        _item(folderSeq: 8, imageName: 'c.jpg'),
        _item(folderSeq: 2, imageName: 'a.jpg'),
        _item(folderSeq: 6, imageName: 'b.jpg'),
      ]);
      final result =
          reworkFoldersFor([_folder(1), _folder(2)], byFolder, boxId: 1);
      expect(result.map((f) => f.folderSeq).toList(), [2, 6, 8]);
      expect(result.map((f) => f.id != 0).toList(), [true, false, false]);
    });

    test('empty worklist yields no folders', () {
      expect(reworkFoldersFor([_folder(1)], const {}, boxId: 1), isEmpty);
    });
  });

  group('reworkResolutionFor', () {
    test('a staged recapture wins over a metadata claim', () {
      expect(
        reworkResolutionFor('a.jpg',
            staged: {'a.jpg'}, metadataFixed: {'a.jpg'}),
        'Recapture',
      );
    });

    test('metadata fix alone closes as Metadata', () {
      expect(
        reworkResolutionFor('a.jpg', staged: const {}, metadataFixed: {'a.jpg'}),
        'Metadata',
      );
    });

    test('an untouched item stays open', () {
      expect(
        reworkResolutionFor('a.jpg', staged: const {}, metadataFixed: const {}),
        isNull,
      );
    });
  });

  // Guards Submit: LWIP flips qc_status to PENDING on ANY file change, so a
  // partial recapture must not be allowed to send the folder back to QC while
  // other rejected pages in it are still unresolved.
  group('reworkOpenItemCount', () {
    test('counts items that are neither staged nor metadata-fixed', () {
      final items = [
        _item(folderSeq: 1, imageName: 'a.jpg'),
        _item(folderSeq: 1, imageName: 'b.jpg'),
        _item(folderSeq: 1, imageName: 'c.jpg'),
      ];
      expect(
        reworkOpenItemCount(items, staged: {'a.jpg'}, metadataFixed: {'b.jpg'}),
        1,
      );
    });

    test('zero once every item is closed', () {
      final items = [
        _item(folderSeq: 1, imageName: 'a.jpg'),
        _item(folderSeq: 1, imageName: 'b.jpg'),
      ];
      expect(
        reworkOpenItemCount(items, staged: {'a.jpg'}, metadataFixed: {'b.jpg'}),
        0,
      );
    });

    test('every item open when nothing has been closed', () {
      final items = [_item(folderSeq: 1, imageName: 'a.jpg')];
      expect(
        reworkOpenItemCount(items, staged: const {}, metadataFixed: const {}),
        1,
      );
    });
  });

  // The rule that keeps a metadata-only fix from getting stuck, without letting
  // a recapture reach QC before LWIP has verified the new output.
  group('reworkShouldResetQcStatus', () {
    test('metadata-only fix resets it — LWIP never will', () {
      // No file changed, so the folder's fingerprint is identical and LWIP has
      // no reason to reprocess. Without this the folder sits in REWORK forever.
      expect(
          reworkShouldResetQcStatus(closedInFolder: 2, recapturedInFolder: 0),
          isTrue);
    });

    test('any recapture leaves the reset to LWIP', () {
      // Resetting here too would let QC claim the folder before the reprocessed
      // output had been verified.
      expect(
          reworkShouldResetQcStatus(closedInFolder: 2, recapturedInFolder: 1),
          isFalse);
    });

    test('a folder that settled nothing is not touched', () {
      expect(
          reworkShouldResetQcStatus(closedInFolder: 0, recapturedInFolder: 0),
          isFalse);
    });
  });

  group('reworkClosed', () {
    test('closedReworkImages maps outbox closure keys to image names', () {
      final items = [
        _item(folderSeq: 1, imageName: 'a.jpg'),
        _item(folderSeq: 2, imageName: 'b.jpg'),
      ];
      expect(
        closedReworkImages(items, {'pk1|BOX-9|1|a.jpg'}),
        {'a.jpg'},
      );
    });

    test('a closed page is not counted open', () {
      final items = [
        _item(folderSeq: 1, imageName: 'a.jpg'),
        _item(folderSeq: 2, imageName: 'b.jpg'),
      ];
      expect(
        reworkOpenItemCount(
          items,
          staged: const {},
          metadataFixed: const {},
          closed: const {'a.jpg'},
        ),
        1,
      );
      expect(
        reworkOpenItemCount(
          items,
          staged: const {},
          metadataFixed: const {'a.jpg'},
          closed: const {'a.jpg'},
        ),
        1,
        reason: 'closed wins over a stale metadata mark',
      );
    });
  });

  group('reworkSourceForItem', () {
    test('a metadata-only item never reads the durable intent', () async {
      var calls = 0;
      final source = await reworkSourceForItem(
        staged: null,
        pending: () async {
          calls++;
          return File('C:/store/stale.jpg');
        },
      );
      expect(source, isNull);
      expect(calls, 0);
    });

    test('a staged page uses its matching durable generation', () async {
      final staged = File('C:/store/staged.jpg');
      final source = await reworkSourceForItem(
        staged: staged,
        pending: () async => staged,
      );
      expect(source, same(staged));
    });

    test('a missing or different intent is damaged staging', () async {
      final staged = File('C:/store/staged.jpg');
      await expectLater(
        reworkSourceForItem(staged: staged, pending: () async => null),
        throwsStateError,
      );
      await expectLater(
        reworkSourceForItem(
          staged: staged,
          pending: () async => File('C:/store/other.jpg'),
        ),
        throwsStateError,
      );
    });
  });
}
