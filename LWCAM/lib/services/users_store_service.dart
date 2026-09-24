// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

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

enum AuthStatus { ok, mustChangePassword, wrongPassword, unknownUser, inactive, noStore }

class AuthOutcome {
  final AuthStatus status;
  final AppUser? user;
  const AuthOutcome(this.status, [this.user]);
}

// ── Pending password changes (offline queue) ────────────────────────────────
//
// changeOwnPassword is PG-first, but a permanently-offline site can never
// wait for a connection — so an unreachable PG queues the change here
// (username → new bcrypt hash, a sibling file next to the snapshot) instead
// of blocking the operator. Top-level (not instance methods) so the static
// writeSnapshotFile variant — the pre-login startup tick, before any
// UsersStoreService instance exists — can reconcile them too.

String _pendingPathFor(String storePath) =>
    p.join(p.dirname(storePath), 'lwcam_pending_password_changes.json');

Future<Map<String, String>> _readPendingAt(String pendingPath) async {
  try {
    final content = await File(pendingPath).readAsString();
    if (content.trim().isEmpty) return {};
    final decoded = jsonDecode(content) as Map;
    return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
  } catch (_) {
    return {};
  }
}

Future<void> _writePendingAtomicAt(String pendingPath, Map<String, String> pending) async {
  final file = File(pendingPath);
  if (pending.isEmpty) {
    if (await file.exists()) await file.delete();
    return;
  }
  final tmp = File('$pendingPath.tmp');
  await tmp.writeAsString(jsonEncode(pending), flush: true);
  if (await file.exists()) await file.delete();
  await tmp.rename(pendingPath);
}

UsersStore _replaceUserIn(UsersStore store, AppUser updated) {
  final key = updated.username.toLowerCase();
  return store.copyWith(
    users: store.users.map((u) => u.username.toLowerCase() == key ? updated : u).toList(),
  );
}

/// SLOW PHASE — must run OUTSIDE the `lwcam_users.json` lock.
///
/// Retries every locally-queued password change against PostgreSQL directly,
/// clearing each on success, and rewrites the queue file with whatever still
/// hasn't landed. A site that never reconnects simply stays queued.
///
/// This is deliberately separate from [_splicePending] because each entry costs
/// up to a 5s connect timeout (and DNS isn't even covered by that), while the
/// shared lock's stale grace is only 30s with no heartbeat. Running ~7 queued
/// entries under the lock pushed the hold past the grace period, at which point
/// LWCam Admin deletes it as stale and both processes write the same file —
/// exactly the interleaving the lock exists to prevent.
///
/// The queue file is LWCAM's own sibling (`lwcam_pending_password_changes.json`),
/// not the shared store, so rewriting it here needs no cross-process lock; the
/// instance mutex already serializes it.
///
/// Returns EVERY hash that was queued — including those just pushed — because
/// all of them still have to be spliced onto the store.
Future<Map<String, String>> _pushPendingToPg(
  String storePath,
  UserDirectoryService directory,
) async {
  final pendingPath = _pendingPathFor(storePath);
  final pending = await _readPendingAt(pendingPath);
  if (pending.isEmpty) return const {};

  final remaining = Map<String, String>.from(pending);
  for (final entry in pending.entries) {
    try {
      await directory.changePassword(
        username: entry.key,
        bcryptHash: entry.value,
      );
      remaining.remove(entry.key); // reached PG — no longer pending
    } catch (_) {
      // Still offline (or another transient failure) — stays queued.
    }
  }
  await _writePendingAtomicAt(pendingPath, remaining);
  return pending;
}

