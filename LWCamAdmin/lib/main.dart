// ignore_for_file: avoid_print

// Entry point of LWCam Admin, the Windows app that manages users, projects,
// devices and this station's database connection for the suite. Registers the
// node-config, store and theme services, sizes the window to the screen, then
// shows the login page. Any unhandled error is written to a log file in the
// user's Downloads folder and shown in a message box.
// Services are registered here before runApp; the store service is built
// without awaiting its first sync so an unreachable database never delays launch.

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:lwcam_admin/controllers/sync_status_controller.dart';
import 'package:lwcam_admin/pages/home_page.dart';
import 'package:lwcam_admin/pages/login_page.dart';
import 'package:lwcam_admin/services/admin_bootstrap.dart';
import 'package:lwcam_admin/services/node_config_service.dart';
import 'package:lwcam_admin/services/single_instance.dart';
import 'package:lwcam_admin/services/snackbar_service.dart';
import 'package:lwcam_admin/theme/app_theme.dart';
import 'package:lwcam_admin/theme/theme_controller.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// [preferred], shrunk to fit [workArea] with a margin for the taskbar and
/// window frame. Returns [preferred] unchanged when the work area is unknown
/// or already big enough — the clamp exists only to stop a window opening
/// taller than the screen, where `center: true` would push its title bar off
/// the top and leave it neither draggable nor resizable.
Size _fitToWorkArea(Size preferred, Size? workArea) {
  if (workArea == null) return preferred;
  const margin = 40.0;
  final w = workArea.width - margin;
  final h = workArea.height - margin;
  if (w <= 0 || h <= 0) return preferred;
  return Size(
    preferred.width > w ? w : preferred.width,
    preferred.height > h ? h : preferred.height,
  );
}

Future<void> main() async {
  FlutterError.onError = (FlutterErrorDetails details) async {
    FlutterError.presentError(details);
    await _handleGlobalError(details.exceptionAsString(), details.stack.toString());
  };

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // One Admin per Windows account: this launch replaces any earlier one.
      await killOtherInstances();

      // Same folder LWCAM resolves — this app's Station Setup provisions
      // the very lwcam_node_config.json LWCAM's SyncBootstrap reads.
      final nodeConfigService = NodeConfigService(
        getConfigPath: () {
          final home = Platform.environment['USERPROFILE'] ??
              Platform.environment['HOME'] ??
              'C:\\';
          return p.join(home, 'LWCAM_DBs', NodeConfigService.fileName);
        },
      );
      Get.put(nodeConfigService, permanent: true);
      final nodeConfig = await nodeConfigService.load();
      // Deliberately NOT awaited: the fresh-start path registers the store
      // service synchronously (before its first await), and the initial
      // reconcile behind it can spend ~5s on a connect timeout when the
      // configured host is unreachable — awaiting that held the window
      // back for seconds at every launch. Login runs its own bounded
      // trySync anyway.
      unawaited(AdminBootstrap.apply(nodeConfig));
      // The periodic reconcile tick (30s trySync — auto-pushes queued
      // offline edits the moment PG is reachable again, and keeps the Home
      // status banner live). Looks the store service up per tick, so it
      // survives Station Setup re-registering it.
      Get.put(SyncStatusController(), permanent: true);

      final themeController = await ThemeController.load();
      Get.put(themeController, permanent: true);

      await windowManager.ensureInitialized();
      windowManager.addListener(_AppWindowListener());

      // Best-effort: a display query that fails must not stop the app opening,
      // so an error just means "do not clamp".
      Size? workArea;
      try {
        workArea = (await screenRetriever.getPrimaryDisplay()).visibleSize;
      } catch (e) {
        print('⚠️ Could not read the display size, using the default window: $e');
      }

      final windowOptions = WindowOptions(
        // Measured from the window the operator had sized by hand on the
        // station (1384x970 outer, at 100% scale). window_manager takes
        // LOGICAL pixels and multiplies by the display's scale factor, so this
        // keeps the same apparent size on a 125%/150% screen rather than
        // shrinking. The previous 1100x750 was chosen to fit a 1366x768 laptop.
        //
        // Clamped to the display's WORK AREA because `center: true` on a window
        // taller than the screen puts its top edge at a negative Y: the title
        // bar sits above the desktop, and the operator can then neither drag
        // nor resize the thing. 1366x768, and 1920x1080 at Windows' common
        // 125% scaling (a 1536x864 logical work area), are both shorter than
        // 970.
        size: _fitToWorkArea(const Size(1384, 970), workArea),
        center: true,
        title: 'LWCam Admin',
        backgroundColor: themeController.isDarkResolved
            ? AppTheme.darkWindowBackground
            : AppTheme.lightWindowBackground,
      );

      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setPreventClose(true);
      });

      runApp(const MyApp());
    },
    (error, stack) async {
      await _handleGlobalError(error.toString(), stack.toString());
    },
  );
}

Future<void> _handleGlobalError(String error, String stack) async {
  try {
    final downloadsDir = Directory('${Platform.environment['USERPROFILE']}\\Downloads');
    if (!downloadsDir.existsSync()) downloadsDir.createSync(recursive: true);

    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}_${_twoDigits(now.hour)}-${_twoDigits(now.minute)}-${_twoDigits(now.second)}';
    final logPath = '${downloadsDir.path}\\lwcam_admin_log_$timestamp.txt';
    await File(logPath).writeAsString('[${DateTime.now()}]\n$error\n$stack\n', mode: FileMode.write);

    await _showWindowsErrorMessage(
      'An unexpected error occurred.\n\nDetails have been saved to:\n$logPath',
    );
  } catch (e) {
    print('Failed to write error log: $e');
  }
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

Future<void> _showWindowsErrorMessage(String message) async {
  final escaped = message.replaceAll("'", "''");
  try {
    await Process.run('powershell', [
      '-Command',
      "Add-Type -AssemblyName PresentationFramework; "
          "[System.Windows.MessageBox]::Show('$escaped', "
          "'LWCam Admin Error', 'OK', 'Error')",
    ]);
  } catch (e) {
    print('Failed to show Windows popup: $e');
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'LWCam Admin',
      debugShowCheckedModeBanner: false,
      defaultTransition: Transition.noTransition,
      transitionDuration: Duration.zero,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: Get.find<ThemeController>().themeMode.value,
      scaffoldMessengerKey: appScaffoldMessengerKey,
      initialRoute: '/',
      getPages: [
        GetPage(name: '/', page: () => LoginPage()),
        GetPage(name: '/home', page: () => const HomePage()),
      ],
    );
  }
}

class _AppWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    try {
      final shouldExit = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('Exit LWCam Admin?'),
          content: const Text('Are you sure you want to close the application?'),
          actions: [
            TextButton(onPressed: () => Get.back(result: false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Get.back(result: true), child: const Text('Exit')),
          ],
        ),
      );
      if (shouldExit != true) return;

      try {
        await windowManager.hide();
      } catch (_) {}
      await windowManager.destroy();
    } catch (e) {
      print('Cleanup failed on window close: $e');
      await windowManager.destroy();
    }
  }
}
