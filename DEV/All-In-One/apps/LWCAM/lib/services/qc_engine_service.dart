// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'win32_job.dart';

/// Supervises the QC engine (FastAPI/uvicorn) as a LOCAL SIDECAR.
///
/// The QC platform keeps its Python engine — the export contract
/// (`adobe_deflate` TIFF, CSV hashes, verified ZIP entry order), the AI review
/// pipeline, draft manifests and separation transactions all live there, and
/// Pillow is C where a pure-Dart image library would be seconds per full-res
/// scan. What goes away is the *server-ness*: no browser, no console window, no
/// port on the LAN. It binds 127.0.0.1 only and dies with this app.
///
/// Same supervisor pattern as ScrcpyService: resolve the bundled runtime, spawn,
/// bind to a kill-on-close job so it can never outlive LWCAM (crash included),
/// restart on exit with backoff, and give up after repeated instant failures
/// rather than crash-looping python forever.
///
/// Adopts an engine that is already listening instead of spawning a second one.
/// During the transition the standalone `START_QC_BACKEND.bat` may still be
/// running; two uvicorns on one port is just a bind error, and the one already
/// serving is as good as ours.
class QcEngineService {
  QcEngineService._();
  static final QcEngineService instance = QcEngineService._();

  /// Loopback only. The whole point of the sidecar is that nothing is exposed.
  static const String host = '127.0.0.1';
  static const int port = 8080;

  static Uri get baseUri =>
      debugBaseUriOverride ?? Uri.parse('http://$host:$port');

  /// Test seam: points the client at a local fake engine. Never set in the
  /// app; the engine is always the fixed local port above.
  static Uri? debugBaseUriOverride;

  Process? _process;
  int _jobHandle = 0;
  bool _starting = false;
  bool _stopRequested = false;
  String? _root;
  String? _python;
  DateTime? _startedAt;
  int _earlyExitStreak = 0;
  Timer? _restartTimer;

  bool get isRunning => _process != null;

