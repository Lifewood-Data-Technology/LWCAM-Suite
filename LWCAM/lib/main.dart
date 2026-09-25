// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/upload_contoller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/pages/capture_box_list_page.dart';
import 'package:lwcam/pages/gallery_page.dart';
import 'package:lwcam/pages/home_page.dart';
import 'package:lwcam/pages/login_page.dart';
import 'package:lwcam/services/adb_device_service.dart';
import 'package:lwcam/services/audit_log_service.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:lwcam/services/scrcpy_service.dart';
import 'package:lwcam/services/snackbar_service.dart';
import 'package:lwcam/services/sync_bootstrap.dart';
import 'package:lwcam/services/sync_service.dart';
import 'package:lwcam/services/transfer_queue_service.dart';
import 'package:lwcam/theme/app_theme.dart';
import 'package:lwcam/theme/theme_controller.dart';
import 'package:lwcam/services/single_instance.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

Future<void> main() async {
  // Capture uncaught Flutter errors
  FlutterError.onError = (FlutterErrorDetails details) async {
    // Keep the default red-screen/console presentation — without it a
    // first-frame build error leaves a permanently blank window with the
    // only clue buried in a Downloads log file.
    FlutterError.presentError(details);
    await _handleGlobalError(
      details.exceptionAsString(),
      details.stack.toString(),
    );
  };

  // Capture uncaught Dart zone errors
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // One LWCAM per Windows account: this launch replaces any earlier one.
      // FIRST, before anything else touches shared state. It used to sit just
      // before windowManager, by which point this process had already run the
      // sync and processing bootstraps, and both processes briefly drained the
      // same per-device outbox. (It also used to have started the QC engine
      // sidecar, which made the overlap worse — that engine left this app in
      // Phase 8, but the ordering is still what keeps the outbox single.)
      await killOtherInstances();

      // Initialize SQLite FFI (for Windows / desktop)
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // Local, append-only audit trail + replacement log (see
      // audit_log_service.dart) — registered before login so pre-login
      // events (e.g. a failed login attempt) still get recorded.
      Get.put(AuditLogService.production(), permanent: true);

      // Load per-machine sync/node config (Phase 0 foundation — see
      // node_config.dart / sync_bootstrap.dart). NodeConfig.syncEnabled
      // defaults false, so existing installs see zero behavior change until
      // an admin explicitly opts in from Settings. No one has logged in
      // yet at this point, but the last real capture device id used on this
      // machine (if any) is persisted across restarts — see
      // AuthController.resolveSyncDeviceId — so a previously-configured
      // station resumes draining immediately rather than waiting for a
      // fresh login every launch. SyncBootstrap.apply runs again at login
      // regardless, keying off whichever device just signed in.
      final nodeConfigService = NodeConfigService(
        getConfigPath: () {
          final home =
              Platform.environment['USERPROFILE'] ??
              Platform.environment['HOME'] ??
              'C:\\';
          return p.join(home, 'LWCAM_DBs', NodeConfigService.fileName);
        },
      );
      Get.put(nodeConfigService, permanent: true);
      final nodeConfig = await nodeConfigService.load();
      UploadStatsDB().syncEnabled = nodeConfig.syncEnabled;
      try {
        // Called unconditionally — an admin-only station with no persisted
        // capture device id still needs the permanent users/projects pull
        // whenever a PG host is configured. SyncBootstrap.apply itself
        // no-ops the outbox drain when deviceId is empty.
        final priorDeviceId = await AuthController.readPersistedSyncDeviceId();
        await SyncBootstrap.apply(nodeConfig, deviceId: priorDeviceId);
      } catch (e) {
        print('⚠️ Sync bootstrap skipped at startup: $e');
      }

      // NOTE: notification-service initialization deliberately does NOT
      // happen at startup AT ALL — flutter_local_notifications' Windows
      // initialize() audibly plays the system error tone every time it runs
      // (verified by ear-bisect 2026-07-15; no upstream fix as of v22.0.1),
      // and its first-run COM/shortcut registration can take seconds (or
      // stall behind antivirus). showTransferNotification() lazily
      // initializes on first use instead, where the tone coincides with the
      // expected transfer-complete toast.

      // Theme choice must be known before the window shows so the native
      // window background matches (no white flash when dark mode is saved).
      final themeController = await ThemeController.load();
      Get.put(themeController, permanent: true);

      // Initialize the desktop window manager
      await windowManager.ensureInitialized();

      // hotkey_manager requires clearing any hotkeys left registered by a
      // previous (possibly crashed) run before we register our own.
      await hotKeyManager.unregisterAll();

      // Attach window close listener for cleanup
      windowManager.addListener(_AppWindowListener());

      // Opaque background: a transparent window forces the slow layered-
      // window composition path on Windows (laggy everything on iGPU) and
      // was the main culprit of the blank-on-cold-launch window. The color
      // matches the resolved theme's scaffold so startup doesn't flash.
      final windowOptions = WindowOptions(
        size: const Size(1280, 800),
        center: true,
        title: 'LWCAM (Lifewood Capture)',
        backgroundColor: themeController.isDarkResolved
            ? AppTheme.darkWindowBackground
            : AppTheme.lightWindowBackground,
      );

      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        // Required for _AppWindowListener.onWindowClose to reliably gate
        // window close behind the exit-confirm dialog + cleanup.
        await windowManager.setPreventClose(true);
        // Maximize deliberately NOT here: resizing during the reveal races
        // the first frame and blanked the window on cold launches. It runs
        // post-first-frame instead (_PostFrameStartup).
      });

      runApp(const MyApp());
    },
    (error, stack) async {
      await _handleGlobalError(error.toString(), stack.toString());
    },
  );
}

