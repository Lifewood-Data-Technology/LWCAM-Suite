/// User-management domain models, shared with LWCAM's copy of this file
/// (same JSON shape, minus the two Enc fields LWCAM never had reason to
/// keep once admin-viewable passwords were retired). Pure Dart — PostgreSQL
/// is the source of truth; this serializes to/from the local JSON fallback
/// snapshot (see admin_store_service.dart), not a DB driver.
library;

import 'project.dart';

/// The most recent change-log entries kept per user (audit-light). Older
/// entries are trimmed on write.
const int kUserChangeLogCap = 20;

enum UserRole {
  admin,
  capture,

  /// Folder QC reviewer. This app grants the role and owns the account row; the
  /// reviewing itself happens in the LWCam QC web platform, which reads the same
  /// `users` table. LWCAM has no `qc` member — it has no QC workflow — and
  /// preserves the string opaquely via [AppUser.extraRoles] instead.
  qc;

  String get jsonValue => name;

  static UserRole? fromJson(Object? value) {
    switch (value?.toString()) {
      case 'admin':
        return UserRole.admin;
      case 'capture':
        return UserRole.capture;
      case 'qc':
        return UserRole.qc;
      default:
        return null; // unknown role on disk is ignored, not fatal
    }
  }
}

class UserChangeLogEntry {
  final DateTime at;
  final String by;
  final String action;

  const UserChangeLogEntry({required this.at, required this.by, required this.action});

  Map<String, Object?> toJson() => {
    'at': at.toIso8601String(),
    'by': by,
    'action': action,
  };

  factory UserChangeLogEntry.fromJson(Map<String, Object?> json) => UserChangeLogEntry(
    at: DateTime.tryParse(json['at']?.toString() ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    by: json['by']?.toString() ?? '',
    action: json['action']?.toString() ?? '',
  );
}

/// A Device ID is free-form, but NOT unconstrained: it is interpolated
/// straight into a filename — `lwcam_stats_<deviceId>.db` in
/// `upload_stats_db.dart`, and the `<deviceId>_IMG_<stamp>_001.jpg` prefix on
/// every captured image — with no sanitising at either site. A path separator
/// or a `:` there would break the station's database path rather than be
/// rejected, so the character set is held to what is safe in a Windows file
/// name: 2-32 of A-Z, 0-9, underscore and hyphen, starting alphanumeric.
///
/// Letters are stored upper case ([normalizeDeviceId]); the ID is compared
/// case-insensitively for uniqueness but stamped on records verbatim, so one
/// canonical case keeps `MYTP01` and `mytp01` from reading as two devices.
/// It used to be locked to `SAX##`, which no longer matches how sites are named.
final RegExp kDeviceIdPattern = RegExp(r'^[A-Z0-9][A-Z0-9_-]{1,31}$');

/// Trim and upper-case a typed Device ID. Does not validate — callers check
/// [kDeviceIdPattern] on the result.
String normalizeDeviceId(String raw) => raw.trim().toUpperCase();

class AppUser {
  final String username;
  final String passwordHash;
  final Set<UserRole> roles;

  /// The operator ID assigned to this account at creation — see
  /// [kDeviceIdPattern]. Required for Capture accounts (it stamps their
  /// transfer records); null/empty for Admin-only accounts, which don't
  /// capture and have no Device ID.
  final String? deviceId;
  final bool active;
  final bool mustChangePassword;
  final DateTime? createdAt;
  final String? createdBy;
  final DateTime? lastLoginAt;
  final String? lastLoginDeviceId;
  final List<UserChangeLogEntry> changeLog;

  /// Legacy union used for display and old snapshots. Authorization and push
  /// use [roleProjectKeys], never this flattened compatibility value.
  final Set<String> projectKeys;

  /// Exact project grants by role, matching PostgreSQL `user_projects`.
  final Map<UserRole, Set<String>> roleProjectKeys;

  /// False only for an old mixed-role JSON snapshot whose flattened grants
  /// cannot be safely reconstructed. Such a snapshot must pull before push.
  final bool roleProjectKeysKnown;

