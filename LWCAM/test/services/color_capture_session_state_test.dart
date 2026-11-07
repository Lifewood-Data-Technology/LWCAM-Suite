import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/adb_device_service.dart';
import 'package:lwcam/services/color_cal_service.dart';
import 'package:lwcam/services/color_capture_session.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Phone-free adb: [serial] and [names] are what the next probe returns.
class _FakeAdb extends AdbDeviceService {
  String? serial = 'PHONE';
  List<String>? names = ['old.jpg'];
  int listingCalls = 0;
  @override
  Future<String?> deviceSerial() async => serial;
  @override
  Future<List<String>?> listDeviceImageNames() async {
    listingCalls++;
    return names;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _FakeAdb adb;
  late DateTime now;
  late int prompts;
  late bool promptAnswer;
  late File activeFile;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    root = await Directory.systemTemp.createTemp('capture_session_');
    UploadStatsDB().debugOverrideBaseFolderForTests(root.path);
    final config = NodeConfigService(
      getConfigPath: () => p.join(root.path, 'node.json'),
    );
    await config.save(const NodeConfig(colorCalEnabled: true));
    Get.put<NodeConfigService>(config);
    // A profile for PHONE calibrated today. ColorCalService uses the
    // "default" device key when no AuthController is registered.
    final calibrated = DateTime.now();
    final active = ActiveProfile(
      profileId: 'fixture',
      profilePath: 'fixture.json',
      calibratedAt: calibrated,
      calibratedAtRaw: calibrated.toIso8601String(),
      deviceId: 'station',
      phoneSerial: 'PHONE',
      sourceTask: const {'task_id': 'fixture'},
      workingSpace: 'linear_srgb_d65',
      whiteBalance: const [1, 1, 1],
      correction: const {
        'type': 'matrix3x3',
        'matrix': [
          [1, 0, 0],
          [0, 1, 0],
          [0, 0, 1],
        ],
      },
    );
    final key = base64Url.encode(utf8.encode('default')).replaceAll('=', '');
    activeFile = File(p.join(root.path, 'color_cal', key, 'active.json'));
    await activeFile.parent.create(recursive: true);
    await activeFile.writeAsString(jsonEncode(active.toJson()));
    expect(await ColorCalService().loadActive(), isNotNull);

    adb = _FakeAdb();
    now = calibrated;
    prompts = 0;
    promptAnswer = true;
    ColorCaptureSession.adbFactory = () => adb;
    ColorCaptureSession.clock = () => now;
    ColorCaptureSession.promptWithoutCorrection = () async {
      prompts++;
      return promptAnswer;
    };
    ColorCaptureSession.reset();
  });

  tearDown(() async {
    ColorCaptureSession.reset();
    ColorCaptureSession.adbFactory = AdbDeviceService.new;
    ColorCaptureSession.clock = DateTime.now;
    Get.reset();
    await UploadStatsDB().debugCloseAllForTests();
    await root.delete(recursive: true);
  });

  Future<ColorBinding> bind(String name) =>
      ColorCaptureSession.bindingFor('station', name);

  group('establishing a boundary', () {
    test('a null serial or listing commits nothing', () async {
      adb.serial = null;
      expect(await ColorCaptureSession.begin('station'), isFalse);
      adb.serial = 'PHONE';
      adb.names = null;
      expect(await ColorCaptureSession.begin('station'), isFalse);
      adb.names = ['old.jpg'];
      expect(await ColorCaptureSession.begin('station'), isTrue);
      expect((await bind('old.jpg')).reason, 'historical');
      expect((await bind('new.jpg')).profile, isNotNull);
      expect(prompts, 0);
    });
  });

  group('an established boundary', () {
    setUp(() async {
      expect(await ColorCaptureSession.begin('station'), isTrue);
    });

    test('survives a failed live-sync listing (the call the tick makes)',
        () async {
      ColorCaptureSession.phoneUnavailable();
      adb.names = ['old.jpg', 'during_glitch.jpg'];
      final listings = adb.listingCalls;
      expect(await ColorCaptureSession.begin('station'), isTrue);
      expect(adb.listingCalls, listings, reason: 'boundary is not re-listed');
      expect((await bind('during_glitch.jpg')).profile, isNotNull);
      expect((await bind('old.jpg')).reason, 'historical');
    });

    test('survives a failed serial probe and pauses binding meanwhile',
        () async {
      adb.serial = null;
      adb.names = ['old.jpg', 'during_glitch.jpg'];
      expect(await ColorCaptureSession.begin('station'), isFalse);
      await expectLater(bind('during_glitch.jpg'), throwsStateError,
          reason: 'no page is bound while the phone is unidentified');
      adb.serial = 'PHONE';
      expect(await ColorCaptureSession.begin('station'), isTrue);
      expect((await bind('during_glitch.jpg')).profile, isNotNull);
      expect(prompts, 0);
    });

    test('a different phone never receives the previous profile', () async {
      adb.serial = 'OTHER';
      adb.names = ['other_old.jpg', 'other_new.jpg'];
      promptAnswer = false; // operator goes back
      expect(await ColorCaptureSession.begin('station'), isFalse);
      expect(prompts, 1, reason: 'the profile is for PHONE, not OTHER');
      await expectLater(bind('other_new.jpg'), throwsStateError);
      promptAnswer = true; // operator continues without correction
      expect(await ColorCaptureSession.begin('station'), isTrue);
      expect((await bind('other_after.jpg')).reason, 'skipped');
      expect((await bind('other_new.jpg')).reason, 'historical');
    });

    test('a new day sets up a new boundary', () async {
      await activeFile.delete(); // no calibration for the new day
      now = now.add(const Duration(days: 1));
      adb.names = ['old.jpg', 'taken_before_rollover.jpg'];
      final listings = adb.listingCalls;
      expect(await ColorCaptureSession.begin('station'), isTrue);
      expect(adb.listingCalls, listings + 1);
      expect(prompts, 1);
      expect((await bind('taken_before_rollover.jpg')).reason, 'historical');
      expect((await bind('new_day.jpg')).reason, 'skipped');
    });

    test('an explicit reset re-establishes the boundary', () async {
      ColorCaptureSession.reset();
      adb.names = ['old.jpg', 'before_recalibration.jpg'];
      expect(await ColorCaptureSession.begin('station'), isTrue);
      expect((await bind('before_recalibration.jpg')).reason, 'historical');
    });
  });

  group('an explicit skip', () {
    for (final withProfile in [true, false]) {
      test(
          'survives transient failures '
          '${withProfile ? 'with' : 'without'} a valid profile on file',
          () async {
        if (!withProfile) await activeFile.delete();
        await ColorCaptureSession.skip('station');
        ColorCaptureSession.phoneUnavailable();
        expect(await ColorCaptureSession.begin('station'), isTrue);
        adb.serial = null;
        expect(await ColorCaptureSession.begin('station'), isFalse);
        adb.serial = 'PHONE';
        adb.names = ['old.jpg', 'glitch.jpg'];
        expect(await ColorCaptureSession.begin('station'), isTrue);
        final glitch = await bind('glitch.jpg');
        expect(glitch.reason, 'skipped');
        expect(glitch.profile, isNull, reason: 'skip is not replaced by a profile');
        expect(prompts, 0, reason: 'the operator is not asked again');
      });
    }
  });

  test('live-sync sequence persists a calibrated binding through '
      'BoxSessionController.assignNewImage', () async {
    final db = UploadStatsDB();
    final auth = AuthController()..deviceId.value = 'station';
    final session = BoxSessionController(auth);
    final boxId =
        await db.insertCaptureBox(deviceId: 'station', boxDetails: 'BOX');
    final folderId = await db.insertCaptureFolder(
      deviceId: 'station',
      folder: CaptureFolder(boxId: boxId, title: 'T', volume: 'V'),
      isComplete: false,
    );
    session.activeBox.value =
        await db.getCaptureBoxById(deviceId: 'station', boxId: boxId);
    session.activeFolder.value =
        (await db.getCaptureFolders(deviceId: 'station', boxId: boxId))
            .firstWhere((f) => f.id == folderId);

    // gallery_page.dart _syncNewDeviceImages: capture entry, a tick whose
    // listing fails, then a tick that lists the new photo and ingests it.
    expect(await ColorCaptureSession.begin('station'), isTrue);
    ColorCaptureSession.phoneUnavailable();
    adb.names = ['old.jpg', 'IMG_glitch.jpg'];
    expect(await ColorCaptureSession.begin('station'), isTrue);
    await session.assignNewImage('IMG_glitch.jpg');

    final raw = await db.getDatabase('station');
    final rows = await raw.query('color_bindings',
        where: 'image_name = ?', whereArgs: ['IMG_glitch.jpg']);
    expect(rows, hasLength(1));
    final stored = jsonDecode(rows.single['binding_json'] as String) as Map;
    expect(stored['profile'], isNotNull, reason: 'stored: $stored');
    auth.passwordController.dispose();
    auth.usernameController.dispose();
  });
}