/// Deferred startup work that must only run once a real Flutter frame exists:
/// maximizing the window (resizing before the first frame blanked the client
/// area on cold launches). The notification plugin is deliberately NOT
/// initialized here — its Windows initialize() plays the system error tone
/// every launch (see the NOTE in main()); it initializes lazily on first use.
class _PostFrameStartup {
  static bool _done = false;

  static void run() {
    if (_done) return;
    _done = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // show()/focus() in waitUntilReadyToShow are async and this first
        // post-frame callback can beat them; maximizing a not-yet-shown
        // window is a no-op on Windows, which is why a single early call was
        // silently dropped and the app launched at 1280x800. Wait for the
        // window to be visible, then maximize and verify it actually took,
        // retrying briefly (each attempt is skipped once isMaximized).
        for (var i = 0; i < 40 && !await windowManager.isVisible(); i++) {
          await Future.delayed(const Duration(milliseconds: 25));
        }
        for (var i = 0; i < 20 && !await windowManager.isMaximized(); i++) {
          await windowManager.maximize();
          await Future.delayed(const Duration(milliseconds: 50));
        }
      } catch (e) {
        print('⚠️ Post-frame maximize failed: $e');
      }
    });
  }
}

// Global error logger
Future<void> _handleGlobalError(String error, String stack) async {
  try {
    // Write crash log to user's Downloads folder
    final downloadsDir = Directory(
      '${Platform.environment['USERPROFILE']}\\Downloads',
    );
    if (!downloadsDir.existsSync()) {
      downloadsDir.createSync(recursive: true);
    }

    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}_${_twoDigits(now.hour)}-${_twoDigits(now.minute)}-${_twoDigits(now.second)}';

    final logPath = '${downloadsDir.path}\\lwcam_log_$timestamp.txt';
    final logFile = File(logPath);

    await logFile.writeAsString(
      '[${DateTime.now()}]\n$error\n$stack\n',
      mode: FileMode.write,
    );

    await _showWindowsErrorMessage(
      'An unexpected error occurred.\n\n'
      'Details have been saved to:\n$logPath',
    );
  } catch (e) {
    print('Failed to write error log: $e');
  }
}

String _twoDigits(int n) => n.toString().padLeft(2, '0');

// Windows popup error dialog
Future<void> _showWindowsErrorMessage(String message) async {
  final escaped = message.replaceAll("'", "''");
  try {
    await Process.run('powershell', [
      '-Command',
      "Add-Type -AssemblyName PresentationFramework; "
          "[System.Windows.MessageBox]::Show('$escaped', "
          "'LWCAM Error', 'OK', 'Error')",
    ]);
  } catch (e) {
    print('Failed to show Windows popup: $e');
  }
}

