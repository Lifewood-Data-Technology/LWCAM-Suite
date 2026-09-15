import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/box_integrity.dart' as integrity;
import 'package:path/path.dart' as p;

/// A swap recapture changes the BYTES under an existing filename, and two later
/// readers prefer the box's durable local store over the phone:
///
///   * reopening a box copies from that store instead of re-pulling, so a stale
///     copy showed the SUPERSEDED photo in the grid after a restart;
///   * stageBoxFiles reuses it at transfer time whenever its size matches the
///     device's - so if the two photos happened to be the same size, the OLD
///     one would have been transferred. Silently, and permanently.
///
/// The gallery cache and Flutter's three image-cache entries were already
/// refreshed on swap; only the durable store was missed, which is why the
/// replacement looked correct until LWCAM was restarted.
const _device = 'SAX09';
const _slot = 'IMG_20260902_101500.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider has no platform implementation under `flutter test`, and the
  // durable store lives under the application support directory. Same mock the
  // thumbnail service test uses.
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  late Directory supportDir;

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('durable_support_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') return supportDir.path;
      return null;
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  /// A controller with an active box, built directly rather than through
  /// Get.put so onInit - and the database it would open - never runs.
  BoxSessionController controllerWithBox(int boxId) {
    final auth = AuthController();
    auth.deviceId.value = _device;
    final controller = BoxSessionController(auth);
    controller.activeBox.value = CaptureBox(
      id: boxId,
      deviceId: _device,
      boxDetails: 'BOX 1',
    );
    return controller;
  }

  Future<File> fileWith(String name, String contents) async {
    final dir = await Directory.systemTemp.createTemp('durable_src_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
    final file = File(p.join(dir.path, name));
    await file.writeAsString(contents);
    return file;
  }

  test('a swap refreshes the durable copy the grid reloads from', () async {
    final controller = controllerWithBox(1);
    final store = await integrity.boxImagesDir(_device, 1);

    // What capture-time assignment left behind.
    final durable = File(p.join(store.path, _slot));
    await durable.writeAsString('ORIGINAL');

    await controller.replaceDurableImage(_slot, await fileWith(_slot, 'REPLACEMENT'));

    expect(
      await durable.readAsString(),
      'REPLACEMENT',
      reason: 'reopening the box copies from here in preference to re-pulling',
    );
  });

  test('the durable copy is written even when none existed', () async {
    // A slot whose capture-time persist failed still has a phone-side file; the
    // swap should leave the store correct rather than empty.
    final controller = controllerWithBox(2);
    final store = await integrity.boxImagesDir(_device, 2);

    await controller.replaceDurableImage(_slot, await fileWith(_slot, 'REPLACEMENT'));

    expect(await File(p.join(store.path, _slot)).readAsString(), 'REPLACEMENT');
  });

  test('a missing source leaves the existing copy alone', () async {
    // Best-effort: the phone still holds the swapped file, so a failure here
    // must cost a re-pull, not destroy the copy that is already correct.
    final controller = controllerWithBox(3);
    final store = await integrity.boxImagesDir(_device, 3);
    final durable = File(p.join(store.path, _slot));
    await durable.writeAsString('ORIGINAL');

    await controller.replaceDurableImage(
      _slot,
      File(p.join(supportDir.path, 'does-not-exist.jpg')),
    );

    expect(await durable.readAsString(), 'ORIGINAL');
  });

  test('no active box is a no-op rather than a crash', () async {
    final auth = AuthController();
    auth.deviceId.value = _device;
    final controller = BoxSessionController(auth);

    await expectLater(
      controller.replaceDurableImage(_slot, await fileWith(_slot, 'REPLACEMENT')),
      completes,
    );
  });
}
