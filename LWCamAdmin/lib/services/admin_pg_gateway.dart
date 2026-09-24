// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:postgres/postgres.dart';

import '../models/app_user.dart';
import 'admin_pg_statements.dart' as st;
import 'pg_client.dart';

enum GatewayStatus { reachable, unreachable, schemaOutdated }

class GatewayProbeResult {
  final GatewayStatus status;
  const GatewayProbeResult(this.status);
}

/// The seam between [AdminStoreService] and wherever users/projects/
/// app_settings actually live — [AdminPgGateway] in production, a fake in
/// tests. Mirrors LWCAM's SyncSink pattern.
abstract class AdminGateway {
  Future<GatewayProbeResult> probe();

  /// Pushes [store]'s users/projects/user_projects/app_settings (and the
  /// roles registry) as one transaction of idempotent upserts, then applies
  /// [store]'s tombstones as soft-deletes. Throws on any failure — the
  /// caller must not assume partial progress.
  Future<void> pushSnapshot(UsersStore store);

  /// Rebuilds a [UsersStore] from PostgreSQL — the pull side of every
  /// reconcile.
  Future<UsersStore> pullStore();

  /// Changes the password of the role this gateway authenticates AS, using the
  /// password it currently holds. The caller MUST persist the new password
  /// straight away: once this returns, the saved config is the only remaining
  /// record of how to log in, and a station whose config still holds the old
  /// password is locked out of its own database.
  Future<void> rotatePassword(String newPassword);

  Future<void> close();
}

/// Production [AdminGateway]: one lazily-reconnecting PostgreSQL connection,
/// held for the lifetime of this instance.
class AdminPgGateway implements AdminGateway {
  final String host;
  final int port;
  final String database;
  final String user;
  final String password;
  final bool useSsl;

  Connection? _conn;

  AdminPgGateway({
    required this.host,
    required this.port,
    required this.database,
    required this.user,
    required this.password,
    required this.useSsl,
  });

  Future<Connection> _connect() async {
    final existing = _conn;
    if (existing != null && existing.isOpen) return existing;
    _conn = null;
    return _conn = await openPgConnection(
      host: host,
      port: port,
      database: database,
      user: user,
      password: password,
      useSsl: useSsl,
    );
  }

  /// Executes a [st.PgStatement], wrapping Dart string lists as text[] so
  /// `= ANY(@param)` works — same hardening as LWCAM's sink (the driver's
  /// untyped-list fallback happens to encode correctly today, but that's
  /// an implementation detail of postgres 3.5.x, not a contract).
  Future<Result> _exec(Session session, st.PgStatement stmt) {
    final params = <String, Object?>{
      for (final e in stmt.parameters.entries)
        e.key: e.value is List<String>
            ? TypedValue(Type.textArray, e.value as List<String>)
            : e.value,
    };
    return session.execute(Sql.named(stmt.sql), parameters: params);
  }

  @override
  Future<GatewayProbeResult> probe() async {
    Connection conn;
    try {
      conn = await _connect();
    } catch (_) {
      return const GatewayProbeResult(GatewayStatus.unreachable);
    }
    try {
      await conn.execute('SELECT 1');
      // Schema v2 columns — missing any of these means the team hasn't
      // applied the updated .sql file yet.
      await conn.execute('SELECT device_id, roles FROM users LIMIT 0');
      await conn.execute('SELECT project_key FROM projects LIMIT 0');
      await conn.execute('SELECT key, value FROM app_settings LIMIT 0');
      return const GatewayProbeResult(GatewayStatus.reachable);
    } on ServerException {
      // Undefined column/table — schema not yet updated.
      return const GatewayProbeResult(GatewayStatus.schemaOutdated);
    } catch (_) {
      return const GatewayProbeResult(GatewayStatus.unreachable);
    }
  }

