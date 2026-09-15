/// SQL statement builders for the cloud schema in
/// `LWCam Workflow & SQL update/LWCam_database_20260720.sql`. Pure Dart — no
/// postgres import — so every statement's SQL and parameters are
/// unit-testable without a connection. AdminPgGateway executes these.
///
/// This app owns users/projects/user_projects/roles/app_settings — the
/// tables LWCAM only pulls read-only. LWCAM's own `pg_statements.dart` owns
/// capture_boxes/capture_folders/capture_images, which this app never
/// touches.
///
/// Every upsert here conflicts on the entity's natural key: users(user_id),
/// projects(project_key) — NOT project_id, which is a human-editable label
/// that survives renames — app_settings(key). Every upsert also guards its
/// DO UPDATE with IS DISTINCT FROM so an unchanged push writes nothing (and
/// never fires the PG updated_at trigger) — this keeps a 30s reconcile tick
/// against an already-synced store nearly free.
library;

import 'dart:convert';

import '../models/app_user.dart';
import '../models/metadata_template.dart';
import '../models/project.dart';

class PgStatement {
  final String sql;
  final Map<String, Object?> parameters;
  const PgStatement(this.sql, this.parameters);
}

/// `ALTER ROLE ... PASSWORD ...` is a utility statement, so the driver's bind
/// parameters do not apply to it and both the role name and the password have to
/// be quoted into the SQL by hand. That statement runs with superuser rights, so
/// this quoting is the only thing standing between a typed password and
/// arbitrary SQL - which is why it is a tested builder here rather than string
/// interpolation at the call site.
///
/// Doubling the quote character is the whole rule while
/// standard_conforming_strings is on, and it has been on by default since
/// PostgreSQL 9.1. A backslash would only matter on a server that turned it back
/// off; rather than depend on a server setting being what we assume, the builder
/// refuses backslashes outright, along with control characters no password box
/// should be producing.
PgStatement alterRolePasswordSql({
  required String role,
  required String password,
}) {
  if (role.trim().isEmpty) {
    throw ArgumentError('No PostgreSQL role to change the password for.');
  }
  if (password.isEmpty) {
    throw ArgumentError('The new password cannot be empty.');
  }
  // 0x5c is the backslash, anything below 0x20 is a control character.
  // Checked by code unit rather than a pattern: a regex for this would need
  // escaped backslashes, which is the very thing being guarded against.
  if (password.codeUnits.any((c) => c < 0x20 || c == 0x5c)) {
    throw ArgumentError(
      'The new password cannot contain a backslash or control characters.',
    );
  }
  final quotedRole = '"${role.replaceAll('"', '""')}"';
  final quotedPassword = "'${password.replaceAll("'", "''")}'";
  return PgStatement(
    'ALTER ROLE $quotedRole PASSWORD $quotedPassword',
    const {},
  );
}

/// ISO-8601 string of [value] if it parses as a date/time, else null.
/// Archive dates are sometimes just a year ("1914") or year-month
/// ("1914-06"); those coerce to Jan 1 / the 1st rather than being lost.
String? tsOrNull(Object? value) {
  final s = value?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  final direct = DateTime.tryParse(s);
  if (direct != null) return direct.toIso8601String();
  final yearOnly = RegExp(r'^(\d{4})(?:-(\d{1,2}))?$').firstMatch(s);
  if (yearOnly != null) {
    final year = int.parse(yearOnly.group(1)!);
    final month = int.tryParse(yearOnly.group(2) ?? '') ?? 1;
    if (month >= 1 && month <= 12) {
      return DateTime(year, month).toIso8601String();
    }
  }
  return null;
}

// ── Push: roles / users / projects / user_projects ─────────────────────────

PgStatement seedRolesSql(List<String> roleNames) => PgStatement(
      'INSERT INTO roles (role_name) VALUES '
      '${List.generate(roleNames.length, (i) => '(@r$i)').join(', ')} '
      'ON CONFLICT (role_name) DO NOTHING',
      {for (var i = 0; i < roleNames.length; i++) 'r$i': roleNames[i]},
    );

