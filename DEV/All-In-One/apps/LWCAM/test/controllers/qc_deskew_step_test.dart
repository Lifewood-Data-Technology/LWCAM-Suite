import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';

/// The straighten step the reviewer types, and the bounds it has to stay in.
///
/// The engine rejects anything outside 0.1-10 degrees, so a value that escapes
/// this clamp does not produce a wrong rotation - it produces a 400 and a page
/// that silently refuses to straighten, which reads to the operator as the
/// button being broken. Clamping here is what keeps the field's contract and the
/// engine's the same one.
void main() {
  group('deskew step', () {
    test('defaults to one degree, the long-standing fixed nudge', () {
      expect(QcReviewController(18).deskewStep.value, 1.0);
    });

    test('accepts a fractional step', () {
      final c = QcReviewController(18)..setDeskewStep(0.5);
      expect(c.deskewStep.value, 0.5);
    });

    test('clamps above the maximum instead of sending a rejected value', () {
      final c = QcReviewController(18)..setDeskewStep(45);
      expect(c.deskewStep.value, QcReviewController.deskewStepMax);
    });

    test('clamps below the minimum, including zero', () {
      final c = QcReviewController(18)..setDeskewStep(0);
      expect(c.deskewStep.value, QcReviewController.deskewStepMin);
    });

    test('a negative entry becomes the smallest step, not a reversed one', () {
      // Direction is the button, never the field. A step of -2 would make the
      // left arrow turn the page right.
      final c = QcReviewController(18)..setDeskewStep(-2);
      expect(c.deskewStep.value, QcReviewController.deskewStepMin);
    });

    test('NaN is ignored rather than clamped', () {
      // double.tryParse gives null for junk, but "NaN" itself parses.
      final c = QcReviewController(18)
        ..setDeskewStep(2)
        ..setDeskewStep(double.nan);
      expect(c.deskewStep.value, 2);
    });

    test('the bounds match the engine', () {
      expect(QcReviewController.deskewStepMin, 0.1);
      expect(QcReviewController.deskewStepMax, 10.0);
    });
  });
}