  /// Prints AND appends to %USERPROFILE%\LWCAM_DBs\qc_engine.log — a release exe
  /// has no console, so a field failure would otherwise be invisible. Same
  /// rationale as ScrcpyService._log. Best-effort; never throws.
  void _log(String line) {
    final stamped = '[${DateTime.now().toIso8601String()}] $line';
    print(stamped);
    try {
      final profile = Platform.environment['USERPROFILE'];
      if (profile == null) return;
      File(
        p.join(profile, 'LWCAM_DBs', 'qc_engine.log'),
      ).writeAsStringSync('$stamped\r\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Locates the QC install. Deployed puts it at `<install>\QC` beside
  /// `<install>\LWCAM`; a source tree has `LWCam_QC_Platform`, possibly under
  /// `apps\`. `backend\app\main.py` is the marker either way.
  static String? resolveQcRoot({String? executablePath}) {
    final candidates = <String>[];
    var dir = p.dirname(executablePath ?? Platform.resolvedExecutable);
    for (var level = 0; level < 8; level++) {
      candidates.add(p.join(dir, 'QC'));
      candidates.add(p.join(dir, 'LWCam_QC_Platform'));
      candidates.add(p.join(dir, 'apps', 'LWCam_QC_Platform'));
      final parent = p.dirname(dir);
      if (parent == dir) break;
      dir = parent;
    }
    for (final root in candidates) {
      if (File(p.join(root, 'backend', 'app', 'main.py')).existsSync()) {
        return root;
      }
    }
    return null;
  }

  /// The interpreter to run the engine with: the installer's embedded runtime
  /// first, then a developer venv.
  static String? resolvePython(String qcRoot) {
    final candidates = [
      p.join(qcRoot, 'runtime', 'python', 'python.exe'),
      p.join(qcRoot, 'backend', '.venv', 'Scripts', 'python.exe'),
    ];
    for (final python in candidates) {
      if (File(python).existsSync()) return python;
    }
    return null;
  }

  /// Whether something already serves the API on our port.
  ///
  /// `/docs` needs no token, so this answers "is an engine there" without
  /// authenticating. A short timeout: this runs on the startup path.
  Future<bool> isEngineResponding({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .getUrl(baseUri.resolve('/docs'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      await response.drain<void>();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Starts the engine (idempotent). Never throws — a QC seat that cannot start
  /// its engine must still let the operator use the rest of the app.
  Future<void> ensureStarted({
    String? nodeConfigPath,
    String? executablePath,
  }) async {
    if (_process != null || _starting) return;
    _starting = true;
    _stopRequested = false;
    try {
      if (await isEngineResponding()) {
        _log('🧪 QC engine already listening on $host:$port — adopting it.');
        return;
      }
      final root = resolveQcRoot(executablePath: executablePath);
      if (root == null) {
        _log(
          '⚠️ QC engine not found (need <root>\\backend\\app\\main.py) — '
          'QC features disabled.',
        );
        return;
      }
      final python = resolvePython(root);
      if (python == null) {
        _log(
          '⚠️ QC python runtime not found under $root — run SETUP_QC.bat '
          '(or create backend\\.venv). QC features disabled.',
        );
        return;
      }
      _root = root;
      _python = python;
      _nodeConfigPath = nodeConfigPath;
      _earlyExitStreak = 0;
      await _spawn();
    } catch (e) {
      _log('⚠️ QC engine start failed: $e');
    } finally {
      _starting = false;
    }
  }

  /// Remembered from ensureStarted so a supervisor restart launches the engine
  /// with the same station config, not the .env fallback.
  String? _nodeConfigPath;

  Future<void> _spawn() async {
    final root = _root, python = _python, nodeConfigPath = _nodeConfigPath;
    if (root == null || python == null) return;
    final backend = p.join(root, 'backend');
    // The engine reads the station config the same way the standalone launcher
    // does; without it it would fall back to .env and quietly use different
    // folders than the rest of the suite.
    final environment = <String, String>{
      if (nodeConfigPath != null) 'LWCAM_NODE_CONFIG': nodeConfigPath,
    };
    _log(
      '🧪 Starting QC engine: $python -m uvicorn app.main:app '
      '--host $host --port $port',
    );
    final proc = await Process.start(
      python,
      ['-m', 'uvicorn', 'app.main:app', '--host', host, '--port', '$port'],
      workingDirectory: backend,
      environment: environment,
    );
    _process = proc;
    _startedAt = DateTime.now();
    proc.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isNotEmpty) _log('🧪 $line');
        });
    proc.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
          // uvicorn logs to stderr by default, so this is the normal channel.
          if (line.trim().isNotEmpty) _log('🧪 $line');
        });
    _jobHandle = assignToKillOnCloseJob(proc.pid);
    proc.exitCode.then(_onExit);
  }

  void _onExit(int code) {
    _log('🧪 QC engine exited ($code).');
    final ranFor = _startedAt == null
        ? Duration.zero
        : DateTime.now().difference(_startedAt!);
    final fast = ranFor < const Duration(seconds: 10);
    _process = null;
    closeJobHandle(_jobHandle);
    _jobHandle = 0;
    if (_stopRequested) return;

    if (fast) {
      _earlyExitStreak++;
      if (_earlyExitStreak >= 4) {
        _log(
          '⚠️ QC engine exited within seconds $_earlyExitStreak times in a '
          'row — not restarting. Usually the database is unreachable or the '
          'station config is wrong. Check qc_engine.log, fix Station Setup, '
          'and reopen the app.',
        );
        return;
      }
    } else {
      _earlyExitStreak = 0; // it ran stably before dying
    }
    final delay = _backoffFor(_earlyExitStreak);
    _log('🧪 Restarting QC engine in ${delay.inSeconds}s…');
    _restartTimer?.cancel();
    _restartTimer = Timer(delay, () async {
      if (_stopRequested || _process != null || _root == null) return;
      // Station Setup's save stops this engine and starts its own detached
      // one; respawning here would only lose the race for the port.
      if (await isEngineResponding()) {
        _log('🧪 Another QC engine is listening on $host:$port — adopting it.');
        return;
      }
      if (!_stopRequested && _process == null) await _spawn();
    });
  }

  Duration _backoffFor(int streak) {
    switch (streak) {
      case 0:
        return const Duration(seconds: 5);
      case 1:
        return const Duration(seconds: 10);
      case 2:
        return const Duration(seconds: 30);
      default:
        return const Duration(seconds: 60);
    }
  }

  /// Stops the engine. The job object already guarantees it dies with this app;
  /// this is the orderly path so the window-close handler leaves nothing behind.
  Future<void> stop() async {
    _stopRequested = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    final proc = _process;
    _process = null;
    if (proc != null) {
      _log('🧪 Stopping QC engine.');
      proc.kill();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    }
    closeJobHandle(_jobHandle);
    _jobHandle = 0;
  }
}