/// FAST PHASE — safe to run inside the lock. Splices whichever hash is now
/// correct (freshly pushed, or still only-local) onto [store], so a pull can
/// never silently revert an offline password change. Pure and synchronous:
/// no I/O, so it adds nothing measurable to the lock hold.
UsersStore _splicePending(UsersStore store, Map<String, String> pending) {
  var next = store;
  for (final entry in pending.entries) {
    final user = next.findUser(entry.key);
    if (user != null) {
      next = _replaceUserIn(
        next,
        user.copyWith(passwordHash: entry.value, mustChangePassword: false),
      );
    }
  }
  return next;
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

  /// Serializes every read-modify-write of the pending-changes file /
  /// `_lastLoaded` / the snapshot file. None of those have their own
  /// locking, and the login-time [flushPendingPasswordChanges] is
  /// deliberately unawaited — without this, a slow offline flush (5s
  /// connect timeout per queued entry) racing a [changeOwnPassword] from
  /// the forced-change dialog could overwrite the just-queued hash with
  /// its stale pre-dialog copy, silently dropping a confirmed change.
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
  /// after every successful sync-tick pull. Reconciles any locally-queued
  /// password change first (see [changeOwnPassword]) so this pull can never
  /// revert one that hasn't reached PG yet.
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
        // PG retries BEFORE the lock — see _pushPendingToPg for why holding it
        // across them let LWCam Admin steal the lock as stale.
        final pending = await _pushPendingToPg(path, directory);
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
          final reconciled = _splicePending(store, pending);
          await _writeJsonAtomic(File(path), reconciled.toJson());
          _lastLoaded = reconciled;
          _lastSource = UsersStoreSource.snapshot;
        } finally {
          await _releaseLock(lock);
        }
      });

  /// Static variant for the pre-login startup tick (main.dart's bootstrap
  /// runs before any `AuthController`/`UsersStoreService` instance exists)
  /// — writes the file so the login screen sees a fresh snapshot on next
  /// read, without needing a live instance to swap into. Applies the same
  /// two guards as [applySnapshot] (dirty-file protection, pending
  /// password reconcile); it cannot share the instance mutex, but it only
  /// ever runs pre-login, when no instance writer exists to race.
  static Future<void> writeSnapshotFile(
    UsersStore store,
    String path, {
    UserDirectoryService? directory,
  }) async {
    // PG retries BEFORE the lock — see _pushPendingToPg.
    final pending = await _pushPendingToPg(
      path,
      directory ?? UserDirectoryService(),
    );
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
      final reconciled = _splicePending(store, pending);
      final tmp = File('$path.tmp');
      await tmp.writeAsString(jsonEncode(reconciled.toJson()), flush: true);
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

  /// Forced first-login/reset password change. PG-first: PostgreSQL IS the
  /// account record, so this tries it there first. When PG is unreachable —
  /// some sites are permanently offline and can never "just reconnect" —
  /// the change is queued locally instead of blocking the operator: applied
  /// to the local snapshot immediately (this session's login works right
  /// now) and retried against PG on every sync tick ([applySnapshot]) and
  /// opportunistically on every subsequent login attempt
  /// ([flushPendingPasswordChanges]). Returns true when the change had to
  /// be queued, so the caller can tell the operator it hasn't reached the
  /// server yet. A genuine write failure — PG reachable but the write
  /// itself rejected, as opposed to unreachable — still propagates
  /// untouched: retrying a query PostgreSQL already refused would never help.
  Future<bool> changeOwnPassword(String username, String newPassword) =>
      _serialized(() async {
        final hash = PasswordHasher.hash(newPassword);
        var queuedOffline = false;
        try {
          await directory.changePassword(username: username, bcryptHash: hash);
          // Direct write landed — an older hash queued from a PRIOR offline
          // attempt must not later replay over this one via _reconcilePending.
          final pendingPath = _pendingPathFor(getStorePath());
          final pending = await _readPendingAt(pendingPath);
          if (pending.remove(username) != null) {
            await _writePendingAtomicAt(pendingPath, pending);
          }
        } catch (e) {
          // ANY failure queues — not just the explicit unreachable
          // StateError. This UPDATE touches nothing constrained, so a
          // failure is connectivity in some costume (incl. a connection
          // that opened but died mid-execute); retrying it from the queue
          // is idempotent even if the write actually committed before the
          // response was lost.
          print('ℹ️ Password change queued locally ($e).');
          final pendingPath = _pendingPathFor(getStorePath());
          final pending = await _readPendingAt(pendingPath);
          pending[username] = hash;
          await _writePendingAtomicAt(pendingPath, pending);
          queuedOffline = true;
        }

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
                // Either the PG write already succeeded, or it's now queued — a
                // failed local mirror write just means this session's in-memory
                // copy (already updated above) is ahead of disk until the next
                // pull overwrites it anyway.
                print('ℹ️ Local snapshot update after password change skipped: $e');
              }
            }
          }
        } finally {
          await _releaseLock(lock);
        }
        return queuedOffline;
      });

  /// Best-effort retry of every locally-queued password change — called
  /// opportunistically at the start of every login attempt, in addition to
  /// every sync tick via [applySnapshot], so a permanently-offline site
  /// still catches up the moment connectivity returns rather than waiting
  /// for the next scheduled tick. Never throws.
  Future<void> flushPendingPasswordChanges() => _serialized(() async {
        if (_lastLoaded == null) return;
        final path = getStorePath();
        // PG retries BEFORE the lock — see _pushPendingToPg. This method is
        // fired unawaited on EVERY login attempt, so on a backlogged offline
        // station it was the most frequent over-long lock hold of the three.
        final Map<String, String> pending;
        try {
          pending = await _pushPendingToPg(path, directory);
        } catch (e) {
          print('⚠️ Pending password flush failed: $e');
          return;
        }
        if (pending.isEmpty) return;

        final lock = File('$path.lock');
        await _acquireLock(lock);
        try {
          // Same re-read-then-write discipline as changeOwnPassword — never
          // reconcile onto a stale in-memory copy.
          final base = await _readStore(File(path), attempts: 1) ?? _lastLoaded;
          if (base == null) return;
          final reconciled = _splicePending(base, pending);
          _lastLoaded = reconciled;
          await _writeJsonAtomic(File(path), reconciled.toJson());
        } catch (e) {
          print('⚠️ Pending password flush failed: $e');
        } finally {
          await _releaseLock(lock);
        }
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
