// ignore_for_file: avoid_print

// Admin-side access to the devices table: lists capture devices and moves one
// to another project. The capture app (LWCAM) registers devices at login; this
// is where a SuperAdmin fixes a wrong binding. Each call opens its own short
// database connection.
import 'package:get/get.dart';
import 'package:postgres/postgres.dart';

import '../models/node_config.dart';
import 'node_config_service.dart';
import 'admin_login.dart';
import 'pg_client.dart';

/// Cloud device registry (`devices` in LWCam_database_unified_*.sql): each
/// capture device (its operator ID) is bound to exactly ONE project via
/// `country_location_code` — the FK to projects IS the device→project lock.
/// LWCAM owns the login-time gate/registration (DeviceRegistry.registerOrCheck
/// there); this app is the admin side — list devices and reassign one to a
/// different project.
///
/// Connections are short-lived (one per call, 5s connect timeout).
class DeviceRow {
  final String deviceId;
  final String countryLocationCode;
  final String? projectName;
  final String? lastUser;
  final DateTime? loginAt;

  const DeviceRow({
    required this.deviceId,
    required this.countryLocationCode,
    this.projectName,
    this.lastUser,
    this.loginAt,
  });
}

class DeviceRegistry {
  Future<NodeConfig?> _syncConfig() async {
    if (!Get.isRegistered<NodeConfigService>()) return null;
    try {
      final config = await Get.find<NodeConfigService>().load();
      final host = config.pgHost?.trim() ?? '';
      // Gates on THIS app's PG switch — NOT config.syncEnabled, which is
      // LWCAM's capture-outbox toggle (defaults false and has no UI here;
      // gating on it made Devices dead on every admin-only station).
      if (!config.pgConnectionEnabled || host.isEmpty) return null;
      return config;
    } catch (e) {
      print('ℹ️ Device registry: node config unavailable ($e).');
      return null;
    }
  }

  Future<Connection?> _open(NodeConfig config) async {
    final login = adminLoginFor(config);
    try {
      return await openPgConnection(
        host: config.pgHost!.trim(),
        port: config.pgPort,
        database: config.pgDatabase ?? '',
        user: login.user,
        password: login.password,
        useSsl: config.pgUseSsl,
      );
    } catch (e) {
      print('ℹ️ Device registry: PG unreachable ($e).');
      return null;
    }
  }

  /// All registered devices, for the Devices screen. Throws when sync is
  /// unconfigured or PG unreachable — the page shows the corresponding
  /// message.
  Future<List<DeviceRow>> listDevices() async {
    final config = await _syncConfig();
    if (config == null) {
      throw StateError('PostgreSQL is not configured (or the connection is '
          'disabled in Station Setup) — the device registry lives in '
          'PostgreSQL.');
    }
    final conn = await _open(config);
    if (conn == null) throw StateError('PostgreSQL is unreachable.');
    try {
      final result = await conn.execute(
          'SELECT d.device_id, d.country_location_code, p.project_name, '
          'u.user_id, d.login_at '
          'FROM devices d '
          'LEFT JOIN projects p ON p.country_location_code = d.country_location_code '
          'LEFT JOIN users u ON u.id = d.user_id '
          'ORDER BY d.device_id');
      return [
        for (final row in result)
          DeviceRow(
            deviceId: row[0] as String,
            countryLocationCode: row[1] as String,
            projectName: row[2] as String?,
            lastUser: row[3] as String?,
            loginAt: row[4] is DateTime
                ? row[4] as DateTime
                : DateTime.tryParse(row[4]?.toString() ?? ''),
          ),
      ];
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  /// Admin action: rebind [deviceId] to the project owning
  /// [countryLocationCode]. Throws on unreachable PG / unknown code (FK).
  Future<void> reassign({
    required String deviceId,
    required String countryLocationCode,
  }) async {
    final config = await _syncConfig();
    if (config == null) {
      throw StateError('PostgreSQL is not configured (or the connection is '
          'disabled in Station Setup).');
    }
    final conn = await _open(config);
    if (conn == null) throw StateError('PostgreSQL is unreachable.');
    try {
      await conn.execute(
        Sql.named('UPDATE devices SET country_location_code = @code '
            'WHERE device_id = @device_id'),
        parameters: {'code': countryLocationCode.trim(), 'device_id': deviceId},
      );
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }
}
