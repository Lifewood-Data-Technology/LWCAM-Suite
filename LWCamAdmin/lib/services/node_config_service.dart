// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import '../models/node_config.dart';

/// Reads/writes the per-machine `lwcam_node_config.json` (deployment role,
/// site id, sync connection details). A plain singleton (like
/// UsersStoreService/UploadStatsDB), pure I/O and test-friendly via the
/// injected path function — NOT a GetX controller, since it must be
/// constructible and loadable before Get/UI bootstrap.
///
/// Deliberately simpler than UsersStoreService: this file has exactly ONE
/// writer (an admin editing Settings on THIS machine, or IT provisioning it
/// directly) — there is no concurrent-editor race to guard against, so no
/// lock file is needed. Still uses tmp+rename so a crash mid-write can
/// never leave a torn/partial file.
class NodeConfigService {
  static const String fileName = 'lwcam_node_config.json';

  /// Absolute path of the config file.
  final String Function() getConfigPath;

  NodeConfigService({required this.getConfigPath});

  NodeConfig? _cached;

  /// The current config, loading it from disk on first access (generating
  /// and persisting a fresh one if the file is missing/corrupt). Safe to
  /// call repeatedly — subsequent calls return the in-memory copy.
  Future<NodeConfig> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final path = getConfigPath();
    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          final config = NodeConfig.fromJson(decoded);
          _cached = config;
          return config;
        }
      }
    } catch (e) {
      print('⚠️ Node config read failed ($path): $e — using a fresh config.');
    }

    const fresh = NodeConfig();
    _cached = fresh;
    await save(fresh);
    return fresh;
  }

  /// Re-reads the file from disk, bypassing the in-memory cache — for the
  /// cross-app case: LWCAM and LWCam Admin share this file on a standard
  /// station, so the OTHER app may have rewritten it since this process
  /// first loaded it, and a settings screen about to edit-and-save must
  /// start from the current disk state or it writes the stale copy back.
  Future<NodeConfig> reload() async {
    _cached = null;
    return load();
  }

  /// Persists [config] (tmp-file + rename so a crash mid-write can't leave a
  /// torn file) and updates the in-memory cache.
  Future<void> save(NodeConfig config) async {
    final path = getConfigPath();
    try {
      final file = File(path);
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(config.toJson()), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
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
