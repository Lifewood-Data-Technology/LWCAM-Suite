import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/controllers/color_calibration_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/pages/color_calibration_page.dart';
import 'package:lwcam/services/color_cal_service.dart';
import 'package:lwcam/services/adb_device_service.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:lwcam/theme/theme_controller.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

// Real dart:io work (temp dirs, file reads/writes) is wrapped in
// `TestWidgetsFlutterBinding.instance.runAsync` throughout this file.
// `testWidgets` bodies run inside a fake-time zone (see the stack trace
// under `package:fake_async` if this is ever reverted) where a directly
// awaited real I/O call — a plain `await file.writeAsString(...)`, no
// `runAsync` — never resolves: the test hangs indefinitely and, once
// killed, leaves the temp dir's file handle open, which is what turned
// into `_tempDir`'s teardown "being used by another process" error.
// `runAsync` steps outside that zone so real I/O actually completes.
Future<Directory> _tempDir(String prefix) async {
  final dir = await TestWidgetsFlutterBinding.instance.runAsync(
    () => Directory.systemTemp.createTemp(prefix),
  );
  addTearDown(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      if (await dir!.exists()) await dir.delete(recursive: true);
    });
  });
  return dir!;
}

/// `sessionAppBarActions` (the page's AppBar, always rendered) needs
/// `Get.find<AuthController>()` to resolve, but the real controller's
/// `onInit` fires unawaited real file I/O (`UsersStoreService.load()`,
/// which wraps a real file read in `Future.timeout(Duration(seconds: 8))`).
/// That timer is never awaited by anything here (fire-and-forget from
/// `onInit`), so it is a real hazard independent of the `runAsync` fix
/// above: a real `AuthController` on a slow/offline PC could leave that
/// 8s timeout still pending when a test tears down, tripping
/// flutter_test's "Timer still pending" leak assertion. This page's tests
/// never touch auth, so skip the real init rather than let it run.
class _NoPhone extends AdbDeviceService {
  @override
  Future<String?> deviceSerial() async => null;
}

class _NoInitAuthController extends AuthController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Future<File> _writeConfig(
  Directory dir, {
  required bool colorCalEnabled,
}) async {
  final file = File(p.join(dir.path, 'lwcam_node_config.json'));
  await TestWidgetsFlutterBinding.instance.runAsync(
    () => file.writeAsString(jsonEncode({'colorCalEnabled': colorCalEnabled})),
  );
  return file;
}

// ── Minimal pure-Dart PNG encoder ──────────────────────────────────────────
// `_CornerPicker` no longer decodes the image itself — imageSize comes from
// `controller.imageSize`, which the tests below set directly — so this
// fixture only needs to be a real file for `Image.file`'s (production)
// rendering. Building it via `dart:ui`'s `PictureRecorder`/`Image.toImage`
// was tried first and hangs forever under the plain widget-test binding (no
// raster thread services it) — this encodes raw solid-color RGB8 bytes by
// hand instead, so nothing here touches the rendering pipeline.

int _crc32(List<int> bytes) {
  const poly = 0xEDB88320;
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

Uint8List _pngChunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final out = BytesBuilder();
  out.add(_u32be(data.length));
  out.add(typeBytes);
  out.add(data);
  out.add(_u32be(_crc32([...typeBytes, ...data])));
  return out.toBytes();
}

Uint8List _u32be(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

/// A small real, solid-color PNG so `_CornerPicker` has genuine pixel
/// dimensions to measure.
Future<File> _writeTestImage(
  Directory dir, {
  required int width,
  required int height,
}) async {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type 0 (none) per scanline
    for (var x = 0; x < width; x++) {
      raw.add([0x80, 0x80, 0x80]); // solid mid-grey RGB8
    }
  }
  final idat = ZLibEncoder().convert(raw.toBytes());
  final ihdr = BytesBuilder()
    ..add(_u32be(width))
    ..add(_u32be(height))
    ..addByte(8) // bit depth
    ..addByte(2) // color type: RGB
    ..addByte(0) // compression
    ..addByte(0) // filter
    ..addByte(0); // interlace

  final png = BytesBuilder()
    ..add([137, 80, 78, 71, 13, 10, 26, 10])
    ..add(_pngChunk('IHDR', ihdr.toBytes()))
    ..add(_pngChunk('IDAT', idat))
    ..add(_pngChunk('IEND', const []));

  final file = File(p.join(dir.path, 'chart.png'));
  await TestWidgetsFlutterBinding.instance.runAsync(
    () => file.writeAsBytes(png.toBytes()),
  );
  return file;
}

