import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/project.dart';
import 'package:lwcam/pages/project_area_page.dart';

/// The real onInit reads SharedPreferences and the station's users snapshot;
/// this page only needs [AuthController.currentUser].
class _TestAuth extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

/// Since Phase 8 a QC-only grant has no card in LWCAM, so it lands on the same
/// empty screen as a revoked grant - and must not be told its access is gone.
void main() {
  final project = Project(key: 'p1', projectId: 'P1', name: 'Test Project', startDate: DateTime(2026));

  Future<void> pumpAs(WidgetTester tester, AppUser user) async {
    Get.put<AuthController>(_TestAuth()).currentUser.value = user;
    addTearDown(Get.reset);
    await tester.pumpWidget(MaterialApp(home: ProjectAreaPage(project: project)));
  }

  testWidgets('a QC-only account is sent to the QC console', (tester) async {
    await pumpAs(
      tester,
      const AppUser(
        username: 'reviewer',
        passwordHash: 'x',
        roles: {UserRole.qc},
        roleProjectKeys: {UserRole.qc: {'p1'}},
      ),
    );
    expect(find.textContaining('Reviewing happens in the QC console now'), findsOneWidget);
    expect(find.textContaining('no longer have access'), findsNothing);
  });

  testWidgets('an account with no role on the project is told access is gone', (tester) async {
    await pumpAs(
      tester,
      const AppUser(
        username: 'operator',
        passwordHash: 'x',
        roles: {UserRole.capture},
        roleProjectKeys: {UserRole.capture: {'other'}},
      ),
    );
    expect(find.textContaining('You no longer have access to this project'), findsOneWidget);
  });
}
