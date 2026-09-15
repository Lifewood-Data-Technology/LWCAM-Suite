import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_controller.dart';
import 'package:lwcam/theme/app_theme.dart';

/// The queue's task cards read a step smaller than the tabs above them.
///
/// The cause was not a hardcoded size but an assumption: `titleSmall` is 12 in
/// this app, not Material's 14, so a card title styled `titleSmall` sat below
/// the scope tabs' `labelLarge` 14. The card now uses `titleMedium`.
///
/// Stated as a relationship between theme entries rather than as the number 14,
/// so it stays true if the whole scale is ever retuned - and still fails if the
/// card is pointed back at titleSmall.
void main() {
  group('the task card matches the scope tabs', () {
    final text = AppTheme.light.textTheme;

    test('titleMedium is the size the tabs render at', () {
      // SegmentedButton labels take ButtonStyle.textStyle, whose Material
      // default is labelLarge. That is the "Completed tab" size.
      expect(text.titleMedium!.fontSize, text.labelLarge!.fontSize);
    });

    test('titleSmall really is smaller, which is what went wrong', () {
      expect(
        text.titleSmall!.fontSize,
        lessThan(text.labelLarge!.fontSize!),
        reason: 'if these were equal the original styling was never the bug',
      );
    });

    test('the scale is the same in dark mode', () {
      final dark = AppTheme.dark.textTheme;
      expect(dark.titleMedium!.fontSize, text.titleMedium!.fontSize);
      expect(dark.labelLarge!.fontSize, text.labelLarge!.fontSize);
    });
  });

  group('the card actually uses it', () {
    // The group above only proves the THEME's numbers line up. Reverting the
    // card to titleSmall left every one of those assertions passing, which makes
    // them useless as a guard on their own.
    //
    // Checked at the source level because QcHomePage needs an AuthController and
    // runs a live engine health check on build, so a widget test of the card
    // would pass or fail depending on whether a QC engine happens to be running
    // on the machine (see qc_next_up_test.dart for the same reasoning).
    final page = File('lib/pages/qc_home_page.dart').readAsStringSync();

    test('the title is styled titleMedium', () {
      expect(page, contains('style: Theme.of(context).textTheme.titleMedium'));
    });

    test('the title is no longer titleSmall', () {
      expect(page, isNot(contains('textTheme.titleSmall')));
    });

    test('the subtitle is larger than it was', () {
      expect(page, contains('fontSize: 13'));
      expect(page, isNot(contains('fontSize: 11')));
    });
  });

  group('scope labels', () {
    test('the claimed scope is plural', () {
      expect(QcScope.mine.label, 'My tasks');
    });

    test('the other two are unchanged', () {
      expect(QcScope.pending.label, 'Available');
      expect(QcScope.completed.label, 'Completed');
    });

    test('the wire values are untouched by the label change', () {
      // The engine matches on `wire`, so renaming a label must never reach it.
      expect(QcScope.mine.wire, 'mine');
      expect(QcScope.pending.wire, 'pending');
      expect(QcScope.completed.wire, 'completed');
    });
  });
}
