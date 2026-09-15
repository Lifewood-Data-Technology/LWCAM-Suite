import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:path/path.dart' as p;

/// qcInstallRoot answers for two layouts and only the installed one has .bat
/// launchers, so Station Setup cannot infer the setup script from the root it
/// gets back. It used to, and every save from a source tree shelled out to a
/// path that had never existed.
void main() {
  test('source tree has no setup script, so nothing is run', () async {
    final root = await Directory.systemTemp.createTemp('qc_src_');
    try {
      // The marker qcInstallRoot uses for the source layout, and the only thing
      // a source tree has - SETUP_QC_DB.bat is written by the installer.
      final main = File(
        p.join(root.path, 'apps', 'LWCam_QC_Platform', 'backend', 'app', 'main.py'),
      );
      await main.parent.create(recursive: true);
      await main.writeAsString('');
      final executable = p.join(root.path, 'bin', 'LWCamAdmin', 'lwcam_admin.exe');

      // QC IS detected here - that part was never wrong.
      expect(
        isQcAppInstalled(executablePath: executable, environment: const {}),
        isTrue,
      );
      // But there is no launcher to run, which is what the caller must see.
      expect(
        qcSetupDbScript(executablePath: executable, environment: const {}),
        isNull,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('installed layout returns the launcher beside the backend starter',
      () async {
    final root = await Directory.systemTemp.createTemp('qc_installed_');
    try {
      final qc = Directory(p.join(root.path, 'QC'));
      await qc.create(recursive: true);
      // START_QC_BACKEND.bat is what makes qcInstallRoot call this an install;
      // both launchers ship together.
      await File(p.join(qc.path, 'START_QC_BACKEND.bat')).writeAsString('');
      await File(p.join(qc.path, 'SETUP_QC_DB.bat')).writeAsString('');
      final executable = p.join(root.path, 'LWCamAdmin', 'lwcam_admin.exe');

      expect(
        qcSetupDbScript(executablePath: executable, environment: const {}),
        p.join(qc.path, 'SETUP_QC_DB.bat'),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('no QC at all returns null rather than a path under a missing root',
      () async {
    final root = await Directory.systemTemp.createTemp('qc_none_');
    try {
      expect(
        qcSetupDbScript(
          executablePath: p.join(root.path, 'LWCamAdmin', 'lwcam_admin.exe'),
          environment: const {},
        ),
        isNull,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
