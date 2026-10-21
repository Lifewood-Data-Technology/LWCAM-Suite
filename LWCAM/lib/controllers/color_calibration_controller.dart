// ignore_for_file: avoid_print

// Controller behind the colour calibration page in the capture app (LWCAM):
// launches the phone camera, waits for a shot of the calibration chart, pulls
// it, and hands it to ColorCalService for analysis. This is the calibration
// step that runs before capture starts.
// Things to know before editing: one instance per page visit (the page puts
// and deletes it), not a permanent singleton; CalPhase drives what the page
// shows.

import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset, Size, instantiateImageCodec;

import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../auth/auth_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/project.dart';
import '../services/adb_device_service.dart';
import '../services/color_cal_service.dart';
import '../services/color_capture_session.dart';
import '../services/snackbar_service.dart';

/// Where the calibration flow currently stands (WP-D5). Roughly a state
/// machine driven by [ColorCalibrationController.start] and the directory-task outcome.
enum CalPhase {
  idle,
  launchingCamera,
  waitingForShot,
  pulling,
  analysing,
  result,
  detectionFailed,
  manualCorners,
  error,
}

/// Drives the calibration capture + analyse flow shown by
/// `ColorCalibrationPage`. One instance per page visit — the page does
/// `Get.put`/`Get.delete` around it (like `BoxSessionController`'s per-session
/// lifetime), not a permanent singleton.
///
/// `start()` is `gallery_page.dart`'s `_startRecaptureForSlot` minus the
/// device-slot swap: snapshot the device's file list, launch the camera, wait
/// for a new capture, pull it, then hand it to `ColorCalService`.
class ColorCalibrationController extends GetxController {
  ColorCalibrationController({
    this.resumeProject,
    AdbDeviceService? adbDeviceService,
    ColorCalService? colorCalService,
  }) : _adb = adbDeviceService ?? AdbDeviceService(),
       _colorCal = colorCalService ?? ColorCalService();

  /// Set when this page was reached through the capture-entry gate
  /// ("Calibrate now") rather than the project-area card. When set, **Save &
  /// activate** and **Continue without calibrating** both resume capture into
  /// this project (`AuthController.enterCaptureWithProject`) instead of
  /// merely popping the page.
  final Project? resumeProject;

  final AdbDeviceService _adb;
  final ColorCalService _colorCal;

  @override
  void onClose() {
    _cancelled = true;
    _colorCal.cancel();
    super.onClose();
  }

  final phase = CalPhase.idle.obs;
  final status = ''.obs;
  final capturedImage = Rxn<File>();
  final imageSize = Rxn<Size>();
  final result = Rxn<CalibrationResult>();

  /// Tapped corners in source-image px, order TL,TR,BR,BL.
  final tappedCorners = <Offset>[].obs;

  /// The profile active before this session started — read once on init so
  /// the idle view can show "last calibrated `<date>`, mean ΔE00 `<x>`".
  final lastActive = Rxn<ActiveProfile>();

  bool _cancelled = false;
  int _operation = 0;
  String? _captureDevice;
  String? _captureOperator;
  String? _phoneSerial;
  DateTime? _capturedAt;
  final pending = Rxn<Map<String, dynamic>>();

  Future<void> refreshPending() async {
    try {
      final serial = await _adb.deviceSerial();
      if (serial != null && !isClosed) {
        pending.value = await _colorCal.pendingTask(serial);
      }
    } catch (_) {
      /* The saved task remains available on the next visit. */
    }
  }

  Future<void> resumePending() async {
    final task = pending.value;
    if (task == null) return;
    if (task['device_id'] != _deviceId ||
        task['phone_serial'] != await _adb.deviceSerial()) {
      phase.value = CalPhase.error;
      status.value = 'The device or phone changed. Retake the chart.';
      return;
    }
    _cancelled = false;
    final operation = ++_operation;
    _colorCal.cancel();
    _captureDevice = task['device_id'] as String;
    _captureOperator = task['operator'] as String;
    _phoneSerial = task['phone_serial'] as String;
    _capturedAt = DateTime.parse(task['captured_at'] as String);
    final image = File(p.join(task['local_path'] as String, 'chart.jpg'));
    capturedImage.value = image;
    unawaited(_decodeImageSize(image));
    phase.value = CalPhase.analysing;
    _showOutcome(
      await _colorCal.resumeTask(task, onWaiting: (message) => _waiting(operation, message)),
      operation,
    );
  }

  void _waiting(int operation, String message) {
    if (!_cancelled && !isClosed && operation == _operation) status.value = message;
  }