  /// Tokens from `users.roles` this app has no [UserRole] for — a role owned by
  /// some other module in the suite. Carried through verbatim so a whole-store
  /// push can never strip a role this app merely doesn't model; same guarantee
  /// [UsersStore.adminExtras] gives the sibling app's JSON keys in LWCAM.
  /// Never surfaced in the UI — it exists purely so writes are lossless.
  final Set<String> extraRoles;

  const AppUser({
    required this.username,
    required this.passwordHash,
    required this.roles,
    this.deviceId,
    this.active = true,
    this.mustChangePassword = false,
    this.createdAt,
    this.createdBy,
    this.lastLoginAt,
    this.lastLoginDeviceId,
    this.changeLog = const [],
    this.projectKeys = const {},
    this.roleProjectKeys = const {},
    this.roleProjectKeysKnown = true,
    this.extraRoles = const {},
  });

  /// The value to write into `users.roles`: modelled roles plus anything this
  /// app didn't understand. The single place that string is built.
  String get rolesColumnValue =>
      [...roles.map((r) => r.jsonValue), ...extraRoles].join(',');

  bool get isAdmin => roles.contains(UserRole.admin);

  // Capture ability comes ONLY from the Capture role — the Admin role by
  // itself does NOT grant capture (admins don't capture and have no Device
  // ID). Someone who both administers and captures holds Admin + Capture.
  bool get canNormalMode => roles.contains(UserRole.capture);

  /// True when this account must carry a Device ID (it can capture).
  bool get requiresDeviceId => canNormalMode;

  Set<String> projectKeysFor(UserRole role) {
    final assigned = roleProjectKeys[role];
    if (assigned != null) return assigned;
    return roles.length == 1 && roles.contains(role) ? projectKeys : const {};
  }

  AppUser copyWith({
    String? passwordHash,
    Set<UserRole>? roles,
    String? deviceId,
    bool? active,
    bool? mustChangePassword,
    DateTime? lastLoginAt,
    String? lastLoginDeviceId,
    List<UserChangeLogEntry>? changeLog,
    Set<String>? projectKeys,
    Map<UserRole, Set<String>>? roleProjectKeys,
    bool? roleProjectKeysKnown,
    Set<String>? extraRoles,
  }) {
    return AppUser(
      username: username,
      passwordHash: passwordHash ?? this.passwordHash,
      roles: roles ?? this.roles,
      deviceId: deviceId ?? this.deviceId,
      active: active ?? this.active,
      mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      createdAt: createdAt,
      createdBy: createdBy,
      lastLoginAt: lastLoginAt ?? this.lastLoginAt,
      lastLoginDeviceId: lastLoginDeviceId ?? this.lastLoginDeviceId,
      changeLog: changeLog ?? this.changeLog,
      projectKeys: projectKeys ?? this.projectKeys,
      roleProjectKeys: roleProjectKeys ?? this.roleProjectKeys,
      roleProjectKeysKnown: roleProjectKeysKnown ?? this.roleProjectKeysKnown,
      extraRoles: extraRoles ?? this.extraRoles,
    );
  }

  /// Appends an audit entry, trimming to the most recent [kUserChangeLogCap].
  AppUser withLogEntry(String action, String by, {DateTime? at}) {
    final entry = UserChangeLogEntry(at: at ?? DateTime.now(), by: by, action: action);
    final updated = [...changeLog, entry];
    final trimmed = updated.length > kUserChangeLogCap
        ? updated.sublist(updated.length - kUserChangeLogCap)
        : updated;
    return copyWith(changeLog: trimmed);
  }

  Map<String, Object?> toJson() => {
    'username': username,
    'passwordHash': passwordHash,
    'roles': roles.map((r) => r.jsonValue).toList(),
    'deviceId': deviceId,
    'active': active,
    'mustChangePassword': mustChangePassword,
    'createdAt': createdAt?.toIso8601String(),
    'createdBy': createdBy,
    'lastLoginAt': lastLoginAt?.toIso8601String(),
    'lastLoginDeviceId': lastLoginDeviceId,
    'changeLog': changeLog.map((e) => e.toJson()).toList(),
    'projectKeys': projectKeys.toList(),
    'roleProjectKeys': {
      for (final entry in roleProjectKeys.entries) entry.key.jsonValue: entry.value.toList(),
    },
    'roleProjectKeysKnown': roleProjectKeysKnown,
    'extraRoles': extraRoles.toList(),
  };

