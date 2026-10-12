// Login screen of LWCam Admin (the app that manages users, projects, devices
// and this station's database connection for the LWCAM suite). The app is
// guarded by one SuperAdmin password; the check itself lives in
// AdminAuthController, this file is only the form and the status hints.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/admin_auth_controller.dart';
import '../services/admin_store_service.dart';
import '../theme/app_colors.dart';

/// Sign-in screen: a single SuperAdmin password, checked by
/// AdminAuthController. Also shows a hint when the database schema is out of
/// date or the station is offline (sign-in then uses the local snapshot).
class LoginPage extends StatelessWidget {
  LoginPage({super.key});

  final AdminAuthController authController = Get.isRegistered<AdminAuthController>()
      ? Get.find<AdminAuthController>()
      : Get.put(AdminAuthController(), permanent: true);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final lw = LifewoodColors.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 350),
            child: Container(
              padding: const EdgeInsets.all(24.0),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                      color: cs.shadow.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Obx(() {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 20),
                      decoration: BoxDecoration(
                        color: cs.tertiary,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: Center(child: Image.asset('assets/logo.png', height: 80)),
                    ),
                    Text('LWCam Admin',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
                    const SizedBox(height: 24),
                    TextField(
                      controller: authController.passwordController,
                      obscureText: true,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: 'SuperAdmin password'),
                      onSubmitted: (_) => authController.login(),
                    ),
                    const SizedBox(height: 24),
                    authController.isLoading.value
                        ? const CircularProgressIndicator()
                        : SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: authController.login,
                              child: const Text('Login'),
                            ),
                          ),
                    if (Get.isRegistered<AdminStoreService>()) Builder(builder: (context) {
                      final svc = Get.find<AdminStoreService>();
                      if (svc.schemaOutdated.value) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'PostgreSQL schema is out of date — edits will queue locally '
                            'until it is updated.',
                            style: TextStyle(color: cs.error, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      if (!svc.online.value) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'Offline — signing in against the local snapshot; use '
                            'Station Setup once connected.',
                            style: TextStyle(color: lw.warning, fontSize: 12),
                            textAlign: TextAlign.center,
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}
