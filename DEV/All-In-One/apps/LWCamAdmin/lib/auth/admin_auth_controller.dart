import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'super_admin.dart';
import '../services/admin_store_service.dart';
import '../services/password_hasher.dart';
import '../services/snackbar_service.dart';

/// SuperAdmin-only login — the ONE account this app accepts. Verifies
/// against PostgreSQL's override hash (via a best-effort bounded sync, so a
/// hash changed on another PC takes effect promptly) when reachable, else
/// the local snapshot's copy, else the factory hash compiled into
/// super_admin.dart — this is exactly what lets a completely fresh PC (no
/// PG, no local snapshot yet) still reach Station Setup.
class AdminAuthController extends GetxController {
  final passwordController = TextEditingController();
  final isLoading = false.obs;
  final isAuthenticated = false.obs;

  ColorScheme get _cs => Get.theme.colorScheme;

  Future<void> login() async {
    final password = passwordController.text;
    if (password.isEmpty) {
      showAppSnackBar('Error', 'Password is required.',
          backgroundColor: _cs.error, colorText: _cs.onError);
      return;
    }

    isLoading.value = true;
    if (Get.isRegistered<AdminStoreService>()) {
      try {
        await Get.find<AdminStoreService>().trySync().timeout(const Duration(seconds: 6));
      } catch (_) {
        // Best-effort — an unreachable PG at login time is normal on a
        // fresh station and must not block the factory-hash fallback.
      }
    }
    isLoading.value = false;

    final overrideHash = Get.isRegistered<AdminStoreService>()
        ? Get.find<AdminStoreService>().store.value?.settings.superAdminPasswordHash
        : null;
    final effectiveHash = overrideHash ?? kSuperAdminFactoryHash;

    if (!PasswordHasher.verify(password, effectiveHash)) {
      showAppSnackBar('Login failed', 'Invalid password.',
          backgroundColor: _cs.error, colorText: _cs.onError);
      return;
    }

    passwordController.clear();
    isAuthenticated.value = true;
    Get.offNamed('/home');
  }

  void logout() {
    isAuthenticated.value = false;
    Get.offAllNamed('/');
  }

  @override
  void onClose() {
    passwordController.dispose();
    super.onClose();
  }
}
