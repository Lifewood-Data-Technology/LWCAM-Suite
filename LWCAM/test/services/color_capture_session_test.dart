// Used only through run_capture_probe.py. ADB is fake; session logic is copied
// from the current production file without changing its state machine.
import 'dart:convert';
import 'dart:io';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/models/project.dart';
import 'package:lwcam/services/users_store_service.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/adb_device_service.dart';
import 'package:lwcam/services/color_cal_service.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:path/path.dart' as p;

import 'package:lwcam/services/color_capture_session.dart' as session;

class FakeAdb extends AdbDeviceService {
  String? serial = 'PHONE';
  List<String>? names;
  int serialCalls = 0;
  int listingCalls = 0;
  @override
  Future<String?> deviceSerial() async {
    serialCalls++;
    return serial;
  }

  @override
  Future<List<String>?> listDeviceImageNames() async {
    listingCalls++;
    return names;
  }
}

class KeyingStore extends UsersStoreService {
  KeyingStore() : super(getStorePath: () => 'unused');
  @override
  bool get metadataKeyingEnabled => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeAdb adb;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('review_session_');
    UploadStatsDB().debugOverrideBaseFolderForTests(root.path);
    final config = NodeConfigService(
      getConfigPath: () => p.join(root.path, 'node.json'),
    );
    await config.save(const NodeConfig(colorCalEnabled: true));
    Get.put<NodeConfigService>(config);
    final now = DateTime.now();
    final active = ActiveProfile(
      profileId: 'fixture',
      profilePath: 'fixture.json',
      calibratedAt: now,
      calibratedAtRaw: now.toIso8601String(),
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
    // ColorCalService defaults to device "default" with no AuthController.
    final key = base64Url.encode(utf8.encode('default')).replaceAll('=', '');
    final file = File(p.join(root.path, 'color_cal', key, 'active.json'));
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(active.toJson()));
    expect(await ColorCalService().loadActive(), isNotNull);
    adb = FakeAdb();
    session.ColorCaptureSession.adbFactory = () => adb;
    session.ColorCaptureSession.reset();
  });
  tearDown(() async {
    session.ColorCaptureSession.reset();
    session.ColorCaptureSession.adbFactory = AdbDeviceService.new;
    Get.reset();
    await root.delete(recursive: true);
  });
  test('Auth capture entry refuses an unestablished phone boundary', () async {
    final auth = AuthController()..usersStore = KeyingStore();
    auth.deviceId.value = 'station';
    final project = Project(key: 'p', projectId: 'P', name: 'Project', startDate: DateTime.now());
    adb.names = null;
    expect(await auth.enterCaptureWithProject(project, calibrationConfirmed: true), isFalse);
    expect(adb.listingCalls, 1);
    auth.passwordController.dispose();
    auth.usernameController.dispose();
  });
  test('failed first listing can retry without explicit reset', () async {
    adb.names = null;
    expect(await session.ColorCaptureSession.begin('station'), isFalse);
    adb.names = ['old.jpg'];
    final binding = await session.ColorCaptureSession.bindingFor(
      'station',
      'new.jpg',
    );
    expect(binding.profile, isNotNull);
    expect(adb.listingCalls, 2);
    session.ColorCaptureSession.reset();
    final retried = await session.ColorCaptureSession.bindingFor(
      'station',
      'new.jpg',
    );
    expect(retried.profile, isNotNull);
  });
  test('binding batches reuse the capture entry serial', () async {
    adb.names = ['old.jpg'];
    expect(await session.ColorCaptureSession.begin('station'), isTrue);
    expect(
      (await session.ColorCaptureSession.bindingFor(
        'station',
        'one.jpg',
      )).profile,
      isNotNull,
    );
    expect(
      (await session.ColorCaptureSession.bindingFor(
        'station',
        'two.jpg',
      )).profile,
      isNotNull,
    );
    expect(adb.serialCalls, 1);
    expect(adb.listingCalls, 1);
  });
}
