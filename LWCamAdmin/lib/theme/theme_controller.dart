// Holds the Light/Dark/System theme choice and saves it between runs. Loaded
// in main.dart before the window shows so the window background matches the
// theme. A corrupt saved value falls back to light. This theme folder is
// copied between apps; keep the copies in step.

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's Light/Dark/System theme choice across restarts.
///
/// Loaded in main() BEFORE the window is shown so the native window
/// background can match the resolved theme (no white flash on dark mode).
///
/// NOTE: lib/theme/ is a byte-identical mirror between LWCAM and LWRework —
/// change one, copy to the other (see CHANGELOG convention).
class ThemeController extends GetxController {
  static const _prefKey = 'theme_mode'; // 'light' | 'dark' | 'system'

  final Rx<ThemeMode> themeMode = ThemeMode.light.obs;

  static Future<ThemeController> load() async {
    final controller = ThemeController();
    try {
      final prefs = await SharedPreferences.getInstance();
      controller.themeMode.value = switch (prefs.getString(_prefKey)) {
        'dark' => ThemeMode.dark,
        'system' => ThemeMode.system,
        _ => ThemeMode.light,
      };
    } catch (e) {
      // Corrupt/unreadable prefs: default to light rather than failing boot.
      // ignore: avoid_print
      print('⚠️ ThemeController: failed to load theme_mode pref: $e');
    }
    return controller;
  }

  Future<void> setMode(ThemeMode mode) async {
    themeMode.value = mode;
    Get.changeThemeMode(mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, switch (mode) {
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
        _ => 'light',
      });
    } catch (e) {
      // ignore: avoid_print
      print('⚠️ ThemeController: failed to persist theme_mode pref: $e');
    }
  }

  /// Resolved darkness for pre-runApp decisions (native window background).
  bool get isDarkResolved =>
      themeMode.value == ThemeMode.dark ||
      (themeMode.value == ThemeMode.system &&
          PlatformDispatcher.instance.platformBrightness == Brightness.dark);
}