/// [roles] is the account's global roles (comma-joined into `users.roles`).
/// LWCAM-owned columns are left OUT of the conflict target's DO UPDATE
/// entirely: `last_login_at` (LWCAM's recordLogin stamps it) AND
/// `password`/`must_change_password` (LWCAM's changeOwnPassword writes
/// them) — a whole-store push carrying a snapshot taken before a capture
/// user changed their own password must never regress that change. An
/// admin-intended password write (reset, or a recreate reviving a deleted
/// username) goes through the targeted [userPasswordResetSql] instead,
/// driven by the store's pendingPasswordResets queue. INSERT still
/// supplies password/must_change_password for genuinely new rows.
/// Revives a soft-deleted row (re-creating a deleted username).
///
/// `roles` is never overwritten with an empty string: a build that cannot parse
/// a role it finds in PG would otherwise revoke it on the next whole-store push.
/// [AppUser.extraRoles] already preserves unknown roles, so an empty value here
/// means "this snapshot knows of no roles at all" — never an intentional clear.
/// Deliberately mirrored into the WHERE guard so such a push stays a true no-op
/// instead of firing an UPDATE that would also revive a soft-deleted row.
PgStatement userUpsertSql({
  required String username,
  required String passwordHash,
  required bool active,
  required bool mustChangePassword,
  required String roles,
  String? deviceId,
  String? createdAtIso,
}) =>
    PgStatement(
      'INSERT INTO users (user_id, password, active, must_change_password, '
      'roles, device_id, created_at) '
      'VALUES (@user_id, @password, @active, @must_change_password, @roles, '
      '@device_id, COALESCE(CAST(@created_at AS timestamptz), clock_timestamp())) '
      'ON CONFLICT (user_id) DO UPDATE SET '
      'active = EXCLUDED.active, '
      "roles = CASE WHEN EXCLUDED.roles = '' THEN users.roles "
      'ELSE EXCLUDED.roles END, '
      'device_id = EXCLUDED.device_id, '
      'is_deleted = FALSE, deleted_at = NULL '
      'WHERE users.active IS DISTINCT FROM EXCLUDED.active '
      "OR users.roles IS DISTINCT FROM (CASE WHEN EXCLUDED.roles = '' "
      'THEN users.roles ELSE EXCLUDED.roles END) '
      'OR users.device_id IS DISTINCT FROM EXCLUDED.device_id '
      'OR users.is_deleted',
      {
        'user_id': username,
        'password': passwordHash,
        'active': active,
        'must_change_password': mustChangePassword,
        'roles': roles,
        'device_id': (deviceId == null || deviceId.trim().isEmpty) ? null : deviceId.trim(),
        'created_at': tsOrNull(createdAtIso),
      },
    );

/// The one way an existing PG user row's password changes from THIS app:
/// an explicit admin reset (or createUser reviving a deleted username),
/// queued per-username in the store's pendingPasswordResets. Always forces
/// a change on next login — this app only ever sets the shared default
/// temp password, never a user-chosen one.
PgStatement userPasswordResetSql({
  required String username,
  required String passwordHash,
}) =>
    PgStatement(
      'UPDATE users SET password = @password, must_change_password = TRUE '
      'WHERE user_id = @user_id',
      {'user_id': username, 'password': passwordHash},
    );

/// Second pass: fill created_by once both rows exist. Only where still NULL —
/// a creator that isn't a store user (e.g. SuperAdmin) simply stays NULL.
PgStatement userSetCreatedBySql({
  required String username,
  required String creatorUsername,
}) =>
    PgStatement(
      'UPDATE users SET created_by = '
      '(SELECT id FROM users WHERE user_id = @creator) '
      'WHERE user_id = @user_id AND created_by IS NULL '
      'AND EXISTS (SELECT 1 FROM users WHERE user_id = @creator)',
      {'user_id': username, 'creator': creatorUsername},
    );

