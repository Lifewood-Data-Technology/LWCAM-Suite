import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/admin_auth_controller.dart';
import '../services/admin_bootstrap.dart';
import '../services/admin_store_service.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import 'app_settings_page.dart';
import 'devices_page.dart';
import 'projects_page.dart';
import 'station_setup_page.dart';
import 'user_management_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AdminAuthController>();
    final appBarFg = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('LWCam Admin'),
        actions: [
          // Dark/light toggle — same placement as LWCAM's Home app bar.
          Obx(() {
            final theme = Get.find<ThemeController>();
            final dark = theme.isDarkResolved;
            return IconButton(
              tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
              icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
              color: appBarFg,
              onPressed: () =>
                  theme.setMode(dark ? ThemeMode.light : ThemeMode.dark),
            );
          }),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
            child: OutlinedButton.icon(
              onPressed: auth.logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: appBarFg,
                side: BorderSide(color: appBarFg.withValues(alpha: 0.65)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              icon: const Icon(Icons.logout, size: 18),
              label: const Text('Logout'),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const _StatusBar(),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 24),
                      Image.asset('assets/logo.png', height: 64),
                      const SizedBox(height: 28),
                      _HomeCard(
                        icon: Icons.manage_accounts_outlined,
                        title: 'User Management',
                        subtitle: 'Create accounts, roles, passwords and Device IDs.',
                        onTap: () => Get.to(() => const UserManagementPage()),
                      ),
                      _HomeCard(
                        icon: Icons.folder_special_outlined,
                        title: 'Projects',
                        subtitle: 'Create, edit and assign projects; edit metadata templates.',
                        onTap: () => Get.to(() => const ProjectsPage()),
                      ),
                      _HomeCard(
                        icon: Icons.devices_other,
                        title: 'Devices',
                        subtitle: 'See which project each capture device is assigned to; reassign.',
                        onTap: () => Get.to(() => const DevicesPage()),
                      ),
                      _HomeCard(
                        icon: Icons.settings_outlined,
                        title: 'App Settings',
                        subtitle: 'Metadata keying, remote shutter, default temp password.',
                        onTap: () => Get.to(() => const AppSettingsPage()),
                      ),
                      _HomeCard(
                        icon: Icons.dns_outlined,
                        title: 'Station Setup',
                        subtitle: 'This machine\'s PostgreSQL connection and snapshot path.',
                        onTap: () => Get.to(() => const StationSetupPage()),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Persistent status strip: online/offline, dirty count, schema-outdated
/// warning, last pull time — the one place an admin checks before assuming
/// an edit actually reached PostgreSQL.
class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    final lw = LifewoodColors.of(context);
    final cs = Theme.of(context).colorScheme;
    return Obx(() {
      // Read the bootstrap generation FIRST so a Station Setup save (which
      // deletes and re-registers the service, silencing the old instance's
      // Rx forever) forces this Obx to rebuild and re-find the live one.
      AdminBootstrap.generation.value;
      if (!Get.isRegistered<AdminStoreService>()) return const SizedBox.shrink();
      final svc = Get.find<AdminStoreService>();
      String label;
      Color color;
      Color onColor;
      if (!svc.pgConnectionEnabled) {
        final n = (svc.store.value?.deletedUsernames.length ?? 0) +
            (svc.store.value?.deletedProjectKeys.length ?? 0) +
            (svc.dirty.value ? 1 : 0);
        label = svc.dirty.value
            ? 'PostgreSQL connection disabled — $n unsynced change(s) queued.'
            : 'PostgreSQL connection disabled — working offline (Station Setup).';
        color = lw.info;
        onColor = lw.onInfo;
      } else if (svc.schemaOutdated.value) {
        label = 'Database schema out of date — updates queued locally.';
        color = cs.error;
        onColor = cs.onError;
      } else if (!svc.online.value) {
        final n = (svc.store.value?.deletedUsernames.length ?? 0) +
            (svc.store.value?.deletedProjectKeys.length ?? 0) +
            (svc.dirty.value ? 1 : 0);
        label = svc.dirty.value
            ? 'Offline — $n unsynced change(s) queued.'
            : 'Offline — no PostgreSQL connection.';
        color = lw.warning;
        onColor = lw.onWarning;
      } else {
        final last = svc.lastPullAt.value;
        final when = last == null ? 'just now' : '${last.hour.toString().padLeft(2, '0')}:'
            '${last.minute.toString().padLeft(2, '0')}';
        label = 'Online — last pull $when.';
        color = lw.success;
        onColor = lw.onSuccess;
      }
      return Container(
        width: double.infinity,
        color: color,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Text(label, style: TextStyle(color: onColor, fontSize: 13)),
      );
    });
  }
}

class _HomeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        leading: Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
