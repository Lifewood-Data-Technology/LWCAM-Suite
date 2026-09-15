import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../auth/auth_controller.dart';
import '../services/users_store_service.dart';
import '../theme/app_colors.dart';
import 'settings_page.dart';

class LoginPage extends StatelessWidget {
  LoginPage({super.key});

  // SettingsController is registered permanent here (first page) so the
  // instance is the same one gallery/upload/box flows Get.find later — it
  // now just mirrors NodeConfig.destinationPath (set by LWCam Admin's
  // Station Setup; LWCAM has no Settings page of its own).
  // ignore: unused_field
  final SettingsController _settings = Get.isRegistered<SettingsController>()
      ? Get.find<SettingsController>()
      : Get.put(SettingsController(), permanent: true);

  final AuthController authController = Get.isRegistered<AuthController>()
      ? Get.find<AuthController>()
      : Get.put(AuthController(), permanent: true);

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
                    // Saffron brand accent bar (mirrors the Lifewood palette
                    // card look from the brand sheet).
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
                      padding: const EdgeInsets.only(bottom: 24.0),
                      child: Center(child: Image.asset('assets/logo.png', height: 80)),
                    ),
                    TextField(
                      controller: authController.usernameController,
                      decoration: const InputDecoration(labelText: 'Username'),
                      onChanged: (value) {
                        authController.username.value = value;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: authController.passwordController,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: 'Password'),
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
                    if (authController.storeMode.value == UsersStoreSource.none) ...[
                      const SizedBox(height: 12),
                      Text(
                        'No users snapshot on this PC yet — run LWCam Admin '
                        'station setup.',
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (authController.storeMode.value == UsersStoreSource.snapshot &&
                        _isStale(authController.usersStore?.lastLoaded?.updatedAt)) ...[
                      const SizedBox(height: 8),
                      Text(
                        'User list last synced ${_formatSyncTime(authController.usersStore?.lastLoaded?.updatedAt)} '
                        '— sign-in uses the offline snapshot.',
                        style: TextStyle(color: lw.warning, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  /// The pull stamps `updatedAt` as the pull time — this IS "last synced".
  /// Staleness is a soft signal only (sync could simply be off), so the
  /// threshold is generous.
  bool _isStale(DateTime? updatedAt) =>
      updatedAt == null || DateTime.now().difference(updatedAt) > const Duration(hours: 24);

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');

  String _formatSyncTime(DateTime? updatedAt) {
    if (updatedAt == null) return 'unknown';
    final local = updatedAt.toLocal();
    return '${local.year}-${_twoDigits(local.month)}-${_twoDigits(local.day)} '
        '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  }
}
