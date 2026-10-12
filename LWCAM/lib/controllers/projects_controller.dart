// ignore_for_file: avoid_print

// GetX controller behind projects_page.dart (LWCAM capture app).
// Loads the signed-in account's projects from the local users snapshot.
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../models/project.dart';
import '../services/users_store_service.dart';

/// Drives the Admin "Projects" screen — read-only in LWCAM. Project
/// create/edit/delete/template management now live in the separate LWCam
/// Admin app, which writes PostgreSQL directly; LWCAM only displays the
/// projects assigned to the signed-in admin from the local pulled snapshot.
class ProjectsController extends GetxController {
  final AuthController _auth = Get.find<AuthController>();

  final projects = <Project>[].obs;
  final source = UsersStoreSource.none.obs;
  final isLoading = false.obs;
  final errorMessage = RxnString();

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    isLoading.value = true;
    try {
      await _auth.reloadUsersStore();
      final store = _auth.usersStore;
      if (store == null || store.lastSource == UsersStoreSource.none) {
        source.value = UsersStoreSource.none;
        projects.value = const [];
        errorMessage.value = 'No users snapshot yet — run LWCam Admin station setup.';
        return;
      }
      source.value = store.lastSource;
      // Every role's grants, not just admin's: Projects is the one way in.
      projects.value = _auth.visibleProjects;
      errorMessage.value = null;
    } catch (e) {
      errorMessage.value = 'Could not load projects: $e';
    } finally {
      isLoading.value = false;
    }
  }
}
