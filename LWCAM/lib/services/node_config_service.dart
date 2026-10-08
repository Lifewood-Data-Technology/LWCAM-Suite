// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import '../models/node_config.dart';
import 'dpapi.dart';

/// Reads/writes the per-machine `lwcam_node_config.json` (deployment role,
/// site id, sync connection details). A plain singleton (like
/// UsersStoreService/UploadStatsDB), pure I/O and test-friendly via the
/// injected path function — NOT a GetX controller, since it must be
/// constructible and loadable before Get/UI bootstrap.
///
/// Deliberately simpler than UsersStoreService: no lock file. The file is
/// shared with LWCam Admin, so every edit goes through [update] (reload, then
/// save) and writes tmp+replace so a crash mid-write can never leave a
/// torn/partial file.
class NodeConfigService {
  static const String fileName = 'lwcam_node_config.json';

  /// Absolute path of the config file.
  final String Function() getConfigPath;

  /// Decrypts the capture login's  (DPAPI, entropy
  /// "LWCam"). Injectable so tests need no Windows user profile.
  final String Function(String) unprotect;

  NodeConfigService({
    required this.getConfigPath,
    String Function(String)? unprotect,
  }) : unprotect = unprotect ?? ((b) => dpapiUnprotect(b, entropy: captureDpapiEntropy));

  NodeConfig? _cached;

  /// The current config, loading it from disk on first access (generating
  /// and persisting a fresh one if the file is missing/corrupt). Safe to
  /// call repeatedly — subsequent calls return the in-memory copy.
  Future<NodeConfig> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final path = getConfigPath();
    var unreadable = false;
    try {
      final file = File(path);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.trim().isNotEmpty) {
          final decoded = jsonDecode(content) as Map<String, dynamic>;
          var config = NodeConfig.fromJson(decoded);
          // Password at rest: pgPasswordProtected (DPAPI) wins, old files
          // keep the plain pgPassword. The blob stays in extras so a save
          // never drops it.
          final blob = decoded['pgPasswordProtected']?.toString() ?? '';
          if (blob.isNotEmpty) {
            try {
              config = config.copyWith(pgPassword: unprotect(blob));
            } catch (e) {
              print('⚠️ Node config: pgPasswordProtected not readable by '
                  'this Windows user ($e).');
            }
          }
          _cached = config;
          return config;
        }
      }
    } catch (e) {
      // A file that exists but cannot be parsed is LWCam Admin's to fix -
      // never overwrite it with defaults from here.
      unreadable = true;
      print('⚠️ Node config read failed ($path): $e — using a fresh config.');
    }

    const fresh = NodeConfig();
    _cached = fresh;
    if (!unreadable) await save(fresh);
    return fresh;
  }

  /// Read-modify-save against the CURRENT disk state: reloads first so the
  /// change is applied to whatever LWCam Admin last wrote, never to a stale
  /// cached copy. Every caller that edits and saves must go through here.
  Future<NodeConfig> update(
      NodeConfig Function(NodeConfig current) change) async {
    final next = change(await reload());
    await save(next);
    return next;
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

  /// Persists [config] (tmp-file + replace so a crash mid-write can't leave a
  /// torn file) and updates the in-memory cache. Prefer [update], which starts
  /// from the disk state.
  Future<void> save(NodeConfig config) async {
    final path = getConfigPath();
    try {
      final file = File(path);
      if (!await file.parent.exists()) await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      final json = config.toJson();
      // The plain password never goes back to disk once a protected blob
      // exists (LWCAM never edits the password; LWCam Admin owns it).
      if ((json['pgPasswordProtected']?.toString() ?? '').isNotEmpty) {
        json['pgPassword'] = null;
      }
      await tmp.writeAsString(jsonEncode(json), flush: true);
      // Replace in place (Dart's rename is MoveFileEx with REPLACE_EXISTING on
      // Windows): there is never a moment with no config file.
      await tmp.rename(file.path);
      _cached = config;
    } catch (e) {
      print('⚠️ Node config write failed ($path): $e');
      rethrow;
    }
  }

  /// The in-memory config if [load] has run, else null — for call sites that
  /// must not force an async load.
  NodeConfig? get cached => _cached;
}
