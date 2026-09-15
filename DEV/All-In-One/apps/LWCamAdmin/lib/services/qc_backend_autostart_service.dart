// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;

import 'admin_bootstrap.dart' show defaultLwcamDbsDir;
import 'node_config_service.dart';

/// Makes the QC backend run on its own, instead of only when someone remembers
/// to double-click START_QC_BACKEND.bat.
///
/// Same mechanism, and the same reasoning, as [enableLwipAutostart]: a value
/// under HKCU\...\CurrentVersion\Run launching `pythonw.exe` (no console
/// window). A service or a scheduled task would need elevation LWCam Admin does
/// not have, while the Run key is per-user, needs no stored credentials, and
/// stays visible to the operator under Task Manager > Startup apps.
///
/// Cost, stated plainly: this starts the backend at LOGON, not at boot, and it
/// runs for the whole session even if nobody opens LWCAM. On a capture or
/// all-in-one station that logs in, logon and boot amount to the same thing, and
/// an idle uvicorn is cheap.
///
/// Only one backend can hold port 8080. A second copy fails to bind and exits on
/// its own, which is why [startQcBackendNow] does not bother checking first -
/// the same self-limiting property LWIP gets from its orchestrator lock.
const String _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

/// Value name under the Run key. Stable, so an upgrade replaces the previous
/// entry instead of stacking a second one.
const String kQcBackendAutostartValueName = 'LWCamQcBackend';

/// The port START_QC_BACKEND.bat uses, kept identical so the console, LWCAM and
/// this launcher all agree on where the backend lives.
const int kQcBackendPort = 8080;