Map<String, dynamic> _successProfile() => {
  'profile_id': 'p1',
  'created_at': '2026-09-11T08:00:00+08:00',
  'working_space': 'linear_srgb_d65',
  'white_balance': [1.0, 1.0, 1.0],
  'correction': {
    'type': 'matrix3x3',
    'matrix': [
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ],
    'applied_after_white_balance': true,
  },
  'stats': {
    'mean_de00': 1.234,
    'median_de00': 1.0,
    'max_de00': 3.5,
    'per_patch': [
      {'name': 'A1', 'de00': 0.5, 'clipped': false},
      {'name': 'B2', 'de00': 3.5, 'clipped': false},
      {'name': 'C3', 'de00': 1.2, 'clipped': true},
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    Get.testMode = true;
    SharedPreferences.setMockInitialValues({});
    tempDir = await _tempDir('cal_page_');
    UploadStatsDB().debugOverrideBaseFolderForTests(tempDir.path);
    Get.put<AuthController>(_NoInitAuthController());
    Get.put(ThemeController());
  });

  tearDown(Get.reset);

  // A desktop-sized surface — the result view's stat row + data table and
  // the corner picker both need real room, matching qc_review_page_test's
  // convention for pages laid out for a desktop window.
  void useDesktopSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<void> registerNodeConfig({required bool colorCalEnabled}) async {
    final configFile = await _writeConfig(
      tempDir,
      colorCalEnabled: colorCalEnabled,
    );
    final svc = NodeConfigService(getConfigPath: () => configFile.path);
    await TestWidgetsFlutterBinding.instance.runAsync(svc.load);
    Get.put(svc);
  }

  testWidgets('a disabled station renders the switched-off message', (
    tester,
  ) async {
    await registerNodeConfig(colorCalEnabled: false);

    await tester.pumpWidget(const MaterialApp(home: ColorCalibrationPage()));
    await tester.pump();

    expect(
      find.textContaining('Color calibration is switched off for this station'),
      findsOneWidget,
    );
  });

  testWidgets(
    'the result view shows the mean ΔE00 and orders patches worst first',
    (tester) async {
      useDesktopSurface(tester);
      await registerNodeConfig(colorCalEnabled: true);
      final controller = ColorCalibrationController(adbDeviceService: _NoPhone());
      Get.put(controller);
      controller.phase.value = CalPhase.result;
      controller.result.value = CalibrationSuccess(
        profilePath: p.join(tempDir.path, 'p1.json'),
        profile: _successProfile(),
      );

      await tester.pumpWidget(const MaterialApp(home: ColorCalibrationPage()));
      await tester.pump();

      expect(find.text('Mean ΔE00 1.23'), findsOneWidget);
      expect(find.text('Median ΔE00 1.00'), findsOneWidget);
      expect(find.text('Max ΔE00 3.50'), findsOneWidget);

      // Worst patch (B2, ΔE00 3.5) renders above the best (A1, ΔE00 0.5).
      final worst = tester.getTopLeft(find.text('B2'));
      final best = tester.getTopLeft(find.text('A1'));
      expect(worst.dy, lessThan(best.dy));
    },
  );

  testWidgets(
    'detectionFailed: 4 taps enable Analyse, mapped through the computed '
    'scale to source px',
    (tester) async {
      useDesktopSurface(tester);
      await registerNodeConfig(colorCalEnabled: true);
      const imgW = 200.0, imgH = 100.0;
      final image = await _writeTestImage(
        tempDir,
        width: imgW.round(),
        height: imgH.round(),
      );

      final controller = ColorCalibrationController(adbDeviceService: _NoPhone());
      Get.put(controller);
      controller.capturedImage.value = image;
      // Set directly rather than exercising the controller's own decode
      // (ColorCalibrationController._decodeImageSize, driven by start()) —
      // that's covered by its own unit coverage; this page test only cares
      // that the picker renders and maps taps correctly once a size exists.
      controller.imageSize.value = const Size(imgW, imgH);
      controller.phase.value = CalPhase.detectionFailed;
      controller.result.value = const CalibrationDetectionFailed(
        code: 'no_chart_found',
        message: 'No chart found.',
      );

      await tester.pumpWidget(const MaterialApp(home: ColorCalibrationPage()));
      await tester.pump();

      final analyseFinder = find.widgetWithText(
        FilledButton,
        'Analyse with these corners',
      );
      expect(analyseFinder, findsOneWidget);
      expect(tester.widget<FilledButton>(analyseFinder).onPressed, isNull);

      final tapAreaFinder = find.byKey(const Key('corner_picker_tap_area'));
      expect(tapAreaFinder, findsOneWidget);
      final rect = tester.getRect(tapAreaFinder);

      // Mirror _CornerPicker's own "contain" scale/centring math to compute
      // the expected SOURCE px for a tap.
      final scale = (rect.width / imgW < rect.height / imgH)
          ? rect.width / imgW
          : rect.height / imgH;
      final offX = (rect.width - imgW * scale) / 2;
      final offY = (rect.height - imgH * scale) / 2;

      final tapLocal = Offset(offX + 10, offY + 5);
      await tester.tapAt(rect.topLeft + tapLocal);
      await tester.pump();

      expect(controller.tappedCorners, hasLength(1));
      final expectedSrc = Offset(
        (tapLocal.dx - offX) / scale,
        (tapLocal.dy - offY) / scale,
      );
      expect(controller.tappedCorners.first.dx, closeTo(expectedSrc.dx, 1.5));
      expect(controller.tappedCorners.first.dy, closeTo(expectedSrc.dy, 1.5));

      // 3 more in-bounds taps reach 4 and enable Analyse.
      for (final local in [
        Offset(offX + imgW * scale - 10, offY + 5),
        Offset(offX + imgW * scale - 10, offY + imgH * scale - 5),
        Offset(offX + 10, offY + imgH * scale - 5),
      ]) {
        await tester.tapAt(rect.topLeft + local);
        await tester.pump();
      }

      expect(controller.tappedCorners, hasLength(4));
      expect(tester.widget<FilledButton>(analyseFinder).onPressed, isNotNull);
    },
  );
}
