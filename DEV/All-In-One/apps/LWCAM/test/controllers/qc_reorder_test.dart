import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';

/// The engine rejects any order that is not an exact permutation of the pages
/// it already has, so an off-by-one here is either a failed request or a
/// silently wrong page order in the exported document.
void main() {
  test('moving a page later lands it after the pages it passed', () {
    expect(QcReviewController.reorderedIds([1, 2, 3, 4], 0, 2), [2, 3, 1, 4]);
  });

  test('moving a page earlier lands it before the pages it passed', () {
    expect(QcReviewController.reorderedIds([1, 2, 3, 4], 3, 1), [1, 4, 2, 3]);
  });

  test('moving a page onto itself changes nothing', () {
    expect(QcReviewController.reorderedIds([1, 2, 3], 1, 1), [1, 2, 3]);
  });

  test('a drop past the end lands at the end rather than throwing', () {
    expect(QcReviewController.reorderedIds([1, 2, 3], 0, 99), [2, 3, 1]);
  });

  test('every page survives the move, exactly once', () {
    // What the engine actually checks: same set, same length.
    final out = QcReviewController.reorderedIds([5, 6, 7, 8, 9], 4, 0);
    expect(out.toSet(), {5, 6, 7, 8, 9});
    expect(out.length, 5);
    expect(out.first, 9);
  });

  test('inserted pages carry negative ids and reorder like any other', () {
    // The draft numbers its own additions downward from -1.
    expect(QcReviewController.reorderedIds([1, -1, 2], 1, 2), [1, 2, -1]);
  });

  test('an out-of-range source is refused rather than corrupting the list', () {
    expect(QcReviewController.reorderedIds([1, 2], 5, 0), [1, 2]);
    expect(QcReviewController.reorderedIds([1, 2], -1, 0), [1, 2]);
  });
}
