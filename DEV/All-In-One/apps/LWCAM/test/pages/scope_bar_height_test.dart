import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/pages/qc_home_page.dart';
import 'package:lwcam/theme/app_theme.dart';

/// The scope bar holds its search box to [scopeBarControlHeight] so the whole
/// row does not grow on entering Completed. That only works while Material's
/// segmented button really is that tall — a Flutter upgrade or a theme change
/// could move it, and the symptom would be a bar that jumps again.
///
/// So this asserts the PREMISE, not the field: the field is pinned to the
/// constant by construction, the tabs are not.
void main() {
  testWidgets('the tabs are as tall as the constant the search box is pinned to', (
    tester,
  ) async {
    // Tests default to Android density, where everything is 48 and the bug is
    // invisible. LWCAM runs on Windows, where adaptivePlatformDensity resolves
    // to compact.
    //
    // Cleared inside the body rather than in a teardown: the framework checks
    // for leaked debug variables before any teardown runs.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Center(
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Available')),
                ButtonSegment(value: 1, label: Text('My tasks')),
                ButtonSegment(value: 2, label: Text('Completed')),
              ],
              selected: const {0},
              onSelectionChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final height = tester.getSize(find.byType(SegmentedButton<int>)).height;
    debugDefaultTargetPlatformOverride = null;

    expect(height, scopeBarControlHeight);
  });
}