  @override
  void onInit() {
    super.onInit();
    unawaited(_loadLastActive());
    unawaited(refreshPending());
  }

  Future<void> _loadLastActive() async {
    lastActive.value = await _colorCal.loadActive();
  }

  /// Where the pulled chart photo lands before being submitted to LWIP.
  /// `ColorCalService` doesn't expose its own `captures\` subdir publicly, so
  /// this mirrors the same `<base>\color_cal\captures\` layout its class doc
  /// comment describes rather than reaching into its private internals.
  Future<Directory> _capturesDir() async {
    final base = await UploadStatsDB().getBaseFolder();
    final dir = Directory(p.join(base, 'color_cal', 'captures'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String get _deviceId => Get.find<AuthController>().deviceId.value;
  String get _operator =>
      Get.find<AuthController>().currentUser.value?.username ?? '';

  Future<void> start() async {
    final operation = ++_operation;
    _colorCal.cancel();
    _cancelled = false;
    _captureDevice = _deviceId;
    _captureOperator = _operator;
    tappedCorners.clear();
    result.value = null;
    capturedImage.value = null;
    imageSize.value = null;

    ColorCaptureSession.reset();
    _phoneSerial = await _adb.deviceSerial();
    final before = await _adb.listDeviceImageNames();
    if (operation != _operation || isClosed) return;
    if (before == null) {
      phase.value = CalPhase.error;
      status.value = 'Phone not reachable. Check the USB/ADB connection.';
      return;
    }

    phase.value = CalPhase.launchingCamera;
    status.value = 'Launching the camera…';

    // Started before the launch resolves so a fast operator's photo is
    // caught the instant it lands, same reasoning as the gallery recapture.
    final newNameFuture = _adb.waitForNewCapture(
      before.toSet(),
      isCancelled: () => _cancelled || operation != _operation,
    );

    final launched = await _adb.launchCameraProMode(
      onProModeUnverified: (warning) => status.value = warning,
    );
    if (operation != _operation || isClosed) return;
    if (!launched) {
      _cancelled = true;
      await newNameFuture;
      phase.value = CalPhase.error;
      status.value = 'Could not launch the camera.';
      return;
    }

    phase.value = CalPhase.waitingForShot;
    status.value =
        'Photograph the SpyderCheckr card filling the frame, then '
        'return here.';

    final newName = await newNameFuture;
    if (operation != _operation || isClosed) return;
    if (newName == null) {
      if (_cancelled) {
        phase.value = CalPhase.idle;
        status.value = '';
      } else {
        phase.value = CalPhase.error;
        status.value = 'No new capture was detected on the device.';
      }
      return;
    }

    _capturedAt = DateTime.now();
    phase.value = CalPhase.pulling;
    status.value = 'Pulling the photo…';
    final file = await _adb.pullSingleFile(
      newName,
      targetDir: await _capturesDir(),
    );
    if (operation != _operation || isClosed) return;
    if (file == null) {
      phase.value = CalPhase.error;
      status.value = 'Could not pull the photo from the device.';
      return;
    }
    capturedImage.value = file;
    // Fire-and-forget: the manual-corner picker (_CornerPicker) reads
    // imageSize reactively and shows "image size unknown" until this
    // lands, so analysis need not wait on it.
    unawaited(_decodeImageSize(file));

    await _bringToFront();
    await _analyse(image: file);
  }

  /// Decodes [file]'s pixel dimensions for the manual-corner picker (source
  /// px, matching what the CLI's `--corners` expects — same frame
  /// `Image.file`'s decoder and the CLI both apply EXIF orientation in).
  /// Never throws: a bad file just leaves [imageSize] null, and the picker
  /// shows "image size unknown" with taps disabled rather than crashing.
  Future<void> _decodeImageSize(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      imageSize.value = Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
    } catch (_) {
      // Leave imageSize null.
    }
  }

  Future<void> _bringToFront() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      print('⚠️ Failed to focus app window: $e');
    }
  }

  Future<void> _analyse({
    required File image,
    List<Offset>? corners,
    bool force = false,
  }) async {
    if (_cancelled || isClosed) return;
    final operation = ++_operation;
    phase.value = CalPhase.analysing;
    status.value = 'Analysing the chart…';
    final outcome = await _colorCal.runCalibration(
      image: image,
      corners: corners,
      force: force,
      deviceId: _captureDevice ?? _deviceId,
      operator: _captureOperator ?? _operator,
      phoneSerial: _phoneSerial,
      capturedAt: _capturedAt,
      onWaiting: (message) => _waiting(operation, message),
    );
    unawaited(refreshPending());
    _showOutcome(outcome, operation);
  }

