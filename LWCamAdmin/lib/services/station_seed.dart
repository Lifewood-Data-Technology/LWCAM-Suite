// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The connection Setup wrote down for us, so nobody has to type it.
///
/// Setup installs PostgreSQL, invents a password for it, and writes both into
/// `%ProgramData%\LWCAM\station-seed.json` (older installers wrote
/// `<install>\station-seed.json`, still searched - see
/// [stationSeedCandidates]). Admin reads that file the first time it opens,
/// provisions the station from it, and deletes it. The operator sees a working
/// station instead of five empty boxes and a 32-character password they were
/// asked to retype from a dialog they could not copy from.
///
/// Machine-wide on purpose: setup runs elevated, so it cannot reliably write
/// into the profile of whoever will actually use the station.
class StationSeed {
  final String host;
  final int port;
  final String database;
  final String user;
  final String password;

  const StationSeed({
    required this.host,
    required this.port,
    required this.database,
    required this.user,
    required this.password,
  });

  /// Parses [text], or null when it is not a usable seed.
  ///
  /// Tolerant by design: a half-written or hand-edited seed must not stop Admin
  /// from opening. Every field has to be present and non-empty, or the whole
  /// thing is ignored and the operator fills settings in by hand as before.
  static StationSeed? tryParse(String text) {
    try {
      final data = jsonDecode(text);
      if (data is! Map) return null;
      String s(String key) => (data[key] ?? '').toString().trim();
      final host = s('pgHost');
      final database = s('pgDatabase');
      final user = s('pgUser');
      final password = s('pgPassword');
      final port = int.tryParse(s('pgPort')) ?? 0;
      if (host.isEmpty || database.isEmpty || user.isEmpty || password.isEmpty) {
        return null;
      }
      return StationSeed(
        host: host,
        port: port == 0 ? 5432 : port,
        database: database,
        user: user,
        password: password,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Candidate seed locations, nearest first.
///
/// ProgramData comes first because that is where setup writes it now, and the
/// only place Admin can DELETE it from. The seed holds a superuser password, so
/// consuming it has to mean removing it - and the first clean install proved
/// {app} cannot: Program Files is admin-write, Admin runs unelevated, and the
/// delete failed silently leaving the password readable on the station forever.
/// The installer grants users-modify on the ProgramData folder for exactly this.
///
/// The {app} paths are still searched, so a station installed by an older build
/// is still picked up (it just cannot clear the file afterwards).
///
/// Admin is installed at `<install>\LWCamAdmin\lwcam_admin.exe`, so the seed sits
/// one level up. Ancestors are walked so a portable or source build can sit
/// several folders below the root.
List<String> stationSeedCandidates({
  String? executablePath,
  Map<String, String>? environment,
}) {
  final paths = <String>[];
  final programData =
      (environment ?? Platform.environment)['ProgramData'] ?? r'C:\ProgramData';
  paths.add(p.join(programData, 'LWCAM', 'station-seed.json'));
  var dir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  for (var level = 0; level < 4; level++) {
    paths.add(p.join(dir, 'station-seed.json'));
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  return paths;
}

/// Reads the seed, or null when there is none to read.
StationSeed? readStationSeed({
  String? executablePath,
  Map<String, String>? environment,
}) {
  for (final path in stationSeedCandidates(
      executablePath: executablePath, environment: environment)) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final seed = StationSeed.tryParse(file.readAsStringSync());
    if (seed != null) return seed;
    print('station-seed.json at $path is not usable, ignoring it.');
  }
  return null;
}

/// Deletes the seed once its contents are safely in the config.
///
/// It holds a superuser password in a user-readable folder, so it does not stay
/// a moment longer than needed. Failure is not fatal: the config is already
/// written by this point, and a leftover seed is only re-read if the config is
/// later deleted.
void deleteStationSeed({
  String? executablePath,
  Map<String, String>? environment,
}) {
  for (final path in stationSeedCandidates(
      executablePath: executablePath, environment: environment)) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      file.deleteSync();
      print('station-seed.json consumed and removed.');
    } catch (e) {
      // Worth shouting about: the file still holds a superuser password. This is
      // what silently happened for every station installed by a build that put
      // the seed under Program Files.
      print('WARNING: could not remove $path - it still contains the '
          'PostgreSQL password. Delete it by hand. ($e)');
    }
  }
}
