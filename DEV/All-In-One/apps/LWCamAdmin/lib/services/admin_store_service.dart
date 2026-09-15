// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../auth/super_admin.dart';
import '../models/app_user.dart';
import '../models/metadata_template.dart';
import '../models/project.dart';
import 'admin_pg_gateway.dart';
import 'password_hasher.dart';

/// PostgreSQL-first store with an offline local-JSON fallback: this is the
/// ONE place LWCam Admin reads/writes users, projects, and app settings.
///
/// Online: every mutation reconciles first (push any pending offline edits,
/// then pull PG's current state) so a stale local copy can never clobber
/// newer rows, applies the change, pushes it, and pulls back the canonical
/// result. Offline: the mutation still applies to the local JSON snapshot
/// (tmp+rename atomic, `.lock` create-exclusive against a second admin
/// editing concurrently — the same machinery LWCAM's old NAS store used),
/// marked `dirty` with a tombstone recorded for any delete, and queued for
/// the next successful [trySync].
class AdminStoreService extends GetxController {
  static const String fileName = 'lwcam_users.json';
  static const Duration _lockStaleGrace = Duration(seconds: 30);

  final AdminGateway gateway;

  /// Directory holding `lwcam_users.json` — NodeConfig.usersStorePath or the
  /// default `%USERPROFILE%\LWCAM_DBs`.
  final String Function() getStoreDirPath;

  /// NodeConfig.pgConnectionEnabled, captured at construction — AdminBootstrap
  /// always rebuilds this service fresh on every Station Setup save, so a
  /// live-reloading getter isn't needed. When false, [trySync] never even
  /// probes PostgreSQL: every mutation goes straight to the offline branch.
  final bool pgConnectionEnabled;

  AdminStoreService({
    required this.gateway,
    required this.getStoreDirPath,
    this.pgConnectionEnabled = true,
  });

  final store = Rxn<UsersStore>();
  final online = false.obs;
  final dirty = false.obs;
  final schemaOutdated = false.obs;
  final lastPushAt = Rxn<DateTime>();
  final lastPullAt = Rxn<DateTime>();
  final lastError = RxnString();

  String get _path => p.join(getStoreDirPath(), fileName);

  /// Reads the local snapshot (creating an empty one if absent — this app
  /// has no first-run ceremony beyond "an empty store exists"), then
  /// attempts an immediate reconcile. Call once at startup — main.dart
  /// deliberately does NOT await it (an unreachable configured host costs
  /// a ~5s connect timeout, which used to hold the window back).
  Future<void> init() async {
    final file = File(_path);
    if (await file.exists()) {
      final loaded = await _readStore(file);
      store.value = loaded ?? const UsersStore();
    } else {
      await _createJsonExclusive(file, const UsersStore().toJson());
      store.value = const UsersStore();
    }
    dirty.value = store.value?.dirty ?? false;
    await trySync();
  }

  /// The one reconcile primitive: probe → (if dirty) push → pull → write
  /// clean. Returns true when the pull landed (i.e. the in-memory store now
  /// reflects PostgreSQL). Called by [init], a periodic timer
  /// (SyncStatusController), and at the start of every mutation.
  Future<bool> trySync() async {
    if (!pgConnectionEnabled) {
      // Administratively off — never even attempt the network, unlike a
      // real "unreachable" probe result (which still tries every tick).
      online.value = false;
      schemaOutdated.value = false;
      return false;
    }
    final probe = await gateway.probe();
    if (probe.status == GatewayStatus.schemaOutdated) {
      schemaOutdated.value = true;
      online.value = false;
      lastError.value = 'PostgreSQL schema is out of date — apply the '
          'updated LWCam_database SQL file. Edits are queued locally.';
      return false;
    }
    schemaOutdated.value = false;
    if (probe.status == GatewayStatus.unreachable) {
      online.value = false;
      return false;
    }
    online.value = true;

    final current = store.value;
    if (current != null && current.dirty) {
      try {
        await gateway.pushSnapshot(current);
        lastPushAt.value = DateTime.now();
      } catch (e) {
        // Don't pull on top of an undelivered push — that would silently
        // discard the pending edits by treating stale PG data as canonical.
        print('⚠️ Push failed, staying dirty: $e');
        lastError.value = '$e';
        online.value = false;
        return false;
      }
    }

    try {
      final pulled = await gateway.pullStore();
      // Same .lock as _mutate: in the documented shared-snapshot-folder
      // setup a second admin's locked mutation must not be clobbered by
      // this pull-write landing mid-edit. Free when uncontended.
      final lock = File('$_path.lock');
      await _acquireLock(lock);
      try {
        await _writeJsonAtomic(File(_path), pulled.toJson());
      } finally {
        await _releaseLock(lock);
      }
      store.value = pulled;
      dirty.value = false;
      lastPullAt.value = DateTime.now();
      lastError.value = null;
      return true;
    } catch (e) {
      print('⚠️ Pull failed: $e');
      lastError.value = '$e';
      online.value = false;
      return false;
    }
  }