  void _showOutcome(CalibrationResult outcome, int operation) {
    if (_cancelled || isClosed || operation != _operation) return;
    result.value = outcome;
    switch (outcome) {
      case CalibrationSuccess():
        phase.value = CalPhase.result;
        status.value = '';
      case CalibrationDetectionFailed():
        phase.value = CalPhase.detectionFailed;
        status.value = outcome.message;
      case CalibrationError():
        phase.value = CalPhase.error;
        status.value = outcome.message;
    }
  }

  /// Stops waiting for a shot / cancels the poll in flight. Does not undo an
  /// analysis already in progress or completed.
  void cancel() {
    _operation++;
    _cancelled = true;
    _colorCal.cancel();
    phase.value = CalPhase.idle;
    status.value = 'Stopped waiting. Submitted tasks remain on LWIP.';
    unawaited(refreshPending());
  }

  void addCorner(Offset point) {
    if (tappedCorners.length >= 4) return;
    tappedCorners.add(point);
  }

  void clearCorners() => tappedCorners.clear();

  /// Submits a new task with the 4 tapped corners (TL,TR,BR,BL), forcing manual
  /// corner mode.
  Future<void> analyseWithCorners() async {
    final image = capturedImage.value;
    if (image == null || tappedCorners.length != 4) return;
    await _analyse(image: image, corners: List<Offset>.of(tappedCorners));
  }

  /// Only meaningful from a `low_confidence` [CalibrationDetectionFailed] —
  /// re-runs over the same auto-detected quad with `--force`.
  Future<void> useDetectedAnyway() async {
    final image = capturedImage.value;
    final current = result.value;
    if (image == null || current is! CalibrationDetectionFailed) return;
    if (current.code != 'low_confidence') return;
    await _analyse(image: image, force: true);
  }

  Future<void> retake() => start();

  /// Saves the profile as active, then resumes capture (when [resumeProject]
  /// is set) or leaves the page.
  Future<void> saveAndActivate() async {
    final success = result.value;
    if (success is! CalibrationSuccess) return;
    final active = ActiveProfile.fromProfileJson(
      success.profile,
      success.profilePath,
    );
    if (_phoneSerial == null || await _adb.deviceSerial() != _phoneSerial) {
      phase.value = CalPhase.error;
      status.value = 'The phone changed or disconnected. Retake the chart.';
      return;
    }
    final bound = ActiveProfile.fromJson({
      ...active.toJson(),
      'phone_serial': _phoneSerial,
    });
    if (bound.deviceId != _deviceId) {
      phase.value = CalPhase.error;
      status.value = 'The station changed. Retake the chart.';
      return;
    }
    try {
      await _colorCal.setActive(bound);
    } catch (e) {
      phase.value = CalPhase.error;
      status.value = 'Cannot activate calibration. Retake the chart. $e';
      return;
    }
    ColorCaptureSession.reset();
    showAppSnackBar('Calibration saved', 'Profile activated for today.');
    await _continue();
  }

  /// Leaves calibration without activating a profile.
  Future<void> continueWithoutCalibrating() async {
    cancel();
    await ColorCaptureSession.skip(_deviceId);
    await _continue();
  }

  /// Both branches leave this page. The [resumeProject] branch calls
  /// `enterCaptureWithProject`, which routes via `Get.off`/`Get.offNamed` —
  /// a route REPLACEMENT, not a pop — so `ColorCalibrationPage`'s
  /// `PopScope.onPopInvokedWithResult` (its usual `Get.delete`) never fires.
  /// Left alone, the next "Calibrate now" visit's `Get.put` would return
  /// this stale instance (its phase/result/resumeProject already spent)
  /// instead of a fresh one. So delete explicitly here, right before
  /// navigating away, in BOTH branches — PopScope's delete stays as a
  /// fallback for any other way off this page. Delete first, navigate
  /// second: nothing below this point may read `this`'s Rx fields, since
  /// deleting runs `onClose()` on them.
  Future<void> _continue() async {
    final project = resumeProject;
    if (Get.isRegistered<ColorCalibrationController>()) {
      Get.delete<ColorCalibrationController>();
    }
    if (project != null) {
      await Get.find<AuthController>().enterCaptureWithProject(
        project,
        calibrationConfirmed: true,
      );
    } else {
      Get.back();
    }
  }
}
