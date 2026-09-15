// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;

import 'admin_bootstrap.dart';
import 'lwip_config_writer.dart';
import 'node_config_service.dart';

/// Makes LWIP run on its own, instead of only while LWCAM happens to be open.
///
/// Mechanism: a value under HKCU\...\CurrentVersion\Run launching `pythonw.exe`
/// (no console window) against a small generated launcher.
///
/// Why not a Windows service or a scheduled task: both need elevation to
/// register, and LWCam Admin runs unelevated — `schtasks /create` returns
/// "Access is denied" here. A task set to run whether or not the user is logged
/// on would also need stored credentials. The Run key needs neither, is per-user,
/// and stays visible to the operator in Task Manager > Startup apps.
///
/// The honest cost: this starts LWIP at LOGON, not at boot. On a station that
/// logs in — every capture and all-in-one PC — those are the same thing. A PC
/// that must process while sitting at the login screen needs a real service, and
/// that needs an elevated installer step.
///
/// Only ONE LWIP may run per output root: it takes an orchestrator lock and a
/// second instance exits rather than corrupting the first. That is exactly why
/// LWCAM no longer spawns LWIP itself — see LWCAM's ProcessingBootstrap.

const String _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

/// Value name under the Run key. Stable, so an upgrade replaces the previous
/// entry instead of stacking a second one.
const String kLwipAutostartValueName = 'LWCamLWIP';

