/// User-management domain models (spec §9/§10). Pure Dart — the users store
/// is a JSON file on the NAS, so these serialize to/from JSON (not a DB).
library;

import 'project.dart';

/// The most recent change-log entries kept per user (audit-light). Older
/// entries are trimmed on write.
const int kUserChangeLogCap = 20;

enum UserRole {
  admin,
  capture,
  // QC arrived when the QC platform merged into this app. The string matches
  // the one the QC backend and LWCam Admin write into `users.roles` - their
  // parsers are exact lowercase matches, so it must stay 'qc'.
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

class AppUser {
  final String username;
  final String passwordHash;
  final Set<UserRole> roles;

  /// The operator ID assigned to this account at creation. Required for
  /// Capture accounts (it stamps their transfer records); null/empty for
  /// Admin-only accounts, which don't capture and have no Device ID.
  final String? deviceId;
  final bool active;
  final bool mustChangePassword;
  final DateTime? createdAt;
  final String? createdBy;
  final DateTime? lastLoginAt;
  final String? lastLoginDeviceId;
  final List<UserChangeLogEntry> changeLog;

  /// Legacy union of assigned project keys. New snapshots also carry
  /// [roleProjectKeys]; callers that make authorization decisions must use
  /// [projectKeysFor] instead of this compatibility field.
  final Set<String> projectKeys;

  /// Exact project grants, separated by role. PostgreSQL's `user_projects`
  /// table is role-specific, so flattening this map would grant QC/Admin
  /// projects to Capture users.
  final Map<UserRole, Set<String>> roleProjectKeys;

  /// Role/project pairs owned by other apps (currently QC). LWCAM never uses
  /// them, but must round-trip them when rewriting the shared JSON snapshot.
  final Map<String, Set<String>> extraRoleProjectKeys;

  /// Tokens from `users.roles` this app has no [UserRole] for — `qc` (the Folder
  /// QC web platform's role) and any other module's. This app never writes
  /// `users.roles` to PostgreSQL, but it DOES rewrite the shared
  /// `lwcam_users.json` snapshot wholesale on every pull, and LWCam Admin pushes
  /// from that same file — so dropping these here would still revoke the role by
  /// the next admin save. Carried verbatim for the same reason
  /// [UsersStore.adminExtras] carries the sibling app's JSON keys.
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
    this.extraRoleProjectKeys = const {},
    this.extraRoles = const {},
  });

  bool get isAdmin => roles.contains(UserRole.admin);

  // Capture ability comes ONLY from the Capture role — the Admin role by
  // itself does NOT grant capture (admins don't capture and have no Device
  // ID). Someone who both administers and captures holds Admin + Capture.
  bool get canNormalMode => roles.contains(UserRole.capture);

  /// Quality-check ability. Independent of capture and admin: a QC operator
  /// reviews what other people captured and has no Device ID of their own.
  bool get canQc => roles.contains(UserRole.qc);

  /// True when this account must carry a Device ID (it can capture).
  bool get requiresDeviceId => canNormalMode;

  Set<String> projectKeysFor(UserRole role) {
    final assigned = roleProjectKeys[role];
    if (assigned != null) return assigned;
    // A single-role legacy snapshot has no ambiguity. Mixed legacy snapshots
    // deliberately get no implied grants until PostgreSQL supplies the pairs.
    return roles.length == 1 && roles.contains(role) ? projectKeys : const {};
  }

  /// The roles this account holds on one specific project — what decides which
  /// tabs that project's screen offers.
  ///
  /// BOTH layers must agree. The role itself is global (`users.roles`, so an
  /// account with no project at all still keeps it); `user_projects` then says
  /// which projects that role reaches. Either alone is not a grant: a role with
  /// no matching project row opens nothing, and a leftover project row for a
  /// role the account no longer holds must not resurrect it.
  Set<UserRole> rolesForProjectKey(String projectKey) => {
        for (final r in roles)
          if (projectKeysFor(r).contains(projectKey)) r,
      };

  /// Every project key this account may open, in any role — the union of the
  /// per-role grants. The list of projects is role-agnostic; what can be DONE
  /// in one is not (see [rolesForProjectKey]).
  Set<String> get allProjectKeys => {
        for (final r in roles) ...projectKeysFor(r),
      };

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
    Map<String, Set<String>>? extraRoleProjectKeys,
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
      extraRoleProjectKeys: extraRoleProjectKeys ?? this.extraRoleProjectKeys,
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
      for (final entry in extraRoleProjectKeys.entries) entry.key: entry.value.toList(),
    },
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
    final extraRoleProjectKeys = <String, Set<String>>{};
    if (rawRoleProjectKeys is Map) {
      for (final entry in rawRoleProjectKeys.entries) {
        final role = UserRole.fromJson(entry.key);
        if (entry.value is! List) continue;
        final keys = (entry.value as List).map((e) => e.toString()).toSet();
        if (role == null) {
          extraRoleProjectKeys[entry.key.toString()] = keys;
        } else {
          roleProjectKeys[role] = keys;
        }
      }
    } else if (roles.length == 1) {
      roleProjectKeys[roles.first] = rawProjectKeys.map((e) => e.toString()).toSet();
    }
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
      extraRoleProjectKeys: extraRoleProjectKeys,
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

  /// JSON keys LWCam Admin writes into the shared `lwcam_users.json` that
  /// LWCAM itself has no model for (its offline-edit queue: `dirty`,
  /// `deletedUsernames`, `deletedProjectKeys`, `pendingPasswordResets`, and
  /// whatever it adds next). Carried OPAQUELY through every LWCAM write so
  /// a local rewrite (e.g. changeOwnPassword's mirror update) can never
  /// silently strip the sibling app's queued state from the shared file.
  final Map<String, Object?> adminExtras;

  /// True when LWCam Admin has offline edits queued in this snapshot that
  /// have not reached PostgreSQL — LWCAM must NOT overwrite the file with
  /// a pulled store in that case (the pull predates those edits).
  bool get hasPendingAdminEdits => adminExtras['dirty'] == true;

  static const int currentSchemaVersion = 1;

  const UsersStore({
    this.schemaVersion = currentSchemaVersion,
    this.updatedAt,
    this.updatedBy,
    this.settings = const SharedAppSettings(),
    this.users = const [],
    this.projects = const [],
    this.adminExtras = const {},
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
  }) {
    return UsersStore(
      schemaVersion: schemaVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      updatedBy: updatedBy ?? this.updatedBy,
      settings: settings ?? this.settings,
      users: users ?? this.users,
      projects: projects ?? this.projects,
      adminExtras: adminExtras,
    );
  }

  /// LWCAM's own keys — anything else in the file belongs to LWCam Admin
  /// and is preserved verbatim (see [adminExtras]).
  static const Set<String> _ownKeys = {
    'schemaVersion', 'updatedAt', 'updatedBy', 'settings', 'users', 'projects',
  };

  Map<String, Object?> toJson() => {
    ...adminExtras,
    'schemaVersion': schemaVersion,
    'updatedAt': updatedAt?.toIso8601String(),
    'updatedBy': updatedBy,
    'settings': settings.toJson(),
    'users': users.map((u) => u.toJson()).toList(),
    'projects': projects.map((p) => p.toJson()).toList(),
  };

  factory UsersStore.fromJson(Map<String, Object?> json) {
    final rawUsers = (json['users'] as List?) ?? const [];
    final rawProjects = (json['projects'] as List?) ?? const [];
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
      adminExtras: {
        for (final e in json.entries)
          if (!_ownKeys.contains(e.key)) e.key: e.value,
      },
    );
  }
}
