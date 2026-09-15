// ignore_for_file: avoid_print

import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/node_config.dart';
import 'lwip_service.dart';
import 'processing_report_service.dart';
import 'sync_bootstrap.dart';
import 'sync_service.dart';

/// Applies the image-processing phase of a [NodeConfig] to the running app:
/// starts/stops the REPORT agent to match `processingEnabled`. Mirrors
/// SyncBootstrap. Called once at startup (main.dart) and at login.
///
/// LWIP itself is no longer this app's child — LWCam Admin registers it to run at
/// logon, so processing continues when nobody has LWCAM open.
class ProcessingBootstrap {
  static Future<void> apply(NodeConfig config) async {
    if (!config.processingEnabled) {
      if (Get.isRegistered<ProcessingReportService>()) {
        await Get.delete<ProcessingReportService>(force: true);
      }
      return;
    }

    // Which per-device DB the ledger + outbox rows live in. A co-located
    // capture+processing PC uses its real capture device id (so the local
    // folder-column mirror lands in the same DB the capture rows are in); a
    // processing-only PC never logged in, so a fixed pseudo id — the payload's
    // NATURAL keys, not this id, drive all PG resolution.
    var deviceId = await AuthController.readPersistedSyncDeviceId();
    if (deviceId.isEmpty) deviceId = 'PROCESSING';

    // Re-binding to a different device id (login on a shared PC — this apply
    // also runs at login now, mirroring SyncBootstrap)? Any reports still
    // pending under the old id would strand: the drain only reads the current
    // device's outbox (2026-07-29 incident, handover §7.8).
    if (Get.isRegistered<ProcessingReportService>()) {
      final previous = Get.find<ProcessingReportService>().deviceId;
      if (previous != deviceId) {
        try {
          final moved = await UploadStatsDB()
              .migratePendingProcessingOutbox(from: previous, to: deviceId);
          if (moved > 0) {
            print('🖼️ Migrated $moved pending processing report(s) '
                'from $previous to $deviceId');
          }
        } catch (e) {
          print('⚠️ Pending processing report migration failed: $e');
        }
      }
    }

    // Make sure the outbox drain runs on this PC so reports reach the cloud
    // (only when sync is on). On a same-PC station main.dart/login already
    // started it for the real device; this covers the processing-only PC
    // whose empty persisted id made main.dart's SyncBootstrap a no-op.
    if (config.syncEnabled && !Get.isRegistered<SyncService>()) {
      await SyncBootstrap.apply(config, deviceId: deviceId);
    }

    // LWIP is NOT started here. It runs on its own from the logon entry LWCam
    // Admin registers (lwip_autostart_service.dart), because it must keep
    // processing whether or not an operator has LWCAM open. Starting it here too
    // would just lose a race for LWIP's orchestrator lock. This app only reports
    // what LWIP finished.
    final stateFile = await LwipService.generatedStateFilePath();
    if (Get.isRegistered<ProcessingReportService>()) {
      await Get.delete<ProcessingReportService>(force: true);
    }
    Get.put(
      ProcessingReportService(
        db: UploadStatsDB(),
        deviceId: deviceId,
        stateFilePath: stateFile,
      ),
      permanent: true,
    );
  }
}
