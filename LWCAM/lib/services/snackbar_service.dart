// App-wide toast helper for LWCAM: one scaffold-messenger key and
// showAppSnackBar, so controllers can show messages without a BuildContext.
import 'package:flutter/material.dart';
import 'package:get/get.dart';

final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Default toast width: a compact, centred floating snackbar instead of a
/// full-width bar. This is the app-wide default — pages with a corner button
/// (Projects, Box list, User Management) place that button in a body Stack
/// (not the Scaffold FAB slot) so the floating snackbar isn't lifted to clear
/// it and instead shares the bottom row. The capture page opts out by passing
/// `width: null` (full-width, original behaviour).
const double kCompactSnackBarWidth = 420;

void showAppSnackBar(
  String title,
  String message, {
  SnackPosition snackPosition = SnackPosition.BOTTOM,
  Color? backgroundColor,
  Color? colorText,
  Duration duration = const Duration(seconds: 2),
  double? width = kCompactSnackBarWidth,
}) {
  // Defaults resolve against the active theme (inverse surface) so snackbars
  // stay legible in both light and dark mode. Explicit colors still win.
  final scheme = Get.theme.colorScheme;
  backgroundColor ??= scheme.inverseSurface;
  colorText ??= scheme.onInverseSurface;

  final messenger = appScaffoldMessengerKey.currentState;

  if (messenger != null) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('$title\n$message', style: TextStyle(color: colorText)),
        backgroundColor: backgroundColor,
        duration: duration,
        behavior: SnackBarBehavior.floating,
        // A non-null width centres the floating snackbar horizontally.
        width: width,
      ),
    );
    return;
  }

  // Fallback to Get.snackbar if there is an overlay/context available.
  try {
    if (Get.overlayContext != null) {
      Get.snackbar(
        title,
        message,
        snackPosition: snackPosition,
        backgroundColor: backgroundColor,
        colorText: colorText,
        duration: duration,
        maxWidth: width,
      );
      return;
    }
  } catch (_) {
    // swallow to avoid crashing due to missing overlay.
  }

  // Last resort: log if no UI overlay is available
  debugPrint('SnackBar fallback: $title - $message');
}