// Main App widget
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Maximize + notification init once a real frame exists (idempotent).
    _PostFrameStartup.run();
    return GetMaterialApp(
      title: 'LWCAM',
      debugShowCheckedModeBanner: false,
      // Desktop-style instant navigation: mobile slide transitions animated
      // the heavy (non-virtualized) gallery on every push/pop, which read as
      // app-wide lag. (Fallback if too abrupt: Transition.fadeIn @120ms.)
      defaultTransition: Transition.noTransition,
      transitionDuration: Duration.zero,
      // Lifewood brand themes (light Paper / dark Serpent) live in
      // lib/theme/app_theme.dart; the mode is persisted by ThemeController
      // and switched at runtime via Get.changeThemeMode. The old inline
      // theme's dark-title-on-light-AppBar workaround is obsolete: the
      // themed AppBar is now Dark Serpent with Paper foreground.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: Get.find<ThemeController>().themeMode.value,
      scaffoldMessengerKey: appScaffoldMessengerKey,
      // Lets ScrcpyPane hide the embedded mirror while any route covers it.
      navigatorObservers: [appRouteObserver],
      initialRoute: '/',
      getPages: [
        GetPage(name: '/', page: () => LoginPage()),
        // Home IS the post-login landing for every role now. There is no
        // separate capture project chooser and no unscoped QC queue: both were
        // folded into its Projects list, which every role reaches its work
        // through.
        GetPage(name: '/home', page: () => const HomePage()),
        GetPage(name: '/boxes', page: () => const CaptureBoxListPage()),
        GetPage(name: '/gallery', page: () => GalleryPage()),
      ],
    );
  }
}

// Handles cleanup when window is closing
class _AppWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    try {
      // A background box transfer in flight/queued gets an explicit warning —
      // exiting is still allowed (the box just stays open; checkpoint +
      // "only NEW files" skip logic make re-transferring safe, and any stage
      // dir left behind is swept on next launch by
      // TransferQueueService._sweepStaleStageDirs).
      final hasActiveBoxTransfer =
          Get.isRegistered<TransferQueueService>() &&
          Get.find<TransferQueueService>().queue.any((j) => j.isActive);

      // Confirm exit
      final shouldExit = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('Exit LWCAM?'),
          content: Text(
            hasActiveBoxTransfer
                ? 'A group transfer is in progress in the background. Exiting now '
                      'will stop it — the group stays open and can be re-transferred '
                      'next launch. Exit anyway?'
                : 'Are you sure you want to close the application?',
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Get.back(result: true),
              child: const Text('Exit'),
            ),
          ],
        ),
      );

      // User canceled exit
      if (shouldExit != true) return;

      // Vanish immediately: the remaining teardown used to hold the visible
      // window open for seconds. Hiding first makes exit feel instant while
      // cleanup finishes out of sight.
      try {
        await windowManager.hide();
      } catch (_) {}

      // The scrcpy mirror is a child process — it would linger after the
      // app closes unless killed here (the job object is the crash backstop).
      await ScrcpyService.instance.stop();
      // After scrcpy, which drives the phone over adb: killing the
      // server first would only make it spawn a fresh one on the way out.
      await AdbDeviceService().killServer();

      // Bounded cleanup — nothing here may delay process exit indefinitely.
      if (Get.isRegistered<UploadController>()) {
        try {
          await Get.find<UploadController>().cleanupTempFiles().timeout(
            const Duration(seconds: 3),
          );
        } catch (e) {
          print('Cleanup skipped on window close: $e');
        }
      }

      // Stop the sync drain timer and release its PG connection, if running.
      if (Get.isRegistered<SyncService>()) {
        try {
          await Get.delete<SyncService>(
            force: true,
          ).timeout(const Duration(seconds: 3));
        } catch (e) {
          print('Sync service cleanup skipped on window close: $e');
        }
      }

      // Proceed to close app window
      await windowManager.destroy();
    } catch (e) {
      print('Cleanup failed on window close: $e');
      await ScrcpyService.instance.stop();
      // After scrcpy, which drives the phone over adb: killing the
      // server first would only make it spawn a fresh one on the way out.
      await AdbDeviceService().killServer();
      await windowManager.destroy();
    }
  }
}