  factory AppUser.fromJson(Map<String, Object?> json) {
    final rawRoles = (json['roles'] as List?) ?? const [];
    final roles = rawRoles.map(UserRole.fromJson).whereType<UserRole>().toSet();
    // Unrecognized entries under `roles` are folded into extraRoles too, so a
    // snapshot written before this field existed still round-trips them.
    final extraRoles = <String>{
      ...rawRoles.where((e) => UserRole.fromJson(e) == null).map((e) => e.toString()),
      ...(((json['extraRoles'] as List?) ?? const []).map((e) => e.toString())),
    }..removeWhere((e) => e.trim().isEmpty);
    final rawLog = (json['changeLog'] as List?) ?? const [];
    final rawDeviceId = json['deviceId']?.toString();
    final rawProjectKeys = (json['projectKeys'] as List?) ?? const [];
    final rawRoleProjectKeys = json['roleProjectKeys'];
    final roleProjectKeys = <UserRole, Set<String>>{};
    if (rawRoleProjectKeys is Map) {
      for (final entry in rawRoleProjectKeys.entries) {
        final role = UserRole.fromJson(entry.key);
        if (role == null || entry.value is! List) continue;
        roleProjectKeys[role] = (entry.value as List).map((e) => e.toString()).toSet();
      }
    } else if (roles.length == 1) {
      roleProjectKeys[roles.first] = rawProjectKeys.map((e) => e.toString()).toSet();
    }
    final legacyAmbiguous = rawRoleProjectKeys is! Map && roles.length > 1 && rawProjectKeys.isNotEmpty;
    return AppUser(
      username: json['username']?.toString() ?? '',
      passwordHash: json['passwordHash']?.toString() ?? '',
      roles: roles,
      deviceId: (rawDeviceId != null && rawDeviceId.isNotEmpty) ? rawDeviceId : null,
      active: json['active'] as bool? ?? true,
      mustChangePassword: json['mustChangePassword'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      createdBy: json['createdBy']?.toString(),
      lastLoginAt: DateTime.tryParse(json['lastLoginAt']?.toString() ?? ''),
      lastLoginDeviceId: json['lastLoginDeviceId']?.toString(),
      changeLog: rawLog
          .whereType<Map>()
          .map((e) => UserChangeLogEntry.fromJson(e.cast<String, Object?>()))
          .toList(),
      projectKeys: rawProjectKeys.map((e) => e.toString()).toSet(),
      roleProjectKeys: roleProjectKeys,
      roleProjectKeysKnown: (json['roleProjectKeysKnown'] as bool?) ?? !legacyAmbiguous,
      extraRoles: extraRoles,
    );
  }
}

/// Cross-PC settings that live in the shared users file (not per-PC prefs, so
/// every operator machine agrees — see plan D3).
/// Allowed values for [SharedAppSettings.shutterMethod] — how the PC-side
/// trigger fires the phone camera shutter over ADB.
const List<String> kShutterMethods = ['tap', 'camera', 'volumeDown', 'volumeUp'];

/// Allowed values for [SharedAppSettings.shutterKeybind] — the global hotkey
/// that triggers the shutter (kept small so it maps cleanly to a
/// PhysicalKeyboardKey and is safe as a system hotkey).
const List<String> kShutterKeybinds = [
  'Space', 'Enter', 'Delete',
  'F1', 'F2', 'F3', 'F4', 'F5', 'F6',
  'F7', 'F8', 'F9', 'F10', 'F11', 'F12',
];

/// Cross-PC settings that live in the shared users file (not per-PC prefs, so
/// every operator machine agrees — see plan D3).
class SharedAppSettings {
  final bool metadataKeyingEnabled;
  final String? defaultTempPasswordHash;

  /// Override for the built-in SuperAdmin account's password (see
  /// `auth/super_admin.dart`). Null means the factory password applies.
  /// Deliberately has NO reversible `...Enc` twin — SuperAdmin's password is
  /// never admin-viewable, unlike regular users' and the default temp
  /// password. Settable only by SuperAdmin itself.
  final String? superAdminPasswordHash;