  // ── Domain mutations ──────────────────────────────────────────────────────

  Future<void> createUser({
    required String username,
    required Set<UserRole> roles,
    String? deviceId,
    Map<UserRole, Set<String>> roleProjectKeys = const {},
    required String by,
  }) {
    if (isSuperAdminName(username)) {
      throw StateError('"$kSuperAdminUsername" is reserved and cannot be used as a username.');
    }
    return _mutate((current) {
      if (current.findUser(username) != null) {
        throw StateError('A user named "$username" already exists.');
      }
      final tempHash = current.settings.defaultTempPasswordHash;
      if (tempHash == null) throw StateError('Set a default temporary password first.');
      final resolvedDeviceId = _validateDeviceIdForRoles(roles, deviceId);
      _validateDeviceIdUnique(current, resolvedDeviceId, excludeUsername: null);
      final resolvedProjects = _resolveRoleProjectKeys(current, roles, roleProjectKeys);
      final now = DateTime.now();
      final user = AppUser(
        username: username.trim(),
        passwordHash: tempHash,
        roles: roles,
        deviceId: resolvedDeviceId,
        active: true,
        mustChangePassword: true,
        createdAt: now,
        createdBy: by,
        changeLog: [UserChangeLogEntry(at: now, by: by, action: 'created')],
        projectKeys: _allProjectKeys(resolvedProjects),
        roleProjectKeys: resolvedProjects,
      );
      // Recreating a username whose offline delete is still queued makes
      // that tombstone obsolete — dropping it here (not just relying on
      // the gateway's deletes-before-upserts ordering) keeps the queued
      // state coherent however many offline edits pile up. The pending
      // password reset covers the revive path: the upsert's DO UPDATE
      // never touches password, so a recreated (revived) row only gets
      // the temp password via the targeted reset statement.
      final lower = user.username.toLowerCase();
      return current.copyWith(
        users: [...current.users, user],
        deletedUsernames: current.deletedUsernames
            .where((u) => u.toLowerCase() != lower)
            .toList(),
        pendingPasswordResets: _withPendingReset(current, user.username),
      );
    }, by: by);
  }

