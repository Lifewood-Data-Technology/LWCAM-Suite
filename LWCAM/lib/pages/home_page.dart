import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../models/app_user.dart';
import '../widgets/session_app_bar_actions.dart';
import 'orphan_resolution_page.dart';
import 'projects_page.dart';

/// Post-login landing: a greeting and the choices this account actually has.
///
/// Branding first — the mark, who is signed in, and in what role — because this
/// is the one screen whose whole job is orientation. Everything below it is two
/// cards at most:
///
///   Projects            always. The way in to a dashboard, capture, or QC.
///   Unresolved Images   admins only. Housekeeping, not a daily destination.
///
/// Capture is deliberately NOT a card. It is entered through a project, so the
/// device-registry gate and the active-project assignment happen in exactly one
/// place rather than two.
///
/// Nothing hides in an app-bar overflow. The old one existed to hold Unresolved
/// Images and an unscoped "all projects" QC queue; the first is a card now and
/// the second is gone (QC is always project-scoped).
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    return Obx(() {
      final user = auth.currentUser.value;
      final admin = user?.isAdmin ?? false;

      // One choice is not a choice. A capture-only or QC-only account with
      // several projects would otherwise read a greeting and then press the
      // single button under it, so skip straight to the list.
      if (!admin) return const ProjectsPage();

      final roleText = user == null
          ? ''
          : user.roles.map(_roleLabel).join(', ');

      return Scaffold(
        appBar: AppBar(
          title: const Text('LWCAM (Lifewood Capture)'),
          actions: sessionAppBarActions(context),
        ),
        body: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 24),
                  Image.asset('assets/logo.png', height: 64),
                  const SizedBox(height: 16),
                  Text(
                    'Welcome, ${auth.username.value}',
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  if (roleText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Role: $roleText',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 28),
                  _HomeCard(
                    icon: Icons.folder_special_outlined,
                    title: 'Projects',
                    subtitle: 'Pick a project to work on.',
                    onTap: () => Get.to(() => const ProjectsPage()),
                  ),
                  _HomeCard(
                    icon: Icons.image_not_supported_outlined,
                    title: 'Unresolved Images',
                    subtitle: 'Captures that were not filed into a group.',
                    onTap: () => Get.to(() => const OrphanResolutionPage()),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  String _roleLabel(UserRole r) {
    switch (r) {
      case UserRole.admin:
        return 'Admin';
      case UserRole.capture:
        return 'Capture';
      // Granted by LWCam Admin and acted on only in the QC console; this app
      // shows the label and offers nothing behind it (Phase 8).
      case UserRole.qc:
        return 'QC';
    }
  }
}

class _HomeCard extends StatelessWidget {
  const _HomeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        leading:
            Icon(icon, size: 32, color: Theme.of(context).colorScheme.primary),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
