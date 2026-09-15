import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/qc_backend_autostart_service.dart';
import 'package:path/path.dart' as p;

/// The generated launcher carries four things a bare uvicorn command line
/// cannot, and each one fails silently if it goes missing: without the chdir the
/// backend resolves its cache folders somewhere else, without backend on
/// sys.path `app` will not import, without LWCAM_NODE_CONFIG an installed
/// station - which ships no .env at all - falls back to defaults with no
/// database password, and without the `__main__` guard every export worker
/// re-runs this file and starts its own uvicorn.
void main() {
  test('an installed QC folder is found by its launcher .bat', () async {
    final root = await Directory.systemTemp.createTemp('qc_auto_');
    try {
      final qc = Directory(p.join(root.path, 'QC'));
      await qc.create(recursive: true);
      await File(p.join(qc.path, 'START_QC_BACKEND.bat')).writeAsString('');
      // Admin sits beside QC in the installed layout.
      final exe = p.join(root.path, 'LWCamAdmin', 'lwcam_admin.exe');
      expect(resolveInstalledQcRoot(executablePath: exe), qc.path);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a source tree resolves to null and is skipped silently', () async {
    final root = await Directory.systemTemp.createTemp('qc_auto_src_');
    try {
      // Source layout: the platform, but no launchers and no built runtime.
      final main = File(p.join(
          root.path, 'apps', 'LWCam_QC_Platform', 'backend', 'app', 'main.py'));
      await main.parent.create(recursive: true);
      await main.writeAsString('');
      final exe = p.join(root.path, 'bin', 'LWCamAdmin', 'lwcam_admin.exe');
      expect(resolveInstalledQcRoot(executablePath: exe), isNull);
      // Nothing to register, and nothing to complain about either.
      expect(await enableQcBackendAutostart(executablePath: exe), isNull);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('a missing runtime is reported, not silently skipped', () async {
    final root = await Directory.systemTemp.createTemp('qc_auto_noruntime_');
    try {
      final qc = Directory(p.join(root.path, 'QC'));
      await qc.create(recursive: true);
      await File(p.join(qc.path, 'START_QC_BACKEND.bat')).writeAsString('');
      final exe = p.join(root.path, 'LWCamAdmin', 'lwcam_admin.exe');
      // Installed, but SETUP_QC.bat has not built runtime\python yet.
      final reason = await enableQcBackendAutostart(executablePath: exe);
      expect(reason, isNotNull);
      expect(reason, contains('SETUP_QC.bat'));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('the launcher sets cwd, sys.path, the config env var and the port',
      () async {
    final root = await Directory.systemTemp.createTemp('qc_auto_launch_');
    try {
      final qc = p.join(root.path, 'QC');
      await Directory(qc).create(recursive: true);
      final file = await writeQcBackendLauncher(qc);
      final text = await file.readAsString();
      final backend = p.join(qc, 'backend');

      expect(file.path, p.join(qc, 'runtime', 'qc_backend_autostart.py'));
      expect(text, contains('os.chdir(backend)'));
      expect(text, contains('sys.path.insert(0, backend)'));
      expect(text, contains('LWCAM_NODE_CONFIG'));
      expect(text, contains('lwcam_node_config.json'));
      expect(text, contains(backend));
      // Same port START_QC_BACKEND.bat uses; drifting apart would leave LWCAM
      // and the console looking for the backend somewhere it is not.
      expect(text, contains('port=$kQcBackendPort'));
      expect(kQcBackendPort, 8080);

      // The launcher is run as a SCRIPT, so it is `__main__`, and the export
      // converts images in a ProcessPoolExecutor - which on Windows spawns
      // fresh interpreters that re-run the main module. Unguarded, every export
      // worker calls uvicorn.run itself, blocks on the port instead of
      // converting its image, and the pool dies with BrokenProcessPool. This
      // breaks exports ONLY on an installed station: the other two launch paths
      // use `python -m uvicorn`, which multiprocessing skips re-running.
      expect(text, contains('if __name__ == "__main__":'));
      final guard = text.indexOf('if __name__ == "__main__":');
      expect(guard, greaterThan(-1));
      expect(text.indexOf('uvicorn.run('), greaterThan(guard),
          reason: 'uvicorn.run must be INSIDE the guard, not before it');
      // The setup must stay OUTSIDE it - a re-imported worker needs backend on
      // sys.path to unpickle the export function.
      expect(text.indexOf('sys.path.insert(0, backend)'), lessThan(guard));
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('the launcher redirects output to a log, inside the guard', () async {
    // A station ran with no backend log at all on 2026-09-09, so an unopenable
    // Quality Check page and a 400 on the Completed tab both had to be
    // diagnosed from a client-side error banner. pythonw.exe has no console,
    // so without this redirection every line the backend writes is discarded.
    final root = await Directory.systemTemp.createTemp('qc_auto_log_');
    try {
      final qc = p.join(root.path, 'QC');
      await Directory(qc).create(recursive: true);
      final file = await writeQcBackendLauncher(qc);
      final text = await file.readAsString();

      // Beside qc_engine.log in the node-config folder, NOT under
      // %LOCALAPPDATA%\LWCam\QC, which SETUP_QC.bat reserves for caches.
      expect(text, contains('qc_backend.log'));
      expect(text, contains(qcBackendLogPath()));
      expect(p.basename(p.dirname(qcBackendLogPath())), 'LWCAM_DBs');
      expect(qcBackendLogPath(), isNot(contains('LOCALAPPDATA')));

      // Both streams share ONE handle, so access and error output interleave
      // in order rather than racing two handles over one file.
      expect(text, contains('sys.stderr = sys.stdout'));

      final guard = text.indexOf('if __name__ == "__main__":');
      expect(guard, greaterThan(-1));
      expect(text.indexOf('sys.stdout = open('), greaterThan(guard),
          reason: 'every export worker re-runs this file; they must not each '
              'reopen the log handle, so the redirect belongs INSIDE the guard');
      // And it must still come before the server starts, or uvicorn's own
      // startup output - the part that names a bad config - is lost.
      expect(text.indexOf('sys.stdout = open('),
          lessThan(text.indexOf('uvicorn.run(')),
          reason: 'redirect before uvicorn.run, or startup output is discarded');
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('pythonw, not python, so no console window appears at logon', () {
    final qc = p.join('C:', 'Program Files', 'LW Suite', 'QC');
    expect(p.basename(qcPythonwPath(qc)), 'pythonw.exe');
    expect(qcPythonwPath(qc), contains(p.join('runtime', 'python')));
  });
}
