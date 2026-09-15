import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/theme/app_colors.dart';
import 'package:lwcam/theme/app_theme.dart';
import 'package:lwcam/widgets/qc_panel_surface.dart';

/// The ground under the review screen's three working panels.
///
/// Asserted by RESOLVED VALUE, not by "a colour was set". A test that only
/// checked non-null passed against two separate broken states earlier in this
/// work, so each expectation below names the actual colour and, where it
/// matters, compares it to the surface it has to be distinguishable from.
Future<Color?> surfaceUnder(WidgetTester tester, ThemeData theme) async {
  Color? seen;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          seen = qcPanelSurface(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return seen;
}

void main() {
  testWidgets('light mode paints the panels white', (tester) async {
    expect(await surfaceUnder(tester, AppTheme.light), Colors.white);
  });

  testWidgets('dark mode paints nothing, so it is untouched', (tester) async {
    // Null rather than a dark colour on purpose: a BoxDecoration with a null
    // colour is exactly what these Containers already had, so dark mode cannot
    // drift from what shipped. A second palette here would be one more thing to
    // keep in step for no gain.
    expect(await surfaceUnder(tester, AppTheme.dark), isNull);
  });

  test('hover is the Material default grey, not a brand colour', () {
    // The operator tried Paper and Sea Salt and asked for the grey back. A
    // translucent overlay also means the panels can never equal it.
    expect(AppTheme.light.hoverColor, const Color(0x0A000000));
    expect(AppTheme.light.hoverColor, isNot(AppColors.paper));
    expect(AppTheme.light.hoverColor, isNot(AppColors.seaSalt));
  });

  test('white is distinguishable from the scaffold behind it', () {
    // Sea Salt is the canvas the panels used to disappear into.
    expect(Colors.white, isNot(AppTheme.lightWindowBackground));
  });

  test('body text has ample contrast on the panels', () {
    // The panels carry every metadata label and the page counter.
    final onSurface = AppTheme.light.colorScheme.onSurface;
    final lighter = Colors.white.computeLuminance();
    final darker = onSurface.computeLuminance();
    final ratio = (lighter + 0.05) / (darker + 0.05);
    expect(ratio, greaterThan(7.0), reason: 'should clear AAA for body text');
  });
}
