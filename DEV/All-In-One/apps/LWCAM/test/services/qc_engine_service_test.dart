import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/qc_engine_service.dart';
import 'package:path/path.dart' as p;

Future<void> fakeQc(String root, {String? pythonAt}) async {
  final app = Directory(p.join(root, 'backend', 'app'));
  await app.create(recursive: true);
  await File(p.join(app.path, 'main.py')).writeAsString('');
  if (pythonAt != null) {
    final python = File(p.join(root, pythonAt));
    await python.parent.create(recursive: true);
    await python.writeAsString('');
  }
}

void main() {
  test('finds QC beside the app, as the installer lays it out', () async {
    // Deployed: LWCAM at <install>\LWCAM, QC at <install>\QC.
    final temp = await Directory.systemTemp.createTemp('qc_deployed_');
    try {
      final exe = p.join(temp.path, 'LWCAM', 'lwcam.exe');
      expect(QcEngineService.resolveQcRoot(executablePath: exe), isNull);
      await fakeQc(p.join(temp.path, 'QC'));
      expect(
        QcEngineService.resolveQcRoot(executablePath: exe),
        p.join(temp.path, 'QC'),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('finds QC in a source tree several folders up', () async {
    final temp = await Directory.systemTemp.createTemp('qc_source_');
    try {
      final exe = p.join(temp.path, 'bin', 'LWCAM', 'lwcam.exe');
      await fakeQc(p.join(temp.path, 'apps', 'LWCam_QC_Platform'));
      expect(
        QcEngineService.resolveQcRoot(executablePath: exe),
        p.join(temp.path, 'apps', 'LWCam_QC_Platform'),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('prefers the shipped runtime over a developer venv', () async {
    // A deployed PC has both if someone once ran the dev setup there; the
    // installer's runtime is the one the installer also keeps patched.
    final temp = await Directory.systemTemp.createTemp('qc_python_');
    try {
      final root = p.join(temp.path, 'QC');
      await fakeQc(root, pythonAt: p.join('backend', '.venv', 'Scripts', 'python.exe'));
      expect(
        QcEngineService.resolvePython(root),
        p.join(root, 'backend', '.venv', 'Scripts', 'python.exe'),
      );

      final shipped = File(p.join(root, 'runtime', 'python', 'python.exe'));
      await shipped.parent.create(recursive: true);
      await shipped.writeAsString('');
      expect(QcEngineService.resolvePython(root), shipped.path);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('no interpreter means no engine, not a crash', () async {
    final temp = await Directory.systemTemp.createTemp('qc_nopython_');
    try {
      final root = p.join(temp.path, 'QC');
      await fakeQc(root);
      expect(QcEngineService.resolvePython(root), isNull);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('binds loopback only', () {
    // The sidecar exists so nothing is exposed on the LAN; a change here would
    // silently reopen the port the whole design closes.
    expect(QcEngineService.host, '127.0.0.1');
    expect(QcEngineService.baseUri.toString(), 'http://127.0.0.1:8080');
  });
}
