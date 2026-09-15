import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/lwip_autostart_service.dart';
import 'package:path/path.dart' as p;

/// Builds a fake LWIP install so root resolution can be exercised without the
/// real one: the marker is pythonw.exe + runtime/.setup_ok plus backend/deskew_crop_tool.
Future<void> fakeLwip(String root) async {
  await Directory(p.join(root, 'runtime', 'python')).create(recursive: true);
  await File(p.join(root, 'runtime', 'python', 'pythonw.exe')).writeAsString('');
  await File(p.join(root, 'runtime', '.setup_ok')).writeAsString('');
  await Directory(p.join(root, 'backend', 'deskew_crop_tool')).create(recursive: true);
}

void main() {
  test('finds LWIP beside the app, as the installer lays it out', () async {
    // Deployed: Admin at <install>\LWCamAdmin, LWIP at <install>\LWCAM\LWIP.
    final temp = await Directory.systemTemp.createTemp('lwip_deployed_');
    try {
      final exe = p.join(temp.path, 'LWCamAdmin', 'lwcam_admin.exe');
      expect(resolveLwipRoot(executablePath: exe), isNull);
      await fakeLwip(p.join(temp.path, 'LWCAM', 'LWIP'));
      expect(
        resolveLwipRoot(executablePath: exe),
        p.join(temp.path, 'LWCAM', 'LWIP'),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('finds LWIP in a source tree several folders up', () async {
    // Portable: exe at <root>\bin\LWCamAdmin, LWIP at <root>\apps\LWCAM\LWIP.
    final temp = await Directory.systemTemp.createTemp('lwip_source_');
    try {
      final exe = p.join(temp.path, 'bin', 'LWCamAdmin', 'lwcam_admin.exe');
      await fakeLwip(p.join(temp.path, 'apps', 'LWCAM', 'LWIP'));
      expect(
        resolveLwipRoot(executablePath: exe),
        p.join(temp.path, 'apps', 'LWCAM', 'LWIP'),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('a runtime without pythonw is not a usable install', () async {
    // python.exe alone would work but pops a console window at every logon,
    // which is the whole reason the launcher targets pythonw.
    final temp = await Directory.systemTemp.createTemp('lwip_nowindow_');
    try {
      final root = p.join(temp.path, 'LWIP');
      await Directory(p.join(root, 'runtime', 'python')).create(recursive: true);
      await File(p.join(root, 'runtime', 'python', 'python.exe')).writeAsString('');
      await Directory(p.join(root, 'backend', 'deskew_crop_tool')).create(recursive: true);
      final exe = p.join(temp.path, 'lwcam_admin.exe');
      expect(resolveLwipRoot(executablePath: exe), isNull);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('LWIP shipped but with no runtime built is not installed', () async {
    // The exact station from the bug report: the installer laid the source
    // down, its setup script failed, and nothing said so. Processing must not
    // switch itself on here - an autostart pointing at an interpreter that was
    // never built is worse than leaving it off.
    final temp = await Directory.systemTemp.createTemp('lwip_norun_');
    try {
      final root = p.join(temp.path, 'LWCAM', 'LWIP');
      await Directory(p.join(root, 'backend', 'deskew_crop_tool')).create(recursive: true);
      await File(p.join(root, 'SETUP_DESKEW_CROP.bat')).writeAsString('');
      final exe = p.join(temp.path, 'LWCamAdmin', 'lwcam_admin.exe');
      expect(resolveLwipRoot(executablePath: exe), isNull);
      expect(isLwipInstalled(executablePath: exe), isFalse);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('isLwipInstalled tracks the resolver', () async {
    final temp = await Directory.systemTemp.createTemp('lwip_flag_');
    try {
      final exe = p.join(temp.path, 'LWCamAdmin', 'lwcam_admin.exe');
      expect(isLwipInstalled(executablePath: exe), isFalse);
      await fakeLwip(p.join(temp.path, 'LWCAM', 'LWIP'));
      expect(isLwipInstalled(executablePath: exe), isTrue);
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
