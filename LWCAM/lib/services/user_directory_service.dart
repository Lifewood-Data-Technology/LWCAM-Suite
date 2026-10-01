// ignore_for_file: avoid_print

import 'package:get/get.dart';
import 'package:postgres/postgres.dart';

import 'node_config_service.dart';
import 'pg_client.dart';
import 'pg_statements.dart' as st;

/// LWCAM's PG write whitelist: the three capture-side events that must land
/// in PostgreSQL directly (never through the local-JSON write path LWCam
/// Admin owns) — a forced password change, the last-login stamp, and the
/// "a box was created" advisory flag. Mirrors DeviceRegistry's short-lived
/// connection pattern (logins/box-creates are rare; no pooled connection
/// worth holding open).
class UserDirectoryService {
  Future<Connection?> _open() async {
    if (!Get.isRegistered<NodeConfigService>()) return null;
    try {
      final config = await Get.find<NodeConfigService>().load();
      final host = config.pgHost?.trim() ?? '';
      // Gated on PG host presence only — NOT config.syncEnabled, which only
      // governs the capture-outbox drain. A forced password change must
      // still reach PG on a station with outbox sync off.
      if (host.isEmpty) return null;
      return await openPgConnection(
        host: host,
        port: config.pgPort,
        database: config.pgDatabase ?? '',
        user: config.pgUser ?? '',
        password: config.pgPassword ?? '',
        useSsl: config.pgUseSsl,
      );
    } catch (e) {
      print('ℹ️ User directory: PG unreachable ($e).');
      return null;
    }
  }

  /// A cheap reachability check — used to pre-gate a forced first-login
  /// password change (which has nowhere local to fall back to; PG IS the
  /// account record).
  Future<bool> isReachable() async {
    final conn = await _open();
    if (conn == null) return false;
    try {
      await conn.execute('SELECT 1');
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  /// Calls `lwcam_change_own_password`. Returns false when the database refuses
  /// (old password wrong / user inactive). Throws [StateError] when PG is
  /// unreachable — there is no local fallback (PostgreSQL IS the account
  /// record and the old plaintext is never stored), so the caller must tell
  /// the operator to reconnect.
  Future<bool> changePassword({
    required String username,
    required String oldPassword,
    required String bcryptHash,
  }) async {
    final conn = await _open();
    if (conn == null) {
      throw StateError('Connect to the database to change your password.');
    }
    try {
      final stmt = st.changeOwnPasswordSql(
        username: username,
        oldPassword: oldPassword,
        bcryptHash: bcryptHash,
      );
      final result = await conn.execute(Sql.named(stmt.sql), parameters: stmt.parameters);
      return result.isNotEmpty && result.first.first == true;
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  /// Best-effort — never throws. A missed stamp just means `last_login_at`
  /// lags until the next successful login.
  Future<void> recordLogin(String username) async {
    final conn = await _open();
    if (conn == null) return;
    try {
      final stmt = st.recordLoginSql(username);
      await conn.execute(Sql.named(stmt.sql), parameters: stmt.parameters);
    } catch (e) {
      print('ℹ️ recordLogin skipped for $username: $e');
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  /// Best-effort — never throws. Box creation is per-PC local and must not
  /// be gated on PG reachability.
  Future<void> markProjectHasData(String projectKey) async {
    final conn = await _open();
    if (conn == null) return;
    try {
      final stmt = st.markProjectHasDataSql(projectKey);
      await conn.execute(Sql.named(stmt.sql), parameters: stmt.parameters);
    } catch (e) {
      print('ℹ️ markProjectHasData skipped for $projectKey: $e');
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }
}