/// Locates the LWIP install: `<root>\runtime\python\pythonw.exe` plus
/// `<root>\backend\deskew_crop_tool`.
///
/// Checks the exe folder and its ancestors under `LWIP`, `LWCAM\LWIP` and
/// `apps\LWCAM\LWIP`, covering the deployed layout (Admin at
/// `<install>\LWCamAdmin`, LWIP at `<install>\LWCAM\LWIP`) and a source tree.
String? resolveLwipRoot({String? executablePath}) {
  final candidates = <String>[];
  var dir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  for (var level = 0; level < 8; level++) {
    candidates.add(p.join(dir, 'LWIP'));
    candidates.add(p.join(dir, 'LWCAM', 'LWIP'));
    candidates.add(p.join(dir, 'apps', 'LWCAM', 'LWIP'));
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  for (final root in candidates) {
    // `.setup_ok` is written last by SETUP_DESKEW_CROP.bat and deleted first,
    // so pythonw.exe alone (zip extracted, wheels failed) is not an install.
    if (File(lwipPythonwPath(root)).existsSync() &&
        File(p.join(root, 'runtime', '.setup_ok')).existsSync() &&
        Directory(p.join(root, 'backend', 'deskew_crop_tool')).existsSync()) {
      return root;
    }
  }
  return null;
}

/// `pythonw.exe` of the private runtime SETUP_DESKEW_CROP.bat builds, so no
/// console window flashes at logon.
///
/// This used to be `venv\Scripts\pythonw.exe`. LWIP now uses the same
/// embeddable-Python layout as the QC backend, because the full CPython installer
/// it relied on refuses to run at all when the machine already has a newer 3.13
/// ("Cannot install a product when a newer version is installed") - which left
/// stations with no image-processing runtime and no complaint.
String lwipPythonwPath(String lwipRoot) =>
    p.join(lwipRoot, 'runtime', 'python', 'pythonw.exe');

/// Whether this PC has a usable LWIP install.
///
/// A machine fact, deliberately: Station Setup uses it to decide whether a
/// never-configured station should have processing on, the same way it uses
/// [isQcAppInstalled] for the QC fields. Registering an autostart for an
/// interpreter that is not there would be worse than leaving it off.
bool isLwipInstalled({String? executablePath}) =>
    resolveLwipRoot(executablePath: executablePath) != null;

String lwipLauncherPath() => p.join(lwipRuntimeDir(), 'lwip_autostart.py');

/// The station config LWIP reads its database settings from.
///
/// Deliberately the same file the QC backend is pointed at (its
/// qcNodeConfigPath) rather than a copy: the station's credentials live in one
/// place, written by Station Setup. Computed here rather than imported from the
/// QC service, because these two autostarts are unrelated and neither should
/// depend on the other for a path.
String lwipNodeConfigPath() =>
    p.join(defaultLwcamDbsDir(), NodeConfigService.fileName);

/// Writes the launcher the Run key invokes.
///
/// LWIP is started as `-m deskew_crop_tool`, and its modules use relative
/// imports, so `backend` has to be on sys.path — which its own
/// START_DESKEW_CROP.bat arranges by `cd`-ing there first. A Run key has no
/// working directory, and wrapping the command in `cmd /c cd ... &&` would flash
/// a console at every logon. Five lines of Python avoid both, and leave the
/// vendored LWIP tree untouched.
/// [destination] exists so a test can generate a launcher WITHOUT writing to the
/// live station. It used to always write `lwipLauncherPath()`, so running the
/// suite on a real machine overwrote that machine's autostart launcher with a
/// fixture pointing at a temp directory - which is then deleted, leaving LWIP
/// unable to start at the next logon. Production passes nothing.
Future<File> writeLwipLauncher(String lwipRoot, {String? destination}) async {
  final backend = p.join(lwipRoot, 'backend');
  final file = File(destination ?? lwipLauncherPath());
  await file.parent.create(recursive: true);
  await file.writeAsString('''
# Generated by LWCam Admin (Station Setup). Do not edit - it is rewritten on save.
#
# The __main__ guard is load-bearing, not boilerplate. LWIP's orchestrator runs
# its image work in a ProcessPoolExecutor, and on Windows multiprocessing starts
# each worker by re-executing THIS file (as __mp_main__). Without the guard every
# worker would reach run_module below, see run_name="__main__", and start a
# second orchestrator of its own - recursively.
#
# sys.path is set at module level on purpose: the workers need backend importable
# too, and they never reach the guarded block.
import os
import runpy
import sys

sys.path.insert(0, r"$backend")

# Where the station's database settings live. LWIP reports finished folders
# itself so a batch reaches QC even when LWCAM is closed, and it reads the
# credentials from the same node config the QC backend does - one file, written
# by Station Setup, never copied. setdefault so an operator running the tool by
# hand with the variable already set keeps their own value.
os.environ.setdefault("LWCAM_NODE_CONFIG", r"${lwipNodeConfigPath()}")

if __name__ == "__main__":
    sys.argv = ["deskew_crop_tool", "--config", r"${lwipConfigPath()}"]
    runpy.run_module("deskew_crop_tool", run_name="__main__")
''', flush: true);
  return file;
}

Future<ProcessResult> _reg(List<String> arguments) =>
    Process.run('reg.exe', arguments);

/// Registers LWIP to start at logon. Returns null on success, else the reason.
Future<String?> enableLwipAutostart({String? executablePath}) async {
  final root = resolveLwipRoot(executablePath: executablePath);
  if (root == null) {
    return 'LWIP was not found next to the apps, so it cannot start '
        'automatically. Image processing will not run.';
  }
  await writeLwipLauncher(root);
  final pythonw = lwipPythonwPath(root);
  final command = '"$pythonw" "${lwipLauncherPath()}"';
  final result = await _reg([
    'add',
    _runKey,
    '/v',
    kLwipAutostartValueName,
    '/t',
    'REG_SZ',
    '/d',
    command,
    '/f',
  ]);
  if (result.exitCode != 0) {
    return 'Could not register LWIP to start automatically: '
        '${(result.stderr as String).trim()}';
  }
  print('🖼️ LWIP autostart registered: $command');
  return null;
}

/// Removes the autostart entry. Succeeds when there was nothing to remove.
Future<void> disableLwipAutostart() async {
  final result = await _reg([
    'delete',
    _runKey,
    '/v',
    kLwipAutostartValueName,
    '/f',
  ]);
  // A non-zero exit is "value does not exist", which is the wanted end state.
  if (result.exitCode == 0) print('🖼️ LWIP autostart removed.');
}

/// Whether the autostart entry is currently registered.
Future<bool> isLwipAutostartEnabled() async {
  final result = await _reg(['query', _runKey, '/v', kLwipAutostartValueName]);
  return result.exitCode == 0;
}

/// Asks a running LWIP to finish what it is doing and exit, then waits for it.
///
/// Needed because [startLwipNow] only STARTS one. A live instance holds
/// `work_root\orchestrator.lock`, so a second process takes no lock and exits
/// immediately - which meant a save could never replace a running LWIP, and
/// LWIP reads its config once at import. Saving new settings therefore left the
/// old ones in effect until the next logon. This is the same defect the QC
/// engine had, fixed the same way on 2026-09-04.
///
/// The channel is a file because there is no other one on Windows: LWIP runs as
/// `pythonw.exe`, so it has no console for CTRL_BREAK and no window for
/// WM_CLOSE, and a `/F` kill would skip its drain. LWIP polls for this file,
/// finishes the folder it is already publishing, cancels the rest and exits;
/// cancelled folders are not journalled, so the next run reprocesses them.
///
/// Waiting is done by taking LWIP's OWN lock - the same `RandomAccessFile.lock`
/// pattern as FileLockService - because acquiring it is proof the orchestrator
/// has gone, and needs no process enumeration. Returns true when LWIP is
/// confirmed stopped (or was never running); false on timeout, so the caller
/// can report rather than silently start a process that will exit.
Future<bool> stopLwipNow({
  Duration timeout = const Duration(seconds: 90),
}) async {
  final runtime = p.join(lwipRuntimeDir(), 'runtime');
  final lockFile = File(p.join(runtime, 'work', 'orchestrator.lock'));
  if (!lockFile.existsSync()) return true; // never started on this station

  // Written where BOTH writers can reach it: %ProgramData% is machine-wide, so
  // an elevated installer does not have to resolve the operator's profile.
  // LWIP checks the work-root path too; this one covers the config-less caller.
  final shared = File(
    p.join(
      Platform.environment['ProgramData'] ?? r'C:\ProgramData',
      'LWCAM',
      'lwip.stop',
    ),
  );
  final markers = [File(p.join(runtime, 'work', 'stop.request')), shared];
  for (final marker in markers) {
    try {
      await marker.parent.create(recursive: true);
      await marker.writeAsString('stop', flush: true);
    } catch (e) {
      print('⚠️ Could not write the LWIP stop file ${marker.path}: $e');
    }
  }

  var stopped = false;
  try {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      RandomAccessFile? handle;
      try {
        handle = await lockFile.open(mode: FileMode.append);
        await handle.lock(FileLock.exclusive);
        await handle.unlock();
        print('🖼️ LWIP stopped.');
        stopped = true;
        return true;
      } catch (_) {
        // Still held: LWIP is draining. Keep waiting.
      } finally {
        await handle?.close();
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    print(
      '⚠️ LWIP did not stop within ${timeout.inSeconds}s; the replacement '
      'will wait for it.',
    );
    return false;
  } finally {
    // Cleared only once the lock was taken, i.e. nothing is running to read
    // it. On a timeout the markers STAY: LWIP is still finishing a folder and
    // may not have read them yet, and the replacement started next parks on
    // the lock (it clears any marker older than its own acquisition once it
    // holds it), so a leftover cannot make that one exit at startup either.
    if (stopped) {
      for (final marker in markers) {
        try {
          if (marker.existsSync()) marker.deleteSync();
        } catch (e) {
          print('⚠️ Could not clear the LWIP stop file ${marker.path}: $e');
        }
      }
    }
  }
}

/// Starts LWIP now, so enabling processing does not wait for the next logon.
///
/// Detached on purpose: it must outlive LWCam Admin. If one is already running,
/// this process waits on the orchestrator lock (up to 15 min) and takes over
/// when that one exits, re-reading its config first; if the first one never
/// leaves, the new one gives up by itself. Cheaper and more reliable than
/// trying to detect the first one.
Future<void> startLwipNow({String? executablePath}) async {
  final root = resolveLwipRoot(executablePath: executablePath);
  if (root == null) return;
  try {
    await Process.start(
      lwipPythonwPath(root),
      [lwipLauncherPath()],
      mode: ProcessStartMode.detached,
    );
    print('🖼️ LWIP started.');
  } catch (e) {
    print('⚠️ Could not start LWIP now (it will start at next logon): $e');
  }
}