/// The INSTALLED QC folder (`<install>\QC`), or null.
///
/// Deliberately keyed on START_QC_BACKEND.bat rather than on the backend source:
/// only an installed station has the launchers, and only an installed station has
/// a `runtime\python` built by SETUP_QC.bat. A source tree resolves to null and is
/// skipped silently - a developer starts the backend with start-qc.ps1, and
/// nagging them at every save would be noise.
String? resolveInstalledQcRoot({String? executablePath}) {
  var dir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  for (var level = 0; level < 8; level++) {
    final qc = p.join(dir, 'QC');
    if (File(p.join(qc, 'START_QC_BACKEND.bat')).existsSync()) return qc;
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return null;
}

/// `pythonw.exe` of the private runtime SETUP_QC.bat builds, so no console
/// window flashes at logon.
String qcPythonwPath(String qcRoot) =>
    p.join(qcRoot, 'runtime', 'python', 'pythonw.exe');

/// Written into `<QC>\runtime`, which the installer creates with users-modify
/// rights precisely because it is filled in after install by the same
/// unelevated user that runs it.
String qcLauncherPath(String qcRoot) =>
    p.join(qcRoot, 'runtime', 'qc_backend_autostart.py');

String qcNodeConfigPath() =>
    p.join(defaultLwcamDbsDir(), NodeConfigService.fileName);

/// Where the logon-started backend writes its output.
///
/// Beside `qc_engine.log`, `scrcpy.log` and `lwip\runtime\deskew_crop.log`, in
/// the same folder as the node config - the convention LWCAM's own
/// `QcEngineService._log` already follows, and for the same stated reason: a
/// release exe has no console, so a field failure would otherwise be invisible.
/// `%LOCALAPPDATA%\LWCam\QC` is deliberately NOT used; SETUP_QC.bat and
/// `node_config.py` reserve that tree for caches (previews, qc_work, qc_audit,
/// ai_review).
///
/// This mattered twice on 2026-09-09: a station had no backend log at all, so
/// an unopenable Quality Check page and a 400 on the Completed tab both had to
/// be diagnosed from a client-side error banner.
String qcBackendLogPath() =>
    p.join(defaultLwcamDbsDir(), 'qc_backend.log');

/// Writes the launcher the Run key invokes.
///
/// Four things it has to arrange that a bare `uvicorn` command line cannot.
/// The backend resolves its `.env` and its cache folders relative to the working
/// directory, and a Run key has no working directory - START_QC_BACKEND.bat gets
/// this by `cd`-ing first, which a Run key cannot do without `cmd /c` flashing a
/// console at every logon. `app` has to be importable, so backend goes on
/// sys.path. And an installed station ships NO .env at all, so without
/// LWCAM_NODE_CONFIG the backend silently falls back to defaults with no
/// password and fails to reach PostgreSQL.
///
/// And it must guard `uvicorn.run` behind `__main__`. This launcher is run as a
/// SCRIPT, so it is `__main__` - and the export converts images in a
/// ProcessPoolExecutor, which on Windows spawns fresh interpreters that re-run
/// the main module to rebuild it. Unguarded, every export worker re-executes
/// this file and calls `uvicorn.run` itself: each one blocks trying to serve
/// port $kQcBackendPort, never runs its image, and the pool dies with
/// BrokenProcessPool. Exports would fail on an installed station and nowhere
/// else, because the two other launch paths (START_QC_BACKEND.bat and LWCAM's
/// sidecar) both use `python -m uvicorn`, which multiprocessing deliberately
/// skips re-running. The setup lines stay OUTSIDE the guard on purpose: a
/// re-imported worker needs `backend` on sys.path to unpickle the export
/// function.
///
/// The log redirection is INSIDE the guard for the same reason `uvicorn.run`
/// is: every export worker re-executes this file, and they must not each
/// reopen the same log handle. Redirection is pure gain here - the Run key
/// launches `pythonw.exe`, which has no console at all, so without it every
/// line the backend writes is discarded.
Future<File> writeQcBackendLauncher(String qcRoot) async {
  final backend = p.join(qcRoot, 'backend');
  final file = File(qcLauncherPath(qcRoot));
  await file.parent.create(recursive: true);
  await file.writeAsString('''
# Generated by LWCam Admin (Station Setup). Do not edit - it is rewritten on save.
import os
import sys

backend = r"$backend"
os.chdir(backend)
sys.path.insert(0, backend)
os.environ.setdefault("LWCAM_NODE_CONFIG", r"${qcNodeConfigPath()}")

import uvicorn

# Guarded because the export's process pool re-runs this file in every worker.
# See the doc comment on writeQcBackendLauncher.
if __name__ == "__main__":
    # pythonw.exe has no console, so without this every line the backend
    # writes is discarded - which is why two faults on 2026-09-09 had to be
    # diagnosed from a client error banner. One handle for both streams, so
    # access and error output interleave in order instead of racing.
    # errors="replace": a traceback carrying an odd byte must not kill the
    # log that exists to report it.
    _log = r"${qcBackendLogPath()}"
    try:
        if os.path.exists(_log) and os.path.getsize(_log) > 10 * 1024 * 1024:
            os.replace(_log, _log + ".old")
    except OSError:
        pass  # still held by an engine that was not stopped: keep appending
    try:
        sys.stdout = open(_log, "a", buffering=1, encoding="utf-8", errors="replace")
        sys.stderr = sys.stdout
    except OSError:
        pass  # an unwritable log must never stop the server starting

    # Loopback only. LWCAM talks to its OWN PC's engine (qc_engine_service.dart
    # hard-codes 127.0.0.1); on a two-PC site the QC PC runs its own engine and
    # reaches the capture PC over 5432 and the share, never over 8080. Binding
    # every interface exposed the engine's login to whatever network the office
    # NIC is on, for nothing.
    uvicorn.run("app.main:app", host="127.0.0.1", port=$kQcBackendPort)
''', flush: true);
  return file;
}

Future<ProcessResult> _reg(List<String> arguments) =>
    Process.run('reg.exe', arguments);

/// Registers the QC backend to start at logon. Returns null on success (and on a
/// source tree, where there is nothing to register), else the reason.
Future<String?> enableQcBackendAutostart({String? executablePath}) async {
  final root = resolveInstalledQcRoot(executablePath: executablePath);
  if (root == null) return null; // source tree - see resolveInstalledQcRoot
  final pythonw = qcPythonwPath(root);
  if (!File(pythonw).existsSync()) {
    return 'The QC backend runtime is missing, so the QC server cannot start '
        'automatically. Run SETUP_QC.bat in the QC folder, then save again.';
  }
  await writeQcBackendLauncher(root);
  final command = '"$pythonw" "${qcLauncherPath(root)}"';
  final result = await _reg([
    'add',
    _runKey,
    '/v',
    kQcBackendAutostartValueName,
    '/t',
    'REG_SZ',
    '/d',
    command,
    '/f',
  ]);
  if (result.exitCode != 0) {
    return 'Could not register the QC backend to start automatically: '
        '${(result.stderr as String).trim()}';
  }
  print('🧪 QC backend autostart registered: $command');
  return null;
}

/// Removes the autostart entry. Succeeds when there was nothing to remove.
Future<void> disableQcBackendAutostart() async {
  final result = await _reg([
    'delete',
    _runKey,
    '/v',
    kQcBackendAutostartValueName,
    '/f',
  ]);
  // A non-zero exit is "value does not exist", which is the wanted end state.
  if (result.exitCode == 0) print('🧪 QC backend autostart removed.');
}

/// Whether the autostart entry is currently registered.
Future<bool> isQcBackendAutostartEnabled() async {
  final result = await _reg([
    'query',
    _runKey,
    '/v',
    kQcBackendAutostartValueName,
  ]);
  return result.exitCode == 0;
}

/// Stops every QC backend process started from [qcRoot]. Returns how many.
///
/// Matched by COMMAND LINE against the QC folder, never by name, so a
/// station's other Python - LWIP's workers among them - is untouched. Same
/// rule and same PowerShell shape as the installer's StopQcBackend. Best
/// effort: a failure here means the fresh start below fails to bind and the
/// old engine keeps running, which is exactly what happened before this
/// existed, not something worse.
Future<int> stopQcBackend(String qcRoot) async {
  // The name filter is WQL so WMI does it rather than PowerShell over the
  // whole process table, and the settle delay is 700 ms only when something
  // was stopped. Kept token for token with the installer's StopQcBackend,
  // which cannot use braces, so neither does this.
  final script =
      r"$p = @(Get-CimInstance Win32_Process -Filter 'Name LIKE ''python%.exe''' | "
      "Where-Object CommandLine -like '*$qcRoot*'); "
      r"$p | Invoke-CimMethod -MethodName Terminate | Out-Null; "
      r'Start-Sleep -Milliseconds ([Math]::Min($p.Count, 1) * 700); '
      r'exit $p.Count';
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (result.exitCode > 0) {
      print('🧪 Stopped ${result.exitCode} QC backend(s).');
    }
    return result.exitCode < 0 ? 0 : result.exitCode;
  } catch (e) {
    print('⚠️ Could not stop the running QC backend: $e');
    return 0;
  }
}

/// Restarts the backend now, so saving Station Setup takes effect at once.
///
/// The engine reads its configuration once at import, so a save that only
/// STARTED a backend changed nothing on a station where one was already up:
/// the new copy failed to bind port [kQcBackendPort] and exited, and the old
/// one kept serving the old settings until the next logon. That is why the
/// running one is stopped first. An export mid-flight resumes on its own
/// (`resume_if_needed`), which is what makes the stop safe.
///
/// Detached on purpose: it must outlive LWCam Admin.
Future<void> startQcBackendNow({String? executablePath}) async {
  final root = resolveInstalledQcRoot(executablePath: executablePath);
  if (root == null) return;
  final pythonw = qcPythonwPath(root);
  if (!File(pythonw).existsSync()) return;
  await stopQcBackend(root);
  try {
    await Process.start(pythonw, [
      qcLauncherPath(root),
    ], mode: ProcessStartMode.detached);
    print('🧪 QC backend started.');
  } catch (e) {
    print(
      '⚠️ Could not start the QC backend now '
      '(it will start at next logon): $e',
    );
  }
}
