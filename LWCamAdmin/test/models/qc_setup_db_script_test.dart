import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  test('finds the installed database script and SQL directory', () async {
    final root = await Directory.systemTemp.createTemp('db_installed_');
    try {
      final database = Directory(p.join(root.path, 'Database', 'database'));
      await database.create(recursive: true);
      final script = File(p.join(root.path, 'Database', 'setup_qc_db.py'));
      await script.writeAsString('');
      final executable = p.join(root.path, 'LWCamAdmin', 'lwcam_admin.exe');

      final setup = dbSetupScript(
        executablePath: executable,
      );
      expect(setup?.$1, script.path);
      expect(setup?.$2, database.path);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('finds the source platform script and SQL directory', () async {
    final root = await Directory.systemTemp.createTemp('db_source_');
    try {
      final platform = p.join(root.path, 'LWCam_QC_Platform');
      final database = Directory(p.join(platform, 'database'));
      await database.create(recursive: true);
      final script = File(p.join(platform, 'scripts', 'setup_qc_db.py'));
      await script.parent.create(recursive: true);
      await script.writeAsString('');
      final executable = p.join(
        root.path,
        'LWCamAdmin',
        'build',
        'windows',
        'x64',
        'runner',
        'Debug',
        'admin.exe',
      );

      final setup = dbSetupScript(
        executablePath: executable,
      );
      expect(setup?.$1, script.path);
      expect(setup?.$2, database.path);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('returns null when neither layout is present', () async {
    final root = await Directory.systemTemp.createTemp('db_none_');
    try {
      expect(
        dbSetupScript(
          executablePath: p.join(root.path, 'LWCamAdmin', 'lwcam_admin.exe'),
        ),
        isNull,
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