/// Tombstone: a user deleted while this app was offline. `active = FALSE`
/// alongside `is_deleted = TRUE` so any code that only checks `active`
/// (never expected once `is_deleted` is filtered, but cheap insurance)
/// still behaves.
PgStatement userSoftDeleteSql(String username) => PgStatement(
      'UPDATE users SET is_deleted = TRUE, deleted_at = now(), active = FALSE '
      'WHERE user_id = @user_id AND is_deleted = FALSE',
      {'user_id': username},
    );

/// Conflicts on `project_key` (the stable client identity), NOT `project_id`
/// — project_id is human-editable and must be free to rename without
/// minting a duplicate cloud row. Revives a soft-deleted row.
PgStatement projectUpsertSql({
  required String projectKey,
  required String projectId,
  required String projectName,
  required String countryLocationCode,
  String? startDateIso,
  required bool hasData,
  String? templateJsonText,
}) =>
    PgStatement(
      'INSERT INTO projects (project_key, project_id, project_name, '
      'country_location_code, start_date, has_data, template) '
      'VALUES (@project_key, @project_id, @project_name, '
      '@country_location_code, CAST(@start_date AS timestamptz), @has_data, '
      'CAST(@template AS jsonb)) '
      'ON CONFLICT (project_key) DO UPDATE SET '
      'project_id = EXCLUDED.project_id, project_name = EXCLUDED.project_name, '
      'country_location_code = EXCLUDED.country_location_code, '
      'start_date = EXCLUDED.start_date, '
      // has_data is monotonic false→true and LWCAM sets it directly
      // (markProjectHasData) — OR instead of overwrite, so a stale
      // offline snapshot can never flip it back to false.
      'has_data = projects.has_data OR EXCLUDED.has_data, '
      'template = EXCLUDED.template, is_deleted = FALSE, deleted_at = NULL '
      'WHERE projects.project_id IS DISTINCT FROM EXCLUDED.project_id '
      'OR projects.project_name IS DISTINCT FROM EXCLUDED.project_name '
      'OR projects.country_location_code IS DISTINCT FROM EXCLUDED.country_location_code '
      'OR projects.start_date IS DISTINCT FROM EXCLUDED.start_date '
      'OR (NOT projects.has_data AND EXCLUDED.has_data) '
      'OR projects.template IS DISTINCT FROM EXCLUDED.template '
      'OR projects.is_deleted',
      {
        'project_key': projectKey,
        'project_id': projectId,
        'project_name': projectName,
        'country_location_code': countryLocationCode,
        'start_date': tsOrNull(startDateIso),
        'has_data': hasData,
        'template': templateJsonText,
      },
    );

/// Tombstone: a project deleted while this app was offline. Rewrites
/// country_location_code to `~deleted~id` — that column is a FULL unique
/// FK target (devices reference it; project_id/project_name only have
/// partial live-rows-only indexes), so the real code must be freed here or
/// a new project could never reuse it. The devices FK cascades the rewrite,
/// deliberately leaving any still-bound device blocked until reassigned.
PgStatement projectSoftDeleteSql(String projectKey) => PgStatement(
      'UPDATE projects SET is_deleted = TRUE, deleted_at = now(), '
      "country_location_code = '~deleted~' || id "
      'WHERE project_key = @project_key AND is_deleted = FALSE',
      {'project_key': projectKey},
    );

PgStatement userProjectInsertSql({
  required String username,
  required String projectId,
  required String roleName,
}) =>
    PgStatement(
      'INSERT INTO user_projects (user_id, project_id, role_id) '
      'SELECT u.id, p.id, r.id FROM users u, projects p, roles r '
      'WHERE u.user_id = @user_id AND p.project_id = @project_id '
      'AND r.role_name = @role_name '
      'ON CONFLICT DO NOTHING',
      {'user_id': username, 'project_id': projectId, 'role_name': roleName},
    );

