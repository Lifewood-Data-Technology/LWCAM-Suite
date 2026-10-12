// App-bar actions shared by every page of the capture app (LWCAM): version
// label, dark/light toggle and Logout. Pages add them to their AppBar so the
// controls look the same everywhere.
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../services/app_version.dart';
import '../theme/theme_controller.dart';

/// The two controls that used to live on the Home screen's app bar: the
/// dark/light toggle (the one per-user setting LWCAM still owns — everything
/// station-level moved to LWCam Admin's Station Setup) and Logout.
///
/// Home is gone; the shell that replaced it has no app bar of its own, so each
/// destination carries these instead. Shared rather than duplicated because
/// two pages showing a differently-styled Logout reads as two different apps.
List<Widget> sessionAppBarActions(BuildContext context) {
  final auth = Get.find<AuthController>();
  // Outlined pill in the AppBar's own foreground (Paper on Dark Serpent): the
  // default TextButton primary was near-invisible on the dark bar.
  final fg = Theme.of(context).appBarTheme.foregroundColor ??
      Theme.of(context).colorScheme.onSurface;
  return [
    Center(
      child: Text('v$appVersion', style: TextStyle(color: fg, fontSize: 12)),
    ),
    Obx(() {
      final theme = Get.find<ThemeController>();
      final dark = theme.isDarkResolved;
      return IconButton(
        tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
        icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
        color: fg,
        onPressed: () => theme.setMode(dark ? ThemeMode.light : ThemeMode.dark),
      );
    }),
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: OutlinedButton.icon(
        onPressed: auth.logout,
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          side: BorderSide(color: fg.withValues(alpha: 0.65)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        icon: const Icon(Icons.logout, size: 18),
        label: const Text('Logout'),
      ),
    ),
  ];
}