  Future<void> setRoles({
    required String username,
    required Set<UserRole> roles,
    String? deviceId,
    Map<UserRole, Set<String>>? roleProjectKeys,
    required String by,
  }) {
    return _mutate((current) {
      final user = current.findUser(username);
      if (user == null) throw StateError('User not found: $username');
      final keepingStoredDeviceId = deviceId == null || deviceId.trim().isEmpty;
      final effectiveDeviceId = keepingStoredDeviceId ? user.deviceId : deviceId;
      // Apply the FORMAT rule only to an id the caller actually supplied.
      // Before that rule this layer enforced nothing but "not empty", so
      // accounts exist whose stored id fails it (a space, over 32 characters).
      // Re-checking an UNCHANGED id would make those accounts uneditable
      // outright — no role change, no project reassignment, not even
      // deactivating them — over something the operator never touched.
      //
      // "Required for capture" still applies either way: skipping it would let
      // an admin-only account be granted the capture role with no Device ID,
      // which the capture-entry gate has no way to satisfy.
      final resolvedDeviceId = keepingStoredDeviceId
          ? _requireDeviceIdForRoles(roles, effectiveDeviceId)
          : _validateDeviceIdForRoles(roles, effectiveDeviceId);
      _validateDeviceIdUnique(current, resolvedDeviceId, excludeUsername: username);
      final resolvedProjects = _resolveRoleProjectKeys(
          current, roles, roleProjectKeys ?? user.roleProjectKeys);
      final updated = AppUser(
        username: user.username,
        passwordHash: user.passwordHash,
        roles: roles,
        deviceId: resolvedDeviceId,
        active: user.active,
        mustChangePassword: user.mustChangePassword,
        createdAt: user.createdAt,
        createdBy: user.createdBy,
        lastLoginAt: user.lastLoginAt,
        changeLog: user.changeLog,
        projectKeys: _allProjectKeys(resolvedProjects),
        roleProjectKeys: resolvedProjects,
        roleProjectKeysKnown: roleProjectKeys != null || user.roleProjectKeysKnown,
      ).withLogEntry('roles_changed', by);
      return _replaceUser(current, updated);
    }, by: by);
  }

  Future<void> setUserProjects({
    required String username,
    required Map<UserRole, Set<String>> roleProjectKeys,
    required String by,
  }) {
    return _mutate((current) {
      final user = current.findUser(username);
      if (user == null) throw StateError('User not found: $username');
      final resolvedProjects = _resolveRoleProjectKeys(current, user.roles, roleProjectKeys);
      final updated = user
          .copyWith(
            projectKeys: _allProjectKeys(resolvedProjects),
            roleProjectKeys: resolvedProjects,
            roleProjectKeysKnown: true,
          )
          .withLogEntry('projects_changed', by);
      return _replaceUser(current, updated);
    }, by: by);
  }

  Future<void> resetPassword({required String username, required String by}) {
    return _mutate((current) {
      final user = current.findUser(username);
      if (user == null) throw StateError('User not found: $username');
      final tempHash = current.settings.defaultTempPasswordHash;
      if (tempHash == null) throw StateError('Set a default temporary password first.');
      return _replaceUser(
        current,
        user.copyWith(passwordHash: tempHash, mustChangePassword: true)
            .withLogEntry('password_reset', by),
      ).copyWith(pendingPasswordResets: _withPendingReset(current, user.username));
    }, by: by);
  }

  /// [current]'s pendingPasswordResets plus [username] (deduped) — the
  /// queue the gateway turns into targeted password writes, since the user
  /// upsert never touches password columns (LWCAM owns them).
  static List<String> _withPendingReset(UsersStore current, String username) {
    final lower = username.toLowerCase();
    return [
      ...current.pendingPasswordResets.where((u) => u.toLowerCase() != lower),
      username,
    ];
  }

  Future<void> setActive({required String username, required bool active, required String by}) {
    return _mutate((current) {
      final user = current.findUser(username);
      if (user == null) throw StateError('User not found: $username');
      return _replaceUser(
        current,
        user.copyWith(active: active).withLogEntry(active ? 'reactivated' : 'deactivated', by),
      );
    }, by: by);
  }

  Future<void> deleteUser({required String username, required String by}) {
    return _mutate((current) {
      final key = username.trim().toLowerCase();
      if (current.findUser(username) == null) throw StateError('User not found: $username');
      return current.copyWith(
        users: current.users.where((u) => u.username.toLowerCase() != key).toList(),
      );
    }, by: by, tombstoneUsername: username.trim());
  }

  Future<void> setDefaultTempPassword({required String plaintext, required String by}) {
    return _mutate((current) {
      return current.copyWith(
        settings: current.settings.copyWith(
          defaultTempPasswordHash: PasswordHasher.hash(plaintext),
        ),
      );
    }, by: by);
  }

  /// Only ever called by SuperAdmin itself — writes directly into
  /// `settings`, not a user record (SuperAdmin is not a store user).
  Future<void> setSuperAdminPassword({required String plaintext, required String by}) {
    return _mutate((current) {
      return current.copyWith(
        settings: current.settings.copyWith(
          superAdminPasswordHash: PasswordHasher.hash(plaintext),
        ),
      );
    }, by: by);
  }