  // ── Remote camera shutter (Phase I) ─────────────────────────────────────
  /// Global hotkey that triggers the phone shutter (one of [kShutterKeybinds]).
  final String shutterKeybind;
  /// How the shutter is fired on the phone (one of [kShutterMethods]).
  final String shutterMethod;
  /// For shutterMethod == 'tap': shutter position as a percentage of the phone
  /// screen (0–100). Default bottom-centre.
  final double shutterTapXPercent;
  final double shutterTapYPercent;

  const SharedAppSettings({
    this.metadataKeyingEnabled = false,
    this.defaultTempPasswordHash,
    this.superAdminPasswordHash,
    this.shutterKeybind = 'Space',
    this.shutterMethod = 'tap',
    this.shutterTapXPercent = 50,
    this.shutterTapYPercent = 90,
  });

  SharedAppSettings copyWith({
    bool? metadataKeyingEnabled,
    String? defaultTempPasswordHash,
    String? superAdminPasswordHash,
    String? shutterKeybind,
    String? shutterMethod,
    double? shutterTapXPercent,
    double? shutterTapYPercent,
  }) {
    return SharedAppSettings(
      metadataKeyingEnabled: metadataKeyingEnabled ?? this.metadataKeyingEnabled,
      defaultTempPasswordHash: defaultTempPasswordHash ?? this.defaultTempPasswordHash,
      superAdminPasswordHash: superAdminPasswordHash ?? this.superAdminPasswordHash,
      shutterKeybind: shutterKeybind ?? this.shutterKeybind,
      shutterMethod: shutterMethod ?? this.shutterMethod,
      shutterTapXPercent: shutterTapXPercent ?? this.shutterTapXPercent,
      shutterTapYPercent: shutterTapYPercent ?? this.shutterTapYPercent,
    );
  }

  Map<String, Object?> toJson() => {
    'metadataKeyingEnabled': metadataKeyingEnabled,
    'defaultTempPasswordHash': defaultTempPasswordHash,
    'superAdminPasswordHash': superAdminPasswordHash,
    'shutterKeybind': shutterKeybind,
    'shutterMethod': shutterMethod,
    'shutterTapXPercent': shutterTapXPercent,
    'shutterTapYPercent': shutterTapYPercent,
  };

  factory SharedAppSettings.fromJson(Map<String, Object?>? json) {
    if (json == null) return const SharedAppSettings();
    final kb = json['shutterKeybind']?.toString();
    final method = json['shutterMethod']?.toString();
    return SharedAppSettings(
      metadataKeyingEnabled: json['metadataKeyingEnabled'] as bool? ?? false,
      defaultTempPasswordHash: json['defaultTempPasswordHash']?.toString(),
      superAdminPasswordHash: json['superAdminPasswordHash']?.toString(),
      shutterKeybind: (kb != null && kShutterKeybinds.contains(kb)) ? kb : 'Space',
      shutterMethod: (method != null && kShutterMethods.contains(method)) ? method : 'tap',
      shutterTapXPercent: (json['shutterTapXPercent'] as num?)?.toDouble() ?? 50,
      shutterTapYPercent: (json['shutterTapYPercent'] as num?)?.toDouble() ?? 90,
    );
  }
}

class UsersStore {
  final int schemaVersion;
  final DateTime? updatedAt;
  final String? updatedBy;
  final SharedAppSettings settings;
  final List<AppUser> users;
  final List<Project> projects;

  /// True when this snapshot has local edits not yet pushed to PostgreSQL
  /// (made while offline). AdminStoreService.trySync clears it after a
  /// successful push. LWCAM's parser ignores this key — it never writes it.
  final bool dirty;

  /// Usernames/project keys deleted locally while offline, queued as
  /// soft-delete statements for the next successful push. Cleared together
  /// with [dirty] on push. LWCAM's parser ignores these keys.
  final List<String> deletedUsernames;
  final List<String> deletedProjectKeys;

