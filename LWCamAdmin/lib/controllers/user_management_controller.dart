import 'package:get/get.dart';

import '../auth/super_admin.dart';
import '../models/app_user.dart';
import '../models/project.dart';
import '../services/admin_store_service.dart';

/// Drives the User Management screen. Every mutation delegates straight to
/// [AdminStoreService] — online or offline, PG-first-with-fallback is
/// AdminStoreService's job, not this controller's. There is no
/// "who can grant which project" restriction here (unlike LWCAM's old
/// version): this app has exactly one operator, SuperAdmin, who could
/// already see and grant every project.
class UserManagementController extends GetxController {
  AdminStoreService get _store => Get.find<AdminStoreService>();
  static const String _actor = kSuperAdminUsername;

  List<AppUser> get users => _store.store.value?.users ?? const [];
  List<Project> get projects => _store.store.value?.projects ?? const [];
  bool get hasDefaultTempPassword => _store.store.value?.settings.defaultTempPasswordHash != null;

  String projectLabel(AppUser u) {
    if (u.projectKeys.isEmpty) return 'No projects';
    final labels = <String>[];
    for (final role in u.roles) {
      final names = projects
          .where((p) => u.projectKeysFor(role).contains(p.key))
          .map((p) => '${p.name} (${p.projectId})')
          .toList();
      if (names.isNotEmpty) labels.add('${role.name}: ${names.join(', ')}');
    }
    return labels.isEmpty ? 'No projects' : labels.join(' · ');
  }

  Future<void> load() => _store.trySync();

  Future<void> createUser({
    required String username,
    required Set<UserRole> roles,
    String? deviceId,
    Map<UserRole, Set<String>> roleProjectKeys = const {},
  }) =>
      _store.createUser(
          username: username, roles: roles, deviceId: deviceId,
          roleProjectKeys: roleProjectKeys, by: _actor);

  Future<void> updateRoles({
    required String username,
    required Set<UserRole> roles,
    String? deviceId,
    Map<UserRole, Set<String>>? roleProjectKeys,
  }) =>
      _store.setRoles(
          username: username, roles: roles, deviceId: deviceId,
          roleProjectKeys: roleProjectKeys, by: _actor);

  Future<void> resetPassword(String username) =>
      _store.resetPassword(username: username, by: _actor);

  Future<void> setActive(String username, bool active) =>
      _store.setActive(username: username, active: active, by: _actor);

  Future<void> deleteUser(String username) => _store.deleteUser(username: username, by: _actor);
}