  @override
  Future<void> pushSnapshot(UsersStore store) async {
    final conn = await _connect();
    await conn.runTx((session) async {
      await _exec(session, st.seedRolesSql([for (final r in UserRole.values) r.jsonValue]));

      // Tombstones FIRST, before any upsert: an offline delete-then-recreate
      // of the same username otherwise upserts the new account and then
      // soft-deletes it in the same transaction (the tombstone carries the
      // same natural key). Deleting first lets the recreate's upsert revive
      // the row afterwards. For projects it also frees the deleted row's
      // country_location_code before the new project's insert needs it.
      for (final username in store.deletedUsernames) {
        await _exec(session, st.userSoftDeleteSql(username));
      }
      for (final key in store.deletedProjectKeys) {
        await _exec(session, st.projectSoftDeleteSql(key));
      }

      for (final p in store.projects) {
        final code = p.countryLocationCode?.trim() ?? '';
        if (code.isEmpty) {
          print('ℹ️ Push skip: project "${p.name}" has no location code yet.');
          continue;
        }
        await _exec(
            session,
            st.projectUpsertSql(
              projectKey: p.key,
              projectId: p.projectId,
              projectName: p.name,
              countryLocationCode: code,
              startDateIso: p.startDate.toIso8601String(),
              hasData: p.hasData,
              templateJsonText: p.template == null ? null : jsonEncode(p.template!.toJson()),
            ));
      }

      for (final u in store.users) {
        await _exec(
            session,
            st.userUpsertSql(
              username: u.username,
              passwordHash: u.passwordHash,
              active: u.active,
              mustChangePassword: u.mustChangePassword,
              roles: u.rolesColumnValue,
              deviceId: u.deviceId,
              createdAtIso: u.createdAt?.toIso8601String(),
            ));
      }
      // Targeted password writes — the user upsert's DO UPDATE deliberately
      // never touches password/must_change_password (LWCAM owns those), so
      // explicit admin resets land through here instead. Runs after the
      // upserts so a brand-new/revived row exists to update.
      for (final username in store.pendingPasswordResets) {
        final user = store.findUser(username);
        if (user == null) continue; // reset then deleted — tombstone wins
        await _exec(
            session,
            st.userPasswordResetSql(
                username: user.username, passwordHash: user.passwordHash));
      }

      for (final u in store.users) {
        final creator = u.createdBy?.trim() ?? '';
        if (creator.isNotEmpty) {
          await _exec(session,
              st.userSetCreatedBySql(username: u.username, creatorUsername: creator));
        }
      }

      for (final u in store.users) {
        if (!u.roleProjectKeysKnown) continue;
        final pairs = <String>[];
        for (final entry in u.roleProjectKeys.entries) {
          final role = entry.key;
          for (final key in entry.value) {
            final project = store.findProjectByKey(key);
            if (project == null) continue; // ghost key — defensively skipped
            pairs.add('${project.projectId}|${role.jsonValue}');
            await _exec(
                session,
                st.userProjectInsertSql(
                  username: u.username,
                  projectId: project.projectId,
                  roleName: role.jsonValue,
                ));
          }
        }
        await _exec(session,
            st.userProjectsPruneSql(username: u.username, keepPairs: pairs));
      }

      final settings = store.settings;
      final settingsToPush = <String, String?>{
        'metadata_keying_enabled': settings.metadataKeyingEnabled ? 'true' : 'false',
        'shutter_keybind': settings.shutterKeybind,
        'shutter_method': settings.shutterMethod,
        'shutter_tap_x_percent': settings.shutterTapXPercent.toString(),
        'shutter_tap_y_percent': settings.shutterTapYPercent.toString(),
        if (settings.defaultTempPasswordHash != null)
          'default_temp_password_hash': settings.defaultTempPasswordHash,
        if (settings.superAdminPasswordHash != null)
          'superadmin_password_hash': settings.superAdminPasswordHash,
      };
      for (final entry in settingsToPush.entries) {
        await _exec(session, st.appSettingUpsertSql(key: entry.key, value: entry.value));
      }
    });
  }

  @override
  Future<UsersStore> pullStore() async {
    final conn = await _connect();
    final users = await _exec(conn, st.selectUsersSql());
    final projects = await _exec(conn, st.selectProjectsSql());
    final userProjects = await _exec(conn, st.selectUserProjectsSql());
    final appSettings = await _exec(conn, st.selectAppSettingsSql());
    return st.buildUsersStoreFromPgRows(
      users: [for (final r in users) r.toColumnMap()],
      projects: [for (final r in projects) r.toColumnMap()],
      userProjects: [for (final r in userProjects) r.toColumnMap()],
      appSettings: [for (final r in appSettings) r.toColumnMap()],
      now: DateTime.now(),
    );
  }

  @override
  Future<void> rotatePassword(String newPassword) async {
    final conn = await _connect();
    // Not in a transaction: ALTER ROLE is a utility statement, and wrapping it
    // buys nothing here - there is one statement and its failure is total.
    await conn.execute(
      st.alterRolePasswordSql(role: user, password: newPassword).sql,
    );
    // This gateway still holds the OLD password in its fields, so its next
    // reconnect would fail authentication. Drop the connection and let the
    // caller build a new gateway from the saved config.
    await close();
  }

  @override
  Future<void> close() async {
    final conn = _conn;
    _conn = null;
    if (conn != null) {
      try {
        await conn.close();
      } catch (_) {}
    }
  }
}