  /// Usernames whose password THIS APP explicitly set (resetPassword, or
  /// createUser reviving a deleted username) and which must therefore be
  /// written to PG. Needed because the user upsert's DO UPDATE deliberately
  /// never touches password/must_change_password — LWCAM owns those via
  /// its own changeOwnPassword write, and a whole-store push carrying a
  /// stale hash must never regress a password a capture user just changed.
  /// Cleared by the pull that follows a successful push, like the
  /// tombstones. LWCAM's parser ignores this key.
  final List<String> pendingPasswordResets;

  static const int currentSchemaVersion = 1;

  const UsersStore({
    this.schemaVersion = currentSchemaVersion,
    this.updatedAt,
    this.updatedBy,
    this.settings = const SharedAppSettings(),
    this.users = const [],
    this.projects = const [],
    this.dirty = false,
    this.deletedUsernames = const [],
    this.deletedProjectKeys = const [],
    this.pendingPasswordResets = const [],
  });

  /// Case-insensitive lookup (usernames are stored trimmed).
  AppUser? findUser(String username) {
    final key = username.trim().toLowerCase();
    for (final u in users) {
      if (u.username.toLowerCase() == key) return u;
    }
    return null;
  }

  Project? findProjectByKey(String key) {
    for (final p in projects) {
      if (p.key == key) return p;
    }
    return null;
  }

  /// Case-insensitive lookup on the user-editable Project ID (uniqueness key).
  Project? findProjectById(String projectId) {
    final id = projectId.trim().toLowerCase();
    for (final p in projects) {
      if (p.projectId.trim().toLowerCase() == id) return p;
    }
    return null;
  }

  UsersStore copyWith({
    DateTime? updatedAt,
    String? updatedBy,
    SharedAppSettings? settings,
    List<AppUser>? users,
    List<Project>? projects,
    bool? dirty,
    List<String>? deletedUsernames,
    List<String>? deletedProjectKeys,
    List<String>? pendingPasswordResets,
  }) {
    return UsersStore(
      schemaVersion: schemaVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
      settings: settings ?? this.settings,
      users: users ?? this.users,
      projects: projects ?? this.projects,
      dirty: dirty ?? this.dirty,
      deletedUsernames: deletedUsernames ?? this.deletedUsernames,
      deletedProjectKeys: deletedProjectKeys ?? this.deletedProjectKeys,
      pendingPasswordResets: pendingPasswordResets ?? this.pendingPasswordResets,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'updatedAt': updatedAt?.toIso8601String(),
    'updatedBy': updatedBy,
    'settings': settings.toJson(),
    'users': users.map((u) => u.toJson()).toList(),
    'projects': projects.map((p) => p.toJson()).toList(),
    'dirty': dirty,
    'deletedUsernames': deletedUsernames,
    'deletedProjectKeys': deletedProjectKeys,
    'pendingPasswordResets': pendingPasswordResets,
  };

  factory UsersStore.fromJson(Map<String, Object?> json) {
    final rawUsers = (json['users'] as List?) ?? const [];
    final rawProjects = (json['projects'] as List?) ?? const [];
    final rawDeletedUsernames = (json['deletedUsernames'] as List?) ?? const [];
    final rawDeletedProjectKeys = (json['deletedProjectKeys'] as List?) ?? const [];
    final rawPendingResets = (json['pendingPasswordResets'] as List?) ?? const [];
    return UsersStore(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? currentSchemaVersion,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
      updatedBy: json['updatedBy']?.toString(),
      settings: SharedAppSettings.fromJson(json['settings'] as Map<String, Object?>?),
      users: rawUsers
          .whereType<Map>()
          .map((e) => AppUser.fromJson(e.cast<String, Object?>()))
          .toList(),
      projects: rawProjects
          .whereType<Map>()
          .map((e) => Project.fromJson(e.cast<String, Object?>()))
          .toList(),
      dirty: json['dirty'] as bool? ?? false,
      deletedUsernames: rawDeletedUsernames.map((e) => e.toString()).toList(),
      deletedProjectKeys: rawDeletedProjectKeys.map((e) => e.toString()).toList(),
      pendingPasswordResets: rawPendingResets.map((e) => e.toString()).toList(),
    );
  }
}
