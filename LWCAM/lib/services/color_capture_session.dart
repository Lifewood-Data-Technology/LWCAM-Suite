import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'adb_device_service.dart';
import 'color_cal_service.dart';
import 'calibration_gate.dart';
import 'node_config_service.dart';

/// Captured values travel with the image; transfer never reads active.json.
class ColorBinding {
  final String? payload;
  final String? profile;
  final String reason;
  final String boundAt;
  const ColorBinding({
    this.payload,
    this.profile,
    required this.reason,
    required this.boundAt,
  });
  factory ColorBinding.none(String reason) =>
      ColorBinding(reason: reason, boundAt: DateTime.now().toIso8601String());
  factory ColorBinding.fromJson(Map<String, dynamic> data) => ColorBinding(
    payload: data['payload'] as String?,
    profile: data['profile'] as String?,
    reason: data['reason'] as String? ?? 'historical',
    boundAt: data['bound_at'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'payload': payload,
    'profile': profile,
    'reason': reason,
    'bound_at': boundAt,
  };
  Map<String, dynamic> marker() => {
    'profile': profile,
    if (profile == null) 'reason': reason,
    'bound_at': boundAt,
  };
}

/// One established capture boundary: the phone, the day, the photos that were
/// already on the phone when it was set up, and the operator's decision.
class _CaptureBoundary {
  final String deviceId;
  final String serial;
  final String day;
  final Set<String> before;
  final ColorBinding binding;
  const _CaptureBoundary(
    this.deviceId,
    this.serial,
    this.day,
    this.before,
    this.binding,
  );
}

/// Which colour binding a newly captured page gets.
///
/// States: no boundary yet; a boundary that is verified (the phone answered
/// with the same serial today); and a boundary that is temporarily unverified
/// (a serial or listing probe failed). While unverified, [begin] returns false
/// and callers pause ingestion, so no page is bound until the phone is
/// identified again. The boundary is kept: when the same phone comes back the
/// same day, its photos taken meanwhile still get the session's decision
/// (calibrated or skipped) rather than `historical`. A different serial or a
/// new day sets up a new boundary, so one phone's profile never reaches
/// another. Only an explicit operator action ([reset], [skip], recalibration)
/// replaces a boundary otherwise.
class ColorCaptureSession {
  @visibleForTesting
  static AdbDeviceService Function() adbFactory = AdbDeviceService.new;
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Asks the operator whether to continue without colour correction.
  @visibleForTesting
  static Future<bool?> Function() promptWithoutCorrection = _askOperator;

  static _CaptureBoundary? _boundary;
  static bool _verified = false;
  static Future<bool>? _starting;
  static bool get enabled =>
      Get.isRegistered<NodeConfigService>() &&
      (Get.find<NodeConfigService>().cached?.colorCalEnabled ?? false);

  static String _today() => clock().toIso8601String().substring(0, 10);

  /// Ends the boundary on an explicit operator action (a new profile saved,
  /// recalibration). The next [begin] sets up a new one.
  static void reset() {
    _boundary = null;
    _verified = false;
  }

  /// A probe outside [begin] (the live-sync listing) could not reach the phone.
  /// Keeps the boundary but requires the next [begin] to identify the phone
  /// before any page is bound.
  static void phoneUnavailable() {
    _verified = false;
  }

  /// The operator chose to continue without correction for this phone today.
  static Future<void> skip(String deviceId) async {
    final adb = adbFactory();
    final serial = await adb.deviceSerial();
    final before = await adb.listDeviceImageNames();
    if (before == null || serial == null) {
      throw StateError('Phone unavailable; reconnect before continuing capture');
    }
    _boundary = _CaptureBoundary(
      deviceId,
      serial,
      _today(),
      before.toSet(),
      ColorBinding.none('skipped'),
    );
    _verified = true;
  }

  /// Verifies (or sets up) the boundary before pages are bound. False means
  /// do not ingest now: the phone could not be identified, or the operator
  /// went back instead of choosing.
  static Future<bool> begin(String deviceId, {bool force = false}) {
    if (force) reset();
    return _starting ??= _begin(deviceId).whenComplete(() => _starting = null);
  }

  static Future<bool> _begin(String deviceId) async {
    if (!enabled) {
      reset();
      return true;
    }
    final adb = adbFactory();
    final serial = await adb.deviceSerial();
    if (serial == null) {
      // Unknown phone: never bind, never discard an established boundary.
      _verified = false;
      return false;
    }
    final day = _today();
    final current = _boundary;
    if (current != null &&
        current.deviceId == deviceId &&
        current.serial == serial &&
        current.day == day) {
      _verified = true;
      return true;
    }
    // First boundary, a different phone, another station id, or a new day.
    _verified = false;
    final before = await adb.listDeviceImageNames();
    if (before == null) return false;
    final ColorBinding binding;
    final active = await ColorCalService().loadActive();
    if (active?.deviceId == deviceId &&
        active?.phoneSerial == serial &&
        evaluateCalibrationGate(enabled: true, active: active) == CalibrationGate.calibratedToday) {
      final payload = jsonEncode({...active!.toJson(), 'schema_version': 1});
      binding = ColorBinding(
        payload: payload,
        profile: sha256.convert(utf8.encode(payload)).toString(),
        reason: '',
        boundAt: clock().toIso8601String(),
      );
    } else {
      if (await promptWithoutCorrection() != true) return false;
      binding = ColorBinding.none('skipped');
    }
    _boundary = _CaptureBoundary(deviceId, serial, day, before.toSet(), binding);
    _verified = true;
    return true;
  }

  static Future<bool?> _askOperator() => Get.dialog<bool>(
    AlertDialog(
      title: const Text('No valid colour calibration'),
      content: const Text(
        'This phone has no verified calibration for today. Continue without colour correction, or go back and calibrate.',
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: () => Get.back(result: true),
          child: const Text('Continue without correction'),
        ),
      ],
    ),
    barrierDismissible: false,
  );

  static Future<ColorBinding> bindingFor(
    String deviceId,
    String filename,
  ) async {
    if (!enabled) return ColorBinding.none('disabled');
    final current = _boundary;
    if ((!_verified ||
            current == null ||
            current.deviceId != deviceId ||
            current.day != _today()) &&
        !await begin(deviceId)) {
      throw StateError('Colour calibration requires operator attention');
    }
    final boundary = _boundary!;
    if (boundary.before.contains(filename)) return ColorBinding.none('historical');
    return boundary.binding;
  }
}
