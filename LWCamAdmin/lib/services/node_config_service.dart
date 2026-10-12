// ignore_for_file: avoid_print

// File access for lwcam_node_config.json, the per-PC settings file that
// LWCam Admin and the capture app (LWCAM) both read and write. Pure file I/O,
// so it can be created before the UI starts. Change the config through update(),
// which re-reads the file first so one app does not overwrite the other.
import 'dart:convert';
import 'dart:io';

import '../models/node_config.dart';

/// Reads/writes the per-machine `lwcam_node_config.json` (deployment role,
/// site id, sync connection details). A plain singleton (like
/// UsersStoreService/UploadStatsDB), pure I/O and test-friendly via the
/// injected path function — NOT a GetX controller, since it must be
/// constructible and loadable before Get/UI bootstrap.
///
/// The file is shared with LWCAM on a station, so a stale write-back would
/// erase the other app's changes: callers that modify the config go through
/// [update], which re-reads the file from disk immediately before applying
/// the change. Unknown keys ride along in [NodeConfig.extras]. Writes are
/// temp-file + atomic replace (never delete-then-rename, which leaves a
/// window with no file at all), and the last good file is kept as `.bak` so
/// a torn or corrupt file recovers on the next load.
class NodeConfigService {
  static const String fileName = 'lwcam_node_config.json';

  /// Absolute path of the config file.
  final String Function() getConfigPath;

  NodeConfigService({required this.getConfigPath});

  NodeConfig? _cached;

  static NodeConfig? _parse(String content) {
    if (content.trim().isEmpty) return null;
    final decoded = jsonDecode(content);
    if (decoded is! Map) return null;
    return NodeConfig.fromJson(decoded.cast<String, Object?>());
  }

  /// The parsed file at [path], or null when it is missing/empty/corrupt.
  Future<NodeConfig?> _tryRead(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      return _parse(await file.readAsString());
    } catch (e) {
      print('⚠️ Node config read failed ($path): $e');
      return null;
    }
  }

  /// The current config, loading it from disk on first access. A corrupt main
  /// file falls back to `.bak`. A missing file yields (and persists) a fresh
  /// config; a file that exists but cannot be read is NEVER overwritten by a
  /// fresh one here - the in-memory default is used and the bad file is left
  /// for a human. Safe to call repeatedly - later calls return the in-memory
  /// copy.
  Future<NodeConfig> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final path = getConfigPath();
    final config = await _tryRead(path);
    if (config != null) return _cached = config;

    final bak = await _tryRead('$path.bak');
    if (bak != null) {
      print('⚠️ Node config $path unreadable - recovered from $path.bak.');
      return _cached = bak;
    }

    const fresh = NodeConfig();
    _cached = fresh;
    if (!await File(path).exists()) {
      try {
        await save(fresh);
      } catch (_) {} // read-only folder: still usable in memory
    }
    return fresh;
  }

  /// Re-reads the file from disk, bypassing the in-memory cache — the file is
  /// shared with LWCAM, which may have rewritten it since this process first
  /// loaded it.
  Future<NodeConfig> reload() async {
    _cached = null;
    return load();
  }

  /// Read-modify-save: reloads the file from disk, applies [change] to that
  /// fresh copy and saves the result. Use this - not a config held since the
  /// screen opened - for every edit, so nothing stale is written back.
  Future<NodeConfig> update(NodeConfig Function(NodeConfig current) change) async {
    final next = change(await reload());
    await save(next);
    return next;
  }

  /// Persists [config] (temp file, then an atomic replace) and updates the
  /// in-memory cache. The previous good file is copied to `.bak` first.
  Future<void> save(NodeConfig config) async {
    final path = getConfigPath();
    try {
      final file = File(path);
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(config.toJson()), flush: true);
      // Keep only a file that parses as the backup, so a corrupt main file
      // can never overwrite the last good copy.
      if (await _tryRead(path) != null) {
        try {
          await file.copy('${file.path}.bak');
        } catch (_) {} // ponytail: best-effort backup; the save itself must not fail on it
      }
      await tmp.rename(file.path); // replaces the target atomically on Windows
      _cached = config;
    } catch (e) {
      print('⚠️ Node config write failed ($path): $e');
      rethrow;
    }
  }

  /// The in-memory config if [load] has run, else null — for call sites (like
  /// UploadStatsDB.syncEnabled at startup) that must not force an async load.
  NodeConfig? get cached => _cached;
}
