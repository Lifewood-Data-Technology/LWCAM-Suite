import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';

/// Station Setup and the QC backend are two separate configuration surfaces
/// reading the same PostgreSQL connection. They drifted once already: the
/// backend defaulted to localhost/lwcam/postgres while Station Setup left all
/// three blank, so a fresh station showed empty fields with nothing telling a
/// non-technical operator what to type. These assertions fail if they drift
/// apart again.
void main() {
  test('PostgreSQL defaults match the QC backend', () {
    final config = File('../LWCam_QC_Platform/backend/app/core/config.py');
    if (!config.existsSync()) {
      // Admin can be checked out or built without the QC platform beside it.
      markTestSkipped('QC backend not present at ${config.path}');
      return;
    }
    final source = config.readAsStringSync();

    String backendDefault(String field) {
      final match = RegExp(
        r'^\s*' + field + r':\s*str\s*=\s*"([^"]*)"',
        multiLine: true,
      ).firstMatch(source);
      expect(match, isNotNull, reason: 'no `$field` default in config.py');
      return match!.group(1)!;
    }

    expect(defaultPgHost, backendDefault('db_host'));
    expect(defaultPgDatabase, backendDefault('db_name'));
    // defaultPgUser is deliberately NOT compared: this app defaults to the
    // suite's shared app login (lwcam_user), not the backend's postgres default.
    expect(defaultPgUser, 'lwcam_user');
    expect(StationSetupController().pgPort.value, 5432);
  });

  test('no default password is shipped', () {
    // A baked-in password would be a credential in source control, and one
    // that silently "works" hides a misconfigured station until production.
    expect(
      File('lib/controllers/station_setup_controller.dart').readAsStringSync(),
      isNot(contains('defaultPgPassword')),
    );
  });
}
