import 'package:get/get.dart';

import '../auth/super_admin.dart';
import '../models/app_user.dart';
import '../services/admin_store_service.dart';

/// Metadata keying, remote shutter, default temp password, and the
/// SuperAdmin password override — everything in `app_settings`.
class AppSettingsController extends GetxController {
  AdminStoreService get _store => Get.find<AdminStoreService>();
  static const String _actor = kSuperAdminUsername;

  SharedAppSettings get settings => _store.store.value?.settings ?? const SharedAppSettings();

  Future<void> setMetadataKeyingEnabled(bool enabled) =>
      _store.setMetadataKeyingEnabled(enabled: enabled, by: _actor);

  Future<void> setShutterConfig({
    String? keybind,
    String? method,
    double? tapXPercent,
    double? tapYPercent,
  }) =>
      _store.setShutterConfig(
        keybind: keybind,
        method: method,
        tapXPercent: tapXPercent,
        tapYPercent: tapYPercent,
        by: _actor,
      );

  Future<void> setDefaultTempPassword(String plaintext) =>
      _store.setDefaultTempPassword(plaintext: plaintext, by: _actor);

  Future<void> setSuperAdminPassword(String plaintext) =>
      _store.setSuperAdminPassword(plaintext: plaintext, by: _actor);
}
