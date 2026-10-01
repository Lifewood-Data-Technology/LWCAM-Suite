// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart' show ServerException;

import '../models/app_user.dart';
import '../models/project.dart';
import 'password_hasher.dart';
import 'user_directory_service.dart';

/// Where the local [UsersStore] snapshot stood at last load.
enum UsersStoreSource {
  /// A snapshot file exists locally — pulled from PostgreSQL by the sync
  /// tick (or LWCam Admin's Station Setup seed on a fresh PC). Read-only:
  /// LWCAM never writes users/projects/settings, only pulls them.
  snapshot,

  /// No snapshot file yet — a fresh PC before its first successful pull.
  /// Login shows "run LWCam Admin station setup".
  none,
}

class UsersStoreLoadResult {
  final UsersStore? store;
  final UsersStoreSource source;
  const UsersStoreLoadResult(this.store, this.source);
}

/// [needsDbUpdate]: the database answered but lacks the function or the right
/// to call it (LWCamDatabaseSetup has not been re-run) - not the user's fault.
enum PasswordChangeResult { changed, wrongCurrent, offline, needsDbUpdate }

enum AuthStatus { ok, mustChangePassword, wrongPassword, unknownUser, inactive, noStore }

class AuthOutcome {
  final AuthStatus status;
  final AppUser? user;
  const AuthOutcome(this.status, [this.user]);
}

// ── Retired offline password queue ──────────────────────────────────────────
//
// Password changes used to be queued here (username → new bcrypt hash) when
// PostgreSQL was unreachable. The database function needs the OLD plaintext
// password, which must never be stored, so a change is done online or not at
// all. A queue file left by an older version is read once, logged, and
// deleted — its entries are dropped, never applied.

String _pendingPathFor(String storePath) =>
    p.join(p.dirname(storePath), 'lwcam_pending_password_changes.json');

Future<void> _dropLegacyPendingQueue(String storePath) async {
  final file = File(_pendingPathFor(storePath));
  try {
    if (!await file.exists()) return;
    var names = <String>[];
    try {
      names = (jsonDecode(await file.readAsString()) as Map).keys.map((k) => '$k').toList();
    } catch (_) {}
    print('ℹ️ Dropping retired pending password queue (${names.length} entries: '
        '${names.join(', ')}) — password changes now require the database.');
    await file.delete();
  } catch (e) {
    print('ℹ️ Could not remove the retired pending password queue: $e');
  }
}

/// Reads the local read-only snapshot of users/projects/app-settings
/// (`lwcam_users.json`, written by the sync pull — see sync_service.dart —
/// or by LWCam Admin's Station Setup on a fresh PC). PostgreSQL is the
/// source of truth; this file is only ever LWCAM's local cache of it.
///
/// LWCAM writes back through exactly three PG-direct calls
/// ([changeOwnPassword]/[recordLogin]/[markProjectHasData], all via
/// [UserDirectoryService]) — never the local file, which the next pull
/// simply overwrites wholesale.
///
/// A plain singleton, not a GetX controller — it is pure I/O and
/// test-friendly via the injected path/directory functions.
class UsersStoreService {
  static const String usersFileName = 'lwcam_users.json';
  static const Duration _lockStaleGrace = Duration(seconds: 30);