  Future<void> setMetadataKeyingEnabled({required bool enabled, required String by}) {
    return _mutate((current) {
      return current.copyWith(
        settings: current.settings.copyWith(metadataKeyingEnabled: enabled),
      );
    }, by: by);
  }

  Future<void> setShutterConfig({
    String? keybind,
    String? method,
    double? tapXPercent,
    double? tapYPercent,
    required String by,
  }) {
    return _mutate((current) {
      return current.copyWith(
        settings: current.settings.copyWith(
          shutterKeybind: keybind,
          shutterMethod: method,
          shutterTapXPercent: tapXPercent,
          shutterTapYPercent: tapYPercent,
        ),
      );
    }, by: by);
  }

  // ── Projects ───────────────────────────────────────────────────────────────

  static String _validateLocationCode(UsersStore current, String code, {String? excludeKey}) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) throw StateError('Country/Location Code is required.');
    if (trimmed.length > 32) {
      throw StateError('Country/Location Code must be 32 characters or fewer.');
    }
    final lower = trimmed.toLowerCase();
    for (final p in current.projects) {
      if (p.key == excludeKey) continue;
      if ((p.countryLocationCode ?? '').toLowerCase() == lower) {
        throw StateError(
            'Country/Location Code "$trimmed" is already used by project "${p.name}".');
      }
    }
    return trimmed;
  }

  /// PostgreSQL enforces `project_name UNIQUE` — the old NAS-only UI never
  /// had to check this locally; an offline edit that collides fails only
  /// when it finally pushes, so check it up front too.
  static void _validateProjectName(UsersStore current, String name, {String? excludeKey}) {
    final lower = name.trim().toLowerCase();
    for (final p in current.projects) {
      if (p.key == excludeKey) continue;
      if (p.name.trim().toLowerCase() == lower) {
        throw StateError('A project named "$name" already exists.');
      }
    }
  }

  /// The user_projects push encodes assignments as `projectId|role`
  /// pairs (see AdminPgGateway/userProjectsPruneSql) — a '|' inside the
  /// free-text Project ID would make that encoding ambiguous and could
  /// wrongly keep or prune rows.
  static void _validateProjectIdChars(String projectId) {
    if (projectId.contains('|')) {
      throw StateError('Project ID cannot contain the "|" character.');
    }
  }

  /// PostgreSQL enforces `users.device_id UNIQUE` — same reasoning as above.
  static void _validateDeviceIdUnique(UsersStore current, String? deviceId,
      {required String? excludeUsername}) {
    if (deviceId == null || deviceId.isEmpty) return;
    final lower = deviceId.toLowerCase();
    for (final u in current.users) {
      if (excludeUsername != null && u.username.toLowerCase() == excludeUsername.toLowerCase()) {
        continue;
      }
      if ((u.deviceId ?? '').toLowerCase() == lower) {
        throw StateError('Device ID "$deviceId" is already assigned to "${u.username}".');
      }
    }
  }

  Future<Project> createProject({
    required String name,
    required String projectId,
    required String countryLocationCode,
    required DateTime startDate,
    required String by,
  }) async {
    final trimmedName = name.trim();
    final trimmedId = projectId.trim();
    if (trimmedName.isEmpty) throw StateError('Project Name is required.');
    if (trimmedId.isEmpty) throw StateError('Project ID is required.');
    _validateProjectIdChars(trimmedId);
    late Project created;
    await _mutate((current) {
      if (current.findProjectById(trimmedId) != null) {
        throw StateError('A project with ID "$trimmedId" already exists.');
      }
      _validateProjectName(current, trimmedName);
      final code = _validateLocationCode(current, countryLocationCode);
      created = Project(
        key: generateProjectKey(),
        projectId: trimmedId,
        name: trimmedName,
        countryLocationCode: code,
        startDate: startDate,
        createdAt: DateTime.now(),
        createdBy: by,
      );
      return current.copyWith(projects: [...current.projects, created]);
    }, by: by);
    return created;
  }

  Future<void> updateProject({
    required String key,
    String? name,
    String? projectId,
    String? countryLocationCode,
    DateTime? startDate,
    required String by,
  }) {
    return _mutate((current) {
      final project = current.findProjectByKey(key);
      if (project == null) throw StateError('Project not found.');
      final trimmedId = projectId?.trim();
      if (trimmedId != null && trimmedId.isEmpty) throw StateError('Project ID is required.');
      if (trimmedId != null) _validateProjectIdChars(trimmedId);
      if (trimmedId != null) {
        final existing = current.findProjectById(trimmedId);
        if (existing != null && existing.key != key) {
          throw StateError('A project with ID "$trimmedId" already exists.');
        }
      }
      final trimmedName = name?.trim();
      if (trimmedName != null && trimmedName.isEmpty) throw StateError('Project Name is required.');
      if (trimmedName != null) _validateProjectName(current, trimmedName, excludeKey: key);
      final code = countryLocationCode == null
          ? null
          : _validateLocationCode(current, countryLocationCode, excludeKey: key);
      final updated = project.copyWith(
        name: trimmedName,
        projectId: trimmedId,
        countryLocationCode: code,
        startDate: startDate,
      );
      return current.copyWith(
        projects: current.projects.map((p) => p.key == key ? updated : p).toList(),
      );
    }, by: by);
  }

  Future<void> deleteProject({required String key, required String by}) {
    return _mutate((current) {
      if (current.findProjectByKey(key) == null) throw StateError('Project not found.');
      return current.copyWith(
        projects: current.projects.where((p) => p.key != key).toList(),
        users: current.users
            .map((u) => u.projectKeys.contains(key)
                ? u.copyWith(
                    projectKeys: u.projectKeys.difference({key}),
                    roleProjectKeys: {
                      for (final entry in u.roleProjectKeys.entries)
                        entry.key: entry.value.difference({key}),
                    },
                  )
                : u)
            .toList(),
      );
    }, by: by, tombstoneProjectKey: key);
  }

  Future<void> setProjectTemplate({
    required String key,
    required MetadataTemplate? template,
    required String by,
  }) {
    return _mutate((current) {
      if (current.findProjectByKey(key) == null) throw StateError('Project not found.');
      return current.copyWith(
        projects: current.projects
            .map((p) => p.key == key
                ? p.copyWith(template: template, clearTemplate: template == null)
                : p)
            .toList(),
      );
    }, by: by);
  }

  /// Drops any key that doesn't resolve to a real project.
  Set<String> _resolveProjectKeys(UsersStore current, Set<String> keys) =>
      keys.where((k) => current.findProjectByKey(k) != null).toSet();

  Map<UserRole, Set<String>> _resolveRoleProjectKeys(
      UsersStore current, Set<UserRole> roles, Map<UserRole, Set<String>> values) => {
        for (final role in roles) role: _resolveProjectKeys(current, values[role] ?? const {}),
      };

  Set<String> _allProjectKeys(Map<UserRole, Set<String>> values) =>
      values.values.expand((keys) => keys).toSet();

  /// Presence only, no format rule — for an id being carried over unchanged.
  /// See the call site in updateUser for why a legacy id must not be re-checked.
  String? _requireDeviceIdForRoles(Set<UserRole> roles, String? deviceId) {
    if (!roles.contains(UserRole.capture)) return null;
    final trimmed = deviceId?.trim() ?? '';
    if (trimmed.isEmpty) {
      throw StateError('A Device ID is required for Capture accounts.');
    }
    return trimmed;
  }

  String? _validateDeviceIdForRoles(Set<UserRole> roles, String? deviceId) {
    if (!roles.contains(UserRole.capture)) return null;
    // Normalize BEFORE validating, so a lower-case entry is accepted and
    // stored upper case rather than rejected. Every create and update funnels
    // through here, so this is the one place the stored form is decided.
    final normalized = normalizeDeviceId(deviceId ?? '');
    if (normalized.isEmpty) {
      throw StateError('A Device ID is required for Capture accounts.');
    }
    if (!kDeviceIdPattern.hasMatch(normalized)) {
      throw StateError(
        'Device ID "$normalized" is not usable. It becomes part of a file name, '
        'so use 2-32 letters, digits, "_" or "-", starting with a letter or digit.',
      );
    }
    return normalized;
  }

  UsersStore _replaceUser(UsersStore current, AppUser updated) {
    final key = updated.username.toLowerCase();
    return current.copyWith(
      users: current.users.map((u) => u.username.toLowerCase() == key ? updated : u).toList(),
    );
  }

  // ── The mutate primitive ────────────────────────────────────────────────

  /// Every mutation funnels through here. Reconciles first (so an online
  /// mutation is never applied on top of a stale local copy), applies
  /// [transform] (validation throws happen here, before anything is
  /// written), then either pushes+pulls (online) or queues offline
  /// (dirty + tombstone). [tombstoneUsername]/[tombstoneProjectKey] record a
  /// delete so it survives a restart until the next successful push.
  Future<void> _mutate(
    UsersStore Function(UsersStore current) transform, {
    required String by,
    String? tombstoneUsername,
    String? tombstoneProjectKey,
  }) async {
    await trySync();
    final lock = File('$_path.lock');
    await _acquireLock(lock);
    try {
      final file = File(_path);
      final current = await _readStore(file) ?? store.value ?? const UsersStore();
      var next = transform(current);
      next = next.copyWith(updatedAt: DateTime.now(), updatedBy: by);

      if (online.value && !schemaOutdated.value) {
        try {
          var toPush = next;
          if (tombstoneUsername != null) {
            toPush = toPush.copyWith(
                deletedUsernames: [...toPush.deletedUsernames, tombstoneUsername]);
          }
          if (tombstoneProjectKey != null) {
            toPush = toPush.copyWith(
                deletedProjectKeys: [...toPush.deletedProjectKeys, tombstoneProjectKey]);
          }
          await gateway.pushSnapshot(toPush);
          lastPushAt.value = DateTime.now();
          final pulled = await gateway.pullStore();
          await _writeJsonAtomic(file, pulled.toJson());
          store.value = pulled;
          dirty.value = false;
          lastPullAt.value = DateTime.now();
          return;
        } catch (e) {
          print('⚠️ Push failed mid-mutation, queuing offline: $e');
          online.value = false;
          lastError.value = '$e';
          // Fall through to the offline branch below.
        }
      }

      next = next.copyWith(
        dirty: true,
        deletedUsernames: tombstoneUsername != null
            ? [...next.deletedUsernames, tombstoneUsername]
            : next.deletedUsernames,
        deletedProjectKeys: tombstoneProjectKey != null
            ? [...next.deletedProjectKeys, tombstoneProjectKey]
            : next.deletedProjectKeys,
      );
      await _writeJsonAtomic(file, next.toJson());
      store.value = next;
      dirty.value = true;
    } finally {
      await _releaseLock(lock);
    }
  }

  // ── Local file machinery (lifted from LWCAM's former NAS-store service) ──

  Future<void> _acquireLock(File lock) async {
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
    throw StateError('Could not acquire the users-store lock (another admin may be editing).');
  }

  Future<void> _releaseLock(File lock) async {
    try {
      if (await lock.exists()) await lock.delete();
    } catch (_) {}
  }

  Future<bool> _createJsonExclusive(File target, Map<String, dynamic> json) async {
    if (!await target.parent.exists()) await target.parent.create(recursive: true);
    try {
      await target.create(exclusive: true);
    } on FileSystemException {
      return false;
    }
    await target.writeAsString(jsonEncode(json), flush: true);
    return true;
  }

  Future<void> _writeJsonAtomic(File target, Map<String, dynamic> json) async {
    if (!await target.parent.exists()) await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    if (await target.exists()) await target.delete();
    await tmp.rename(target.path);
  }

  Future<UsersStore?> _readStore(File file, {int attempts = 5}) async {
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

  @override
  void onClose() {
    gateway.close();
    super.onClose();
  }
}