/// Removes assignments the store no longer holds for [username]. [keepPairs]
/// is the current set encoded as `<project_id>|<role_name>` strings — an
/// empty list clears every assignment for the user.
PgStatement userProjectsPruneSql({
  required String username,
  required List<String> keepPairs,
}) =>
    PgStatement(
      'DELETE FROM user_projects up USING users u, projects p, roles r '
      'WHERE up.user_id = u.id AND up.project_id = p.id AND up.role_id = r.id '
      "AND u.user_id = @user_id "
      "AND NOT (p.project_id || '|' || r.role_name = ANY(@keep_pairs))",
      {'user_id': username, 'keep_pairs': keepPairs},
    );

/// One row per shared setting. `value` is always sent as text (bools/numbers
/// stringified by the caller) — app_settings.value is VARCHAR.
PgStatement appSettingUpsertSql({required String key, required String? value}) =>
    PgStatement(
      'INSERT INTO app_settings (key, value) VALUES (@key, @value) '
      'ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value '
      'WHERE app_settings.value IS DISTINCT FROM EXCLUDED.value',
      {'key': key, 'value': value},
    );

// ── Pull: rebuild the local snapshot from PG ────────────────────────────────

PgStatement selectUsersSql() => const PgStatement(
      'SELECT u.user_id, u.password, u.active, u.must_change_password, '
      'u.roles, u.device_id, u.created_at, u.last_login_at, '
      'c.user_id AS created_by '
      'FROM users u LEFT JOIN users c ON c.id = u.created_by '
      'WHERE u.is_deleted = FALSE',
      {},
    );

PgStatement selectProjectsSql() => const PgStatement(
      'SELECT project_key, project_id, project_name, country_location_code, '
      "start_date, has_data, template::text, created_at "
      'FROM projects WHERE is_deleted = FALSE',
      {},
    );

PgStatement selectUserProjectsSql() => const PgStatement(
      'SELECT u.user_id, p.project_key, r.role_name FROM user_projects up '
      'JOIN users u ON u.id = up.user_id '
      'JOIN projects p ON p.id = up.project_id '
      'JOIN roles r ON r.id = up.role_id '
      'WHERE u.is_deleted = FALSE AND p.is_deleted = FALSE',
      {},
    );

PgStatement selectAppSettingsSql() =>
    const PgStatement('SELECT key, value FROM app_settings', {});

