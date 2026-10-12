// Controller for the Projects page of LWCam Admin: create, update and delete
// projects and set their metadata templates. It holds no data of its own;
// every call goes to AdminStoreService, which handles database and offline
// storage. Edits are recorded under the signed-in admin's name.

import 'package:get/get.dart';

import '../auth/super_admin.dart';
import '../models/metadata_template.dart';
import '../models/project.dart';
import '../services/admin_store_service.dart';

/// Drives the Projects screen: full CRUD + metadata template management.
/// Delegates every mutation to [AdminStoreService] (PG-first, offline
/// fallback) — same shape as [UserManagementController].
class ProjectsController extends GetxController {
  AdminStoreService get _store => Get.find<AdminStoreService>();
  static const String _actor = kSuperAdminUsername;

  List<Project> get projects => _store.store.value?.projects ?? const [];

  Future<void> load() => _store.trySync();

  Future<Project> createProject({
    required String name,
    required String projectId,
    required String countryLocationCode,
    required DateTime startDate,
  }) =>
      _store.createProject(
        name: name,
        projectId: projectId,
        countryLocationCode: countryLocationCode,
        startDate: startDate,
        by: _actor,
      );

  Future<void> updateProject({
    required String key,
    String? name,
    String? projectId,
    String? countryLocationCode,
    DateTime? startDate,
  }) =>
      _store.updateProject(
        key: key,
        name: name,
        projectId: projectId,
        countryLocationCode: countryLocationCode,
        startDate: startDate,
        by: _actor,
      );

  Future<void> deleteProject(String key) => _store.deleteProject(key: key, by: _actor);

  Future<void> setProjectTemplate({required String key, required MetadataTemplate? template}) =>
      _store.setProjectTemplate(key: key, template: template, by: _actor);

  /// Number of users currently assigned to [project] — decides whether the
  /// delete confirmation needs the stronger typed-confirm form.
  int assignedUserCount(Project project) {
    final users = _store.store.value?.users ?? const [];
    return users.where((u) => u.projectKeys.contains(project.key)).length;
  }
}
