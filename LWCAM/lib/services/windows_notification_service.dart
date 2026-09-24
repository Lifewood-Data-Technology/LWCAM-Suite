// ignore_for_file: avoid_print

import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class WindowsNotificationService {
  WindowsNotificationService._();
  static final WindowsNotificationService instance =
      WindowsNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  int _notificationId = 1;

  Future<void> initialize() async {
    if (_initialized || !Platform.isWindows) return;

    const windowsSettings = WindowsInitializationSettings(
      appName: 'LWCAM (Lifewood Capture)',
      appUserModelId: 'Com.Lifewood.LWCAM',
      guid: '0163e34e-b8ed-4d33-992f-362a4fbf7fb6',
    );

    const settings = InitializationSettings(windows: windowsSettings);

    await _plugin.initialize(settings: settings);
    _initialized = true;
  }

  Future<void> showTransferNotification({
    required String title,
    required String body,
    bool warning = false,
  }) async {
    if (!Platform.isWindows) return;
    await initialize();

    final details = NotificationDetails(
      windows: WindowsNotificationDetails(
        audio: warning ? WindowsNotificationAudio.silent() : null,
      ),
    );

    await _plugin.show(
      id: _notificationId++,
      title: title,
      body: body,
      notificationDetails: details,
      payload: warning ? 'transfer-warning' : 'transfer-info',
    );
  }
}
