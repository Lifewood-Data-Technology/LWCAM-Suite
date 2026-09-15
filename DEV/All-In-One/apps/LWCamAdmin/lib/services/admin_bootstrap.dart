import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../models/node_config.dart';
import 'admin_pg_gateway.dart';
import 'admin_store_service.dart';

/// Default local folder for both `lwcam_node_config.json` and
/// `lwcam_users.json` — same path LWCAM resolves, since Station Setup here
/// provisions the very file LWCAM's SyncBootstrap reads.
String defaultLwcamDbsDir() {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? 'C:\\';
  return p.join(home, 'LWCAM_DBs');
}

/// (Re)builds [AdminStoreService] from [config] and registers it, replacing
/// any previous instance — mirrors LWCAM's `SyncBootstrap.apply` so
/// Station Setup can apply a changed PG connection without an app restart.
class AdminBootstrap {
  /// Bumped on every [apply]. Long-lived widgets that bind Rx fields of the
  /// store service (HomePage's status bar) read this inside their Obx: the
  /// old instance's Rx go silent forever once it's deleted, so without this
  /// tick they would freeze on the pre-save state.
  static final generation = 0.obs;

  static Future<void> apply(NodeConfig config) async {
    if (Get.isRegistered<AdminStoreService>()) {
      await Get.delete<AdminStoreService>(force: true);
    }
    final gateway = AdminPgGateway(
      host: config.pgHost?.trim() ?? '',
      port: config.pgPort,
      database: config.pgDatabase ?? '',
      user: config.pgUser ?? '',
      password: config.pgPassword ?? '',
      useSsl: config.pgUseSsl,
    );
    final service = AdminStoreService(
      gateway: gateway,
      getStoreDirPath: () => config.usersStorePath ?? defaultLwcamDbsDir(),
      pgConnectionEnabled: config.pgConnectionEnabled,
    );
    Get.put(service, permanent: true);
    generation.value++;
    await service.init();
  }
}
