import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The export worker count crosses two boundaries with nothing checking either.
///
/// Station Setup writes `exportWorkerCount` into lwcam_node_config.json and the
/// QC engine reads it back out by that string. Neither side can see the other,
/// so a rename in either app leaves the field with no effect at all: the box
/// still takes a number, still saves it, and the export goes on sizing itself
/// from the hardware. Nothing fails - which is what makes it worth a test.
///
/// The controller is checked at the source level because its load and save
/// paths both need a registered NodeConfigService, folder creation and an LWIP
/// config write; standing all that up to prove three assignments exist would
/// cost more than the bug it catches. NodeConfig's own round-trip is covered in
/// node_config_test.dart.
void main() {
  final controller = File('lib/controllers/station_setup_controller.dart');

  test('the controller loads the saved value back into the form', () {
    expect(
      controller.readAsStringSync(),
      contains('exportWorkerCount.value = config.exportWorkerCount;'),
    );
  });

  test('the controller writes the form value into the config', () {
    expect(
      controller.readAsStringSync(),
      contains('exportWorkerCount: exportWorkerCount.value,'),
    );
  });

  test('the QC engine maps the output-format key too', () {
    final mapping = File('../LWCam_QC_Platform/backend/app/core/node_config.py');
    if (!mapping.existsSync()) {
      markTestSkipped('QC backend not present at ${mapping.path}');
      return;
    }
    expect(
      mapping.readAsStringSync(),
      contains('"exportZipOutput": "export_zip_output"'),
    );
  });

  test('the QC engine maps the same key', () {
    final mapping = File('../LWCam_QC_Platform/backend/app/core/node_config.py');
    if (!mapping.existsSync()) {
      // Admin can be checked out or built without the QC platform beside it.
      markTestSkipped('QC backend not present at ${mapping.path}');
      return;
    }
    expect(
      mapping.readAsStringSync(),
      contains('"exportWorkerCount": "export_worker_count"'),
    );
  });
}
