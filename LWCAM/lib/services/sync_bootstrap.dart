import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../auth/auth_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/app_user.dart';
import '../models/node_config.dart';
import 'app_version.dart';
import 'pg_sync_sink.dart';
import 'sync_service.dart';
import 'transfer_queue_service.dart' show TransferQueueService, transferWaitBacklog;
import 'users_store_service.dart';

/// Applies a [NodeConfig] to the running app: starts/stops the background
/// [SyncService] to match. The outbox hooks in upload_stats_db.dart record
/// whatever the switch says; syncEnabled only decides whether they are
/// drained. Called from three places: once at app startup (main.dart, before
/// any device id is known — draining just can't start yet), once after a
/// successful login (auth_controller.dart, once the operator's device id —
/// the per-device SQLite file's key — is known), and whenever an admin
/// saves the Settings "Sync" section.
///
/// One sync shape only: enabled ⇒ drain the outbox to the configured
/// PostgreSQL via [PgSyncSink]. LAN or cloud PostgreSQL is the same direct
/// connection — the earlier role/cloud-forwarding tier was removed
/// 2026-07-18 (see CHANGELOG).
class SyncBootstrap {
  static Future<void> apply(NodeConfig config, {required String deviceId}) async {
    if (Get.isRegistered<SyncService>()) {
      final existing = Get.find<SyncService>();
      existing.stop();
      await Get.delete<SyncService>(force: true);
    }

    // The users/projects/settings pull now runs permanently whenever a PG
    // host is configured — it is no longer tied to the syncEnabled switch,
    // which only governs the capture-outbox drain. drainEnabled carries that
    // switch (plus a known deviceId, needed to find this device's outbox)
    // into the service.
    final host = config.pgHost?.trim() ?? '';
    if (host.isEmpty) return;

    final sink = PgSyncSink(
      host: host,
      port: config.pgPort,
      database: config.pgDatabase ?? '',
      user: config.pgUser ?? '',
      password: config.pgPassword ?? '',
      useSsl: config.pgUseSsl,
    );
    final service = SyncService(
      db: UploadStatsDB(),
      sink: sink,
      cloudCaptureKeys: sink.fetchCaptureKeys,
      deviceId: deviceId,
      drainEnabled: config.syncEnabled && deviceId.isNotEmpty,
      tickInterval: Duration(seconds: config.syncIntervalSeconds),
      heartbeatEnabled: true,
      extraBacklog: () => Get.isRegistered<TransferQueueService>()
          ? Get.find<TransferQueueService>().heartbeatBacklog()
          : transferWaitBacklog(const [], DateTime.now()),
      version: appVersion,
      applyPulledStore: (store) => _applyPulledStore(store, config),
      activeProjectKey: () => Get.isRegistered<AuthController>()
          ? Get.find<AuthController>().activeProject.value?.key
          : null,
    );
    Get.put(service, permanent: true);
    service.start();
  }

  /// Applies a freshly pulled [store] to the local snapshot. Prefers the
  /// live `AuthController.usersStore` instance (keeps its in-memory copy in
  /// sync too); falls back to writing the file directly when no
  /// `AuthController` is registered yet — the pre-login startup tick (see
  /// main.dart, which resumes sync for the last logged-in device before any
  /// login has happened) has no instance to swap into.
  static Future<void> _applyPulledStore(UsersStore store, NodeConfig config) async {
    if (Get.isRegistered<AuthController>()) {
      final svc = Get.find<AuthController>().usersStore;
      if (svc != null) {
        await svc.applySnapshot(store);
        return;
      }
    }
    final storeDir = config.usersStorePath;
    final path = p.join(
      (storeDir == null || storeDir.trim().isEmpty)
          ? await UploadStatsDB().getBaseFolder()
          : storeDir.trim(),
      UsersStoreService.usersFileName,
    );
    await UsersStoreService.writeSnapshotFile(store, path);
  }
}