  /// Cross-process file lock on the shared snapshot — same protocol as
  /// LWCam Admin's `_acquireLock` (`admin_store_service.dart`), so the two
  /// apps' writes to the same `lwcam_users.json` never interleave. Without
  /// this, a stale in-memory `_lastLoaded` written back here could resurrect
  /// edits (including deletions) LWCam Admin had just made on disk.
  static Future<void> _acquireLock(File lock) async {
    for (var attempt = 0; attempt < 50; attempt++) {
      if (await lock.exists()) {
        try {
          final age = DateTime.now().difference((await lock.stat()).modified);
          if (age > _lockStaleGrace) await lock.delete();
        } catch (_) {}
      }
      try {
        await lock.create(exclusive: true);
        await lock.writeAsString('$pid@${DateTime.now().toIso8601String()}', flush: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw StateError('Could not acquire the users-store lock (LWCam Admin may be editing).');
  }

  static Future<void> _releaseLock(File lock) async {
    try {
      if (await lock.exists()) await lock.delete();
    } catch (_) {}
  }

  /// Full path of the local snapshot file (resolved by the caller — see
  /// AuthController._initUsersStore for the node-config-driven default).
  final String Function() getStorePath;

  /// PG write whitelist seam — injectable for tests; production default is
  /// a real [UserDirectoryService].
  final UserDirectoryService directory;

  UsersStoreService({required this.getStorePath, UserDirectoryService? directory})
      : directory = directory ?? UserDirectoryService();

  UsersStore? _lastLoaded;
  UsersStoreSource _lastSource = UsersStoreSource.none;

  /// Serializes every read-modify-write of `_lastLoaded` / the snapshot
  /// file, which have no locking of their own.
  Future<void> _serial = Future.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final run = _serial.then((_) => action());
    _serial = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  UsersStore? get lastLoaded => _lastLoaded;
  UsersStoreSource get lastSource => _lastSource;

  /// Keying flag from the last successful load (false when no store) — the
  /// transfer gate reads this (plus a best-effort [refresh]).
  bool get metadataKeyingEnabled => _lastLoaded?.settings.metadataKeyingEnabled ?? false;

  // Remote-shutter config from the last successful load (defaults when no
  // store) — the capture page reads these when arming the hotkey.
  String get shutterKeybind => _lastLoaded?.settings.shutterKeybind ?? 'Space';
  String get shutterMethod => _lastLoaded?.settings.shutterMethod ?? 'tap';
  double get shutterTapXPercent => _lastLoaded?.settings.shutterTapXPercent ?? 50;
  double get shutterTapYPercent => _lastLoaded?.settings.shutterTapYPercent ?? 90;

  /// Projects from the last successful load — works offline for read
  /// purposes since it's fed from whichever snapshot was loaded.
  List<Project> get projects => _lastLoaded?.projects ?? const [];

  // ── Loading ────────────────────────────────────────────────────────────

  Future<UsersStoreLoadResult> load() async {
    final path = getStorePath();
    final file = File(path);
    // Bounded by a timeout: File.exists()/readAsString() on an unreachable
    // SMB share (the rare shared-snapshot override) can pin a dart:io
    // worker thread for 20-30s; several of those exhaust the small IO pool
    // and slow ALL file I/O app-wide.
    try {
      final store = await _readStore(file).timeout(const Duration(seconds: 8));
      if (store != null) {
        _lastLoaded = store;
        _lastSource = UsersStoreSource.snapshot;
        return UsersStoreLoadResult(store, UsersStoreSource.snapshot);
      }
    } on TimeoutException {
      print('⚠️ Users snapshot access timed out ($path).');
    } catch (e) {
      print('⚠️ Users snapshot read failed ($path): $e');
    }
    _lastLoaded = null;
    _lastSource = UsersStoreSource.none;
    return const UsersStoreLoadResult(null, UsersStoreSource.none);
  }

  /// Best-effort reload (used before the transfer gate). Never throws.
  Future<void> refresh() async {
    try {
      await load();
    } catch (_) {}
  }

  /// Overwrites the local snapshot with a freshly pulled [store] and swaps
  /// it in as the live copy — called by SyncBootstrap's `applyPulledStore`
  /// after every successful sync-tick pull.
  ///
  /// EXCEPT when LWCam Admin has unpushed offline edits queued in the
  /// on-disk file (`dirty: true` — both apps share this file on a standard
  /// station): the pull predates those edits, so overwriting would silently
  /// destroy them (queued user edits, delete tombstones). In that case the
  /// file is left alone and ITS content becomes the live copy — the
  /// admin's offline edits are the newest intent, and they reach PG the
  /// next time LWCam Admin reconciles.
  Future<void> applySnapshot(UsersStore store) => _serialized(() async {
        final path = getStorePath();
        await _dropLegacyPendingQueue(path);
        final lock = File('$path.lock');
        await _acquireLock(lock);
        try {
          final existing = await _readStore(File(path), attempts: 1);
          if (existing != null && existing.hasPendingAdminEdits) {
            print('ℹ️ Snapshot pull skipped: LWCam Admin has unpushed offline '
                'edits queued in $path.');
            _lastLoaded = existing;
            _lastSource = UsersStoreSource.snapshot;
            return;
          }
          if (store.users.isEmpty && (existing?.users.isNotEmpty ?? false)) {
            print('⚠️ Pulled users store is empty — cloud users table empty? '
                'Keeping existing snapshot at $path.');
            _lastLoaded = existing;
            _lastSource = UsersStoreSource.snapshot;
            return;
          }
          await _writeJsonAtomic(File(path), store.toJson());
          _lastLoaded = store;
          _lastSource = UsersStoreSource.snapshot;
        } finally {
          await _releaseLock(lock);
        }
      });

  /// Static variant for the pre-login startup tick (main.dart's bootstrap
  /// runs before any `AuthController`/`UsersStoreService` instance exists)
  /// — writes the file so the login screen sees a fresh snapshot on next
  /// read, without needing a live instance to swap into. Applies the same
  /// guards as [applySnapshot] (dirty-file protection, empty-pull
  /// protection); it cannot share the instance mutex, but it only
  /// ever runs pre-login, when no instance writer exists to race.
  static Future<void> writeSnapshotFile(UsersStore store, String path) async {
    await _dropLegacyPendingQueue(path);
    final lock = File('$path.lock');
    await _acquireLock(lock);
    try {
      final existing = await _readStore(File(path), attempts: 1);
      if (existing != null && existing.hasPendingAdminEdits) {
        print('ℹ️ Snapshot pull skipped: LWCam Admin has unpushed offline '
            'edits queued in $path.');
        return;
      }
      if (store.users.isEmpty && (existing?.users.isNotEmpty ?? false)) {
        print('⚠️ Pulled users store is empty — cloud users table empty? '
            'Keeping existing snapshot at $path.');
        return;
      }
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode(store.toJson()), flush: true);
      final target = File(path);
      if (await target.exists()) await target.delete();
      await tmp.rename(path);
    } finally {
      await _releaseLock(lock);
    }
  }

  // ── Authentication ──────────────────────────────────────────────────────

  Future<AuthOutcome> authenticate(String username, String password) async {
    final store = _lastLoaded;
    if (store == null) return const AuthOutcome(AuthStatus.noStore);
    final user = store.findUser(username);
    if (user == null) return const AuthOutcome(AuthStatus.unknownUser);
    if (!user.active) return AuthOutcome(AuthStatus.inactive, user);
    if (!PasswordHasher.verify(password, user.passwordHash)) {
      return AuthOutcome(AuthStatus.wrongPassword, user);
    }
    return AuthOutcome(
      user.mustChangePassword ? AuthStatus.mustChangePassword : AuthStatus.ok,
      user,
    );
  }

  /// Forced first-login/reset password change, done in PostgreSQL via
  /// `lwcam_change_own_password` (it checks [oldPassword] itself). Nothing is
  /// queued and no plaintext is stored: unreachable database ->
  /// [PasswordChangeResult.offline], database refused (old password not
  /// accepted / user inactive) -> [PasswordChangeResult.wrongCurrent]; in both
  /// cases the local snapshot is left untouched. Any other failure propagates.
  Future<PasswordChangeResult> changeOwnPassword(
    String username,
    String oldPassword,
    String newPassword,
  ) =>
      _serialized(() async {
        final hash = PasswordHasher.hash(newPassword);
        final bool accepted;
        try {
          accepted = await directory.changePassword(
            username: username,
            oldPassword: oldPassword,
            bcryptHash: hash,
          );
        } on StateError {
          return PasswordChangeResult.offline;
        } on ServerException catch (e) {
          // 42501 insufficient_privilege, 42883 undefined_function
          if (e.code == '42501' || e.code == '42883') {
            return PasswordChangeResult.needsDbUpdate;
          }
          rethrow;
        }
        if (!accepted) return PasswordChangeResult.wrongCurrent;

        final path = getStorePath();
        final lock = File('$path.lock');
        await _acquireLock(lock);
        try {
          // Splice onto a freshly re-read disk copy, not the stale
          // in-memory `_lastLoaded` — otherwise this write can resurrect
          // edits (including deletions) LWCam Admin made since the last
          // load. Falls back to `_lastLoaded` only when no file exists yet.
          final base = await _readStore(File(path), attempts: 1) ?? _lastLoaded;
          if (base != null) {
            final user = base.findUser(username);
            if (user != null) {
              final updated = user.copyWith(passwordHash: hash, mustChangePassword: false);
              final next = _replaceUser(base, updated);
              _lastLoaded = next;
              try {
                await _writeJsonAtomic(File(path), next.toJson());
              } catch (e) {
                // PG already has the change; a failed local mirror write just
                // means this session's in-memory copy is ahead of disk until
                // the next pull overwrites it anyway.
                print('ℹ️ Local snapshot update after password change skipped: $e');
              }
            }
          }
        } finally {
          await _releaseLock(lock);
        }
        return PasswordChangeResult.changed;
      });

  /// Best-effort last-login stamp — never blocks login on failure. No local
  /// write: this is cosmetic and the next pull picks it up.
  Future<void> recordLogin(String username) => directory.recordLogin(username);

  // ── Projects (read-only here) ────────────────────────────────────────────

  /// Best-effort advisory stamp: a box was created under this project.
  /// Never blocks/throws — box creation is per-PC local and must not be
  /// gated on PG reachability. No local write: cosmetic, next pull picks it
  /// up.
  Future<void> markProjectHasData({required String projectKey}) =>
      directory.markProjectHasData(projectKey);

  // ── Internal ───────────────────────────────────────────────────────────

  UsersStore _replaceUser(UsersStore store, AppUser updated) {
    final key = updated.username.toLowerCase();
    return store.copyWith(
      users: store.users.map((u) => u.username.toLowerCase() == key ? updated : u).toList(),
    );
  }

  Future<void> _writeJsonAtomic(File target, Map<String, dynamic> json) async {
    if (!await target.parent.exists()) await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
  }

  static Future<UsersStore?> _readStore(File file, {int attempts = 5}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final content = await file.readAsString();
        if (content.trim().isEmpty) throw const FormatException('empty');
        return UsersStore.fromJson(jsonDecode(content) as Map<String, dynamic>);
      } catch (_) {
        if (i < attempts - 1) await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return null;
  }
}
