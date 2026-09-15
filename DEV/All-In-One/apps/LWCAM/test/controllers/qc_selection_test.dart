import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';

/// The ticked pages decide what a batch rotate, deskew, luminance or delete
/// actually touches. Getting this wrong is not a cosmetic bug: it edits or
/// removes scans the reviewer did not choose, and the engine has no way to tell
/// a mistaken list from a deliberate one.
Map<String, Object?> imageJson(int id, {bool available = true}) => {
      'id': id,
      'filename': 'SAX01_IMG_2026081_$id.jpg',
      'available': available,
      'previewUrl': '/api/qc/metadata-tasks/18/images/$id/preview?v=1',
      'draftState': null,
      'separationStart': false,
    };

QcReviewController controllerWith(List<Map<String, Object?>> images) {
  final controller = QcReviewController(18);
  controller.task.value = QcTask.fromJson({
    'id': 18,
    'status': 'pending',
    'sourceHash': 'a' * 64,
    'assignedTo': 3,
    'metadata': <String, Object?>{'folderId': 18},
    'metadataTemplate': <String, Object?>{'fields': <Object?>[]},
    'images': images,
  });
  return controller;
}

QcReviewController fourPages() => controllerWith(
    [imageJson(11), imageJson(12), imageJson(13), imageJson(14)]);

void main() {
  group('targetIds', () {
    test('with nothing ticked, an operation acts on the page on screen', () {
      final controller = fourPages();
      controller.index.value = 2;
      expect(controller.targetIds, [13]);
    });

    test('with pages ticked, it acts on those and not on the page on screen',
        () {
      final controller = fourPages();
      controller.index.value = 0;
      controller.selected.addAll([12, 14]);
      expect(controller.targetIds, [12, 14]);
    });

    test('ids come back in page order, not the order they were ticked', () {
      // The engine records what it was sent, and a reviewer reading the audit
      // should see the rail's order rather than the order of their clicks.
      final controller = fourPages();
      controller.selected.addAll([14, 11, 13]);
      expect(controller.targetIds, [11, 13, 14]);
    });

    test('a tick left over from a deleted page cannot reach the engine', () {
      // The prune in _adopt is the first line of defence; this is the second,
      // and the one that matters - a stale id sent to a batch endpoint is a 404
      // for the whole request, or worse against a recycled id.
      final controller = fourPages();
      controller.selected.addAll([12, 999]);
      expect(controller.targetIds, [12]);
    });

    test('an empty folder targets nothing rather than throwing', () {
      final controller = controllerWith([]);
      expect(controller.targetIds, isEmpty);
    });
  });

  group('selectRange', () {
    test('ticks every page between the two ends, inclusive', () {
      final controller = fourPages();
      controller.selectRange(1, 3);
      expect(controller.targetIds, [12, 13, 14]);
    });

    test('works upwards as well as downwards', () {
      final controller = fourPages();
      controller.selectRange(3, 1);
      expect(controller.targetIds, [12, 13, 14]);
    });

    test('adds to what is already ticked rather than replacing it', () {
      // Shift-click after ctrl-clicking elsewhere must not silently drop the
      // earlier picks - that is the web console's behaviour and the one an
      // operator moving between the two clients expects.
      final controller = fourPages();
      controller.selected.add(11);
      controller.selectRange(2, 3);
      expect(controller.targetIds, [11, 13, 14]);
    });

    test('skips a broken page, which no operation can act on', () {
      final controller = controllerWith([
        imageJson(11),
        imageJson(12, available: false),
        imageJson(13),
      ]);
      controller.selectRange(0, 2);
      expect(controller.targetIds, [11, 13]);
    });

    test('a range past the end clamps instead of throwing', () {
      final controller = fourPages();
      controller.selectRange(2, 99);
      expect(controller.targetIds, [13, 14]);
    });
  });

  group('toggleSelect and setSelectAll', () {
    test('toggling the same page twice leaves it unticked', () {
      final controller = fourPages();
      controller.toggleSelect(12);
      expect(controller.targetIds, [12]);
      controller.toggleSelect(12);
      expect(controller.selected, isEmpty);
    });

    test('select-all ticks every usable page, clear empties the selection', () {
      final controller = fourPages();
      controller.setSelectAll(true);
      expect(controller.targetIds, [11, 12, 13, 14]);
      expect(controller.allSelected, isTrue);
      controller.setSelectAll(false);
      expect(controller.selected, isEmpty);
      expect(controller.allSelected, isFalse);
    });

    test('select-all leaves broken pages alone and still reads as all', () {
      // Otherwise the header checkbox could never show ticked on a folder with
      // one bad scan, and the operator would keep clicking it.
      final controller = controllerWith([
        imageJson(11),
        imageJson(12, available: false),
      ]);
      controller.setSelectAll(true);
      expect(controller.targetIds, [11]);
      expect(controller.allSelected, isTrue);
    });

    test('a partial selection does not read as all', () {
      final controller = fourPages();
      controller.selected.addAll([11, 12]);
      expect(controller.allSelected, isFalse);
    });

    test('an empty folder never reads as all', () {
      expect(controllerWith([]).allSelected, isFalse);
    });
  });
}
