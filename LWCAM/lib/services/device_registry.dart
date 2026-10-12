// ignore_for_file: avoid_print

// Checks and records which project a capture device belongs to in the
// shared PostgreSQL database (LWCAM). Called by auth_controller.dart when
// an operator enters a project; it never blocks when PostgreSQL is unreachable.
import 'package:get/get.dart';
import 'package:postgres/postgres.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/node_config.dart';
import '../models/project.dart';
import 'node_config_service.dart';
import 'pg_client.dart';

/// Cloud device registry (`devices` in LWCam_database_unified_*.sql): each
/// capture device (its operator ID) is bound to exactly ONE project via
/// `country_location_code` — the FK to projects IS the device→project lock.
///
/// Registration happens when a capture user enters a project
/// (AuthController.enterCaptureWithProject). A device already bound to a
/// DIFFERENT project blocks entry: only an admin can reassign it from the
/// Devices screen. When sync is off / unconfigured / PG is unreachable the
/// gate silently allows (same philosophy as the box-name uniqueness pull:
/// the registry lives in PG, no PG ⇒ purely local behavior).
///
/// Connections are short-lived (one per call, 5s connect timeout) — logins
/// are rare, so holding a pooled connection open buys nothing.
enum DeviceGate { allowed, blocked, skipped }

class DeviceGateResult {
  final DeviceGate gate;

  /// When blocked: the location code the device is currently bound to, and
  /// the owning project's name (best-effort; may be null if the project row
  /// vanished), for the dialog copy.
  final String? boundLocationCode;
  final String? boundProjectName;

  /// True when the decision came from the locally cached binding because the
  /// database could not be reached.
  final bool fromCache;

  const DeviceGateResult(this.gate,
      {this.boundLocationCode, this.boundProjectName, this.fromCache = false});
}

class DeviceRegistry {
  /// Pure lock rule, unit-testable: no existing binding or same code ⇒
  /// allowed; different code ⇒ blocked. Case-insensitive (codes are
  /// operator-typed free text).
  static DeviceGate evaluate(String? existingCode, String projectCode) {
    final existing = existingCode?.trim() ?? '';
    if (existing.isEmpty) return DeviceGate.allowed;
    return existing.toLowerCase() == projectCode.trim().toLowerCase()
        ? DeviceGate.allowed
        : DeviceGate.blocked;
  }

  static String _cacheKey(String deviceId) =>
      'device_gate_project.${deviceId.trim().toLowerCase()}';

  /// Remembers the device's project binding so capture keeps working (for
  /// that project only) while the database is unreachable.
  static Future<void> rememberBinding(String deviceId, String code) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey(deviceId), code.trim());
    } catch (_) {}
  }

  /// Decision when the database cannot be asked: the last known binding
  /// decides. Same project -> allowed; another project -> blocked (an
  /// offline PC must not quietly capture into a project the device is not
  /// bound to); never seen bound -> allowed (offline capture must work).
  static Future<DeviceGateResult> offlineDecision(
      String deviceId, String projectCode) async {
    String? cached;
    try {
      final prefs = await SharedPreferences.getInstance();
      cached = prefs.getString(_cacheKey(deviceId));
    } catch (_) {}
    if (cached == null || cached.trim().isEmpty) {
      print('ℹ️ Device registry: unreachable and no cached binding for '
          '$deviceId - gate skipped.');
      return const DeviceGateResult(DeviceGate.skipped);
    }
    if (evaluate(cached, projectCode) == DeviceGate.blocked) {
      return DeviceGateResult(DeviceGate.blocked,
          boundLocationCode: cached, fromCache: true);
    }
    return const DeviceGateResult(DeviceGate.allowed, fromCache: true);
  }

  Future<NodeConfig?> _syncConfig() async {
    if (!Get.isRegistered<NodeConfigService>()) return null;
    try {
      final config = await Get.find<NodeConfigService>().load();
      final host = config.pgHost?.trim() ?? '';
      if (!config.syncEnabled || host.isEmpty) return null;
      return config;
    } catch (e) {
      print('ℹ️ Device registry: node config unavailable ($e).');
      return null;
    }
  }

  Future<Connection?> _open(NodeConfig config) async {
    try {
      return await openPgConnection(
        host: config.pgHost!.trim(),
        port: config.pgPort,
        database: config.pgDatabase ?? '',
        user: config.pgUser ?? '',
        password: config.pgPassword ?? '',
        useSsl: config.pgUseSsl,
      );
    } catch (e) {
      print('ℹ️ Device registry: PG unreachable ($e) — gate skipped.');
      return null;
    }
  }

  /// The login-time gate + registration. Returns `skipped` (allow) whenever
  /// the registry can't participate: sync off/unconfigured, an admin-only
  /// account's empty device id, project without a location code, PG
  /// unreachable, or the project not yet in PG (FK would fail — the outbox
  /// drain will register the device organically via the sink's self-heal
  /// once the project lands).
  Future<DeviceGateResult> registerOrCheck({
    required String deviceId,
    required String username,
    required Project project,
  }) async {
    final devId = deviceId.trim();
    final code = project.countryLocationCode?.trim() ?? '';
    if (devId.isEmpty || code.isEmpty) {
      return const DeviceGateResult(DeviceGate.skipped);
    }
    final config = await _syncConfig();
    if (config == null) return const DeviceGateResult(DeviceGate.skipped);
    final conn = await _open(config);
    if (conn == null) return offlineDecision(devId, code);

    try {
      final existing = await conn.execute(
        Sql.named('SELECT d.country_location_code, p.project_name '
            'FROM devices d '
            'LEFT JOIN projects p ON p.country_location_code = d.country_location_code '
            'WHERE d.device_id = @device_id'),
        parameters: {'device_id': devId},
      );
      final existingCode =
          existing.isEmpty ? null : existing.first[0] as String?;
      if (existingCode != null && existingCode.trim().isNotEmpty) {
        await rememberBinding(devId, existingCode);
      }
      if (evaluate(existingCode, code) == DeviceGate.blocked) {
        return DeviceGateResult(
          DeviceGate.blocked,
          boundLocationCode: existingCode,
          boundProjectName: existing.first[1] as String?,
        );
      }

      // Allowed: register / refresh last-user + login time. The location
      // code is NEVER changed here — only an admin Reassign does that.
      final upserted = await conn.execute(
        Sql.named('INSERT INTO devices (device_id, country_location_code, '
            'user_id, login_at) '
            'SELECT @device_id, @code, u.id, now() '
            'FROM (SELECT 1) one '
            'LEFT JOIN users u ON u.user_id = @username '
            'WHERE EXISTS (SELECT 1 FROM projects '
            '  WHERE country_location_code = @code) '
            'ON CONFLICT (device_id) DO UPDATE SET '
            'user_id = EXCLUDED.user_id, login_at = now()'),
        parameters: {'device_id': devId, 'code': code, 'username': username},
      );
      if (upserted.affectedRows == 0) {
        // Project row not in PG yet (snapshot pending) — allow, sync heals.
        print('ℹ️ Device registry: project "$code" not pushed yet — '
            'registration deferred.');
      } else {
        await rememberBinding(devId, existingCode ?? code);
      }
      return const DeviceGateResult(DeviceGate.allowed);
    } catch (e) {
      print('ℹ️ Device registry check failed ($e) — using cached binding.');
      return offlineDecision(devId, code);
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  // listDevices/reassign were removed 2026-07-21 with LWCAM's Devices page:
  // viewing/reassigning devices is SuperAdmin-only, done from LWCam Admin's
  // Devices screen. LWCAM keeps only the capture-entry gate above.
}