/// Rebuilds a [UsersStore] from the 4 pull SELECTs' decoded rows (each a
/// `Map<String, Object?>` — e.g. via the postgres package's
/// `Result.toColumnMap()`). Pure and unit-testable without a connection.
/// `updatedAt` is stamped as the pull time (there is no meaningful "last PG
/// write" timestamp to carry, and this is exactly what the LWCAM login page
/// shows as "last synced").
UsersStore buildUsersStoreFromPgRows({
  required List<Map<String, Object?>> users,
  required List<Map<String, Object?>> projects,
  required List<Map<String, Object?>> userProjects,
  required List<Map<String, Object?>> appSettings,
  required DateTime now,
}) {
  // Account roles are global, but each project grant belongs to one role.
  final projectKeysByUser = <String, Set<String>>{};
  final roleProjectKeysByUser = <String, Map<UserRole, Set<String>>>{};
  for (final row in userProjects) {
    final username = row['user_id']?.toString() ?? '';
    final projectKey = row['project_key']?.toString() ?? '';
    final role = UserRole.fromJson(row['role_name']);
    if (username.isEmpty || projectKey.isEmpty || role == null) continue;
    (projectKeysByUser[username] ??= {}).add(projectKey);
    (roleProjectKeysByUser[username] ??= {})[role] ??= <String>{};
    roleProjectKeysByUser[username]![role]!.add(projectKey);
  }

  final appUsers = [
    for (final row in users)
      AppUser(
        username: row['user_id']?.toString() ?? '',
        passwordHash: row['password']?.toString() ?? '',
        roles: _rolesFromColumn(row['roles']),
        extraRoles: _extraRolesFromColumn(row['roles']),
        deviceId: _nullIfEmpty(row['device_id']?.toString()),
        active: row['active'] as bool? ?? true,
        mustChangePassword: row['must_change_password'] as bool? ?? false,
        createdAt: _asDateTime(row['created_at']),
        createdBy: row['created_by']?.toString(),
        lastLoginAt: _asDateTime(row['last_login_at']),
        projectKeys: projectKeysByUser[row['user_id']?.toString()] ?? const {},
        roleProjectKeys: roleProjectKeysByUser[row['user_id']?.toString()] ?? const {},
      ),
  ];

  final projectModels = [
    for (final row in projects)
      Project(
        key: row['project_key']?.toString() ?? '',
        projectId: row['project_id']?.toString() ?? '',
        name: row['project_name']?.toString() ?? '',
        countryLocationCode: row['country_location_code']?.toString(),
        startDate: _asDateTime(row['start_date']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        hasData: row['has_data'] as bool? ?? false,
        createdAt: _asDateTime(row['created_at']),
        template: _templateFromColumn(row['template']),
      ),
  ];

  final settingsByKey = {
    for (final row in appSettings) row['key']?.toString() ?? '': row['value']?.toString(),
  };
  final settings = SharedAppSettings(
    metadataKeyingEnabled: settingsByKey['metadata_keying_enabled'] == 'true',
    defaultTempPasswordHash: settingsByKey['default_temp_password_hash'],
    superAdminPasswordHash: settingsByKey['superadmin_password_hash'],
    shutterKeybind: kShutterKeybinds.contains(settingsByKey['shutter_keybind'])
        ? settingsByKey['shutter_keybind']!
        : 'Space',
    shutterMethod: kShutterMethods.contains(settingsByKey['shutter_method'])
        ? settingsByKey['shutter_method']!
        : 'tap',
    shutterTapXPercent: double.tryParse(settingsByKey['shutter_tap_x_percent'] ?? '') ?? 50,
    shutterTapYPercent: double.tryParse(settingsByKey['shutter_tap_y_percent'] ?? '') ?? 90,
  );

  return UsersStore(
    updatedAt: now,
    updatedBy: 'pg-pull',
    settings: settings,
    users: appUsers,
    projects: projectModels,
  );
}

/// `users.roles` is a comma-joined string ('admin', 'capture', 'qc', or any
/// combination); an empty segment is dropped, not fatal.
Set<UserRole> _rolesFromColumn(Object? value) {
  final s = value?.toString() ?? '';
  if (s.trim().isEmpty) return const {};
  return s.split(',').map(UserRole.fromJson).whereType<UserRole>().toSet();
}

/// Segments of `users.roles` that map to no [UserRole] — a role owned by another
/// module in the suite. Kept so the push can write them back untouched; dropping
/// them here is what silently revoked another app's role before.
Set<String> _extraRolesFromColumn(Object? value) {
  final s = value?.toString() ?? '';
  if (s.trim().isEmpty) return const {};
  return s
      .split(',')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty && UserRole.fromJson(segment) == null)
      .toSet();
}

String? _nullIfEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

DateTime? _asDateTime(Object? value) {
  if (value is DateTime) return value;
  return DateTime.tryParse(value?.toString() ?? '');
}

/// `projects.template` (jsonb) may arrive as an already-decoded [Map] or as
/// its raw JSON [String], depending on the driver path — handle both.
MetadataTemplate? _templateFromColumn(Object? value) {
  if (value == null) return null;
  if (value is Map) return MetadataTemplate.fromJson(value.cast<String, Object?>());
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  try {
    final decoded = jsonDecode(s);
    return decoded is Map ? MetadataTemplate.fromJson(decoded.cast<String, Object?>()) : null;
  } catch (_) {
    return null;
  }
}
