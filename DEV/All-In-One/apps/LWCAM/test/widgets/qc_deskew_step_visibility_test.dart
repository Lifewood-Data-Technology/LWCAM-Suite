import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';
import 'package:lwcam/theme/app_colors.dart';
import 'package:lwcam/theme/app_theme.dart';
import 'package:lwcam/widgets/qc_image_toolbar.dart';

/// The +/- either side of the straighten step, in both themes.
///
/// They shipped twice as invisible. The first attempt assumed contrast and gave
/// the icons an explicit colour, which changed nothing: space was allocated
/// either side of the field and still no mark appeared, and the dark theme's
/// onSurfaceVariant is #A6ACA9 - plainly visible on that toolbar, and the colour
/// every other tool in the row was already drawing fine in. What was actually
/// missing was the GLYPH: `Icons.add` and `Icons.remove` were the only uses of
/// those two codepoints in the app, and a release build tree-shakes MaterialIcons.
///
/// So they are text now. A character from the text font cannot be shaken out of
/// an icon font, which is why this is the fix and not another style tweak.
///
/// The lesson is in the assertions: check that something is DRAWN, not merely
/// that a colour was set. The previous test asserted `icon.color != null` and
/// passed against code the operator could not see.
QcReviewController controllerWith({int? assignedTo = 3}) {
  final controller = QcReviewController(18);
  // assignedTo set: the toolbar disables every control on an unclaimed folder,
  // and a toolbar full of disabled buttons would prove nothing.
  controller.task.value = QcTask.fromJson({
    'id': 18,
    'status': 'pending',
    'sourceHash': 'a' * 64,
    if (assignedTo != null) 'assignedTo': assignedTo,
    'metadata': <String, Object?>{'folderId': 18},
    'metadataTemplate': <String, Object?>{'fields': <Object?>[]},
    'images': [
      {
        'id': 1,
        'filename': 'SAX01_IMG_20260901_1.jpg',
        'available': true,
        'previewUrl': '/api/qc/metadata-tasks/18/images/1/preview?v=1',
        'draftState': null,
        'separationStart': false,
      },
    ],
  });
  return controller;
}

Future<void> pumpToolbar(
  WidgetTester tester,
  QcReviewController controller, {
  required ThemeData theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: QcImageToolbar(
          controller: controller,
          onDelete: () {},
          onInsert: () {},
          onReplace: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The minus is U+2212, not a hyphen.
const minusGlyph = '−';

void main() {
  for (final entry in {'dark': AppTheme.dark, 'light': AppTheme.light}.entries) {
    testWidgets('both step glyphs are really on screen in ${entry.key}',
        (tester) async {
      await pumpToolbar(tester, controllerWith(), theme: entry.value);

      // Text, so a missing icon-font codepoint cannot make them vanish.
      expect(find.text('+'), findsOneWidget);
      expect(find.text(minusGlyph), findsOneWidget);
    });

    testWidgets('the step glyphs match the tools they sit between in '
        '${entry.key}', (tester) async {
      await pumpToolbar(tester, controllerWith(), theme: entry.value);
      final scheme = entry.value.colorScheme;

      for (final glyph in ['+', minusGlyph]) {
        final text = tester.widget<Text>(find.text(glyph));
        expect(text.style?.color, scheme.onSurface,
            reason: 'the step buttons must read as the same control as the '
                'straighten arrows beside them');
      }

      // The arrows use the same token, which is what "same colour" means.
      final arrow = tester.widget<Icon>(find.byIcon(Icons.turn_slight_left));
      expect(arrow.color, scheme.onSurface);
    });
  }

  testWidgets('light mode draws them Dark Serpent, not grey', (tester) async {
    // The complaint was that the row looked washed out: Material 3 defaults an
    // IconButton to onSurfaceVariant (#64736C here), a mid green-grey.
    await pumpToolbar(tester, controllerWith(), theme: AppTheme.light);
    final text = tester.widget<Text>(find.text('+'));
    final colour = text.style!.color!;
    expect(colour, AppColors.darkSerpent);
    expect(colour, isNot(const Color(0xFF64736C)));
  });

  // The toolbar is one of the three review panels that gained a ground. Its
  // root Container is the same one that carries the hairline, so the colour is
  // asserted on that decoration - found as the FIRST Container inside the
  // toolbar, since an ancestor lookup from an icon walks up into the test
  // scaffold and picks an unrelated one.
  Future<Color?> toolbarGround(WidgetTester tester, ThemeData theme) async {
    await pumpToolbar(tester, controllerWith(), theme: theme);
    final container = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(QcImageToolbar),
            matching: find.byType(Container),
          )
          .first,
    );
    return (container.decoration as BoxDecoration).color;
  }

  testWidgets('the toolbar sits on white in light mode', (tester) async {
    expect(await toolbarGround(tester, AppTheme.light), Colors.white);
  });

  testWidgets('the toolbar paints no ground in dark mode', (tester) async {
    expect(await toolbarGround(tester, AppTheme.dark), isNull);
  });

  testWidgets('both are enabled at the default step', (tester) async {
    // If they had merely been disabled, none of the above would be the fix.
    final controller = controllerWith();
    expect(controller.deskewStep.value, 1.0);
    await pumpToolbar(tester, controller, theme: AppTheme.dark);

    for (final glyph in ['+', minusGlyph]) {
      final button = tester.widget<IconButton>(
        find.ancestor(of: find.text(glyph), matching: find.byType(IconButton)),
      );
      expect(button.onPressed, isNotNull, reason: '$glyph should be live');
    }
  });

  testWidgets('a step button at the end of its range is dimmed, not hidden',
      (tester) async {
    // One of the pair is always off at the limits, and it still has to be seen.
    final controller = controllerWith()..setDeskewStep(0.1);
    await pumpToolbar(tester, controller, theme: AppTheme.dark);

    expect(find.text(minusGlyph), findsOneWidget);
    final text = tester.widget<Text>(find.text(minusGlyph));
    // Dimmed = the muted control grey (scheme.outline), a colour of its own
    // rather than a faded copy of the text colour.
    expect(text.style!.color, AppTheme.dark.colorScheme.outline);
  });

  testWidgets('an unclaimed folder dims the whole row', (tester) async {
    await pumpToolbar(tester, controllerWith(assignedTo: null),
        theme: AppTheme.dark);

    final muted = AppTheme.dark.colorScheme.outline;
    final text = tester.widget<Text>(find.text('+'));
    expect(text.style!.color, muted);
    final arrow = tester.widget<Icon>(find.byIcon(Icons.turn_slight_left));
    expect(arrow.color, muted);
  });
}
