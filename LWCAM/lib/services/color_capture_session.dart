import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'adb_device_service.dart';
import 'color_cal_service.dart';
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

class ColorCaptureSession {
  static String? _key;
  static ColorBinding? _binding;
  static Set<String> _before = {};
  static Future<bool>? _starting;
  static bool get enabled =>
      Get.isRegistered<NodeConfigService>() &&
      (Get.find<NodeConfigService>().cached?.colorCalEnabled ?? false);

  static void reset() {
    _key = null;
    _binding = null;
    _before = {};
  }

  static Future<void> skip(String deviceId) async {
    final adb = AdbDeviceService();
    final serial = await adb.deviceSerial();
    final before = await adb.listDeviceImageNames();
    final day = DateTime.now().toIso8601String().substring(0, 10);
    _key = '$deviceId|$serial|$day';
    _before = before?.toSet() ?? {};
    _binding = ColorBinding.none(
      serial == null || before == null ? 'historical' : 'skipped',
    );
  }

  static Future<bool> begin(String deviceId, {bool force = false}) {
    if (force) reset();
    return _starting ??= _begin(deviceId).whenComplete(() => _starting = null);
  }

  static Future<bool> _begin(String deviceId) async {
    if (!enabled) {
      _binding = ColorBinding.none('disabled');
      return true;
    }
    final adb = AdbDeviceService();
    final serial = await adb.deviceSerial();
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final key = '$deviceId|$serial|$day';
    if (serial != null && key == _key && _binding != null) return true;
    final before = await adb.listDeviceImageNames();
    final active = await ColorCalService().loadActive();
    if (serial != null &&
        active?.deviceId == deviceId &&
        active?.phoneSerial == serial &&
        ColorCalService.isCalibratedToday(active)) {
      final payload = jsonEncode({...active!.toJson(), 'schema_version': 1});
      _binding = ColorBinding(
        payload: payload,
        profile: sha256.convert(utf8.encode(payload)).toString(),
        reason: '',
        boundAt: DateTime.now().toIso8601String(),
      );
    } else {
      final skip = await Get.dialog<bool>(
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
      if (skip != true) return false;
      _binding = ColorBinding.none('skipped');
    }
    _key = key;
    _before = before?.toSet() ?? {};
    // An unreachable phone cannot establish a capture boundary.
    if (before == null || serial == null) {
      _binding = ColorBinding.none('historical');
    }
    return true;
  }

  static Future<ColorBinding> bindingFor(
    String deviceId,
    String filename,
  ) async {
    if (!enabled) return ColorBinding.none('disabled');
    if (!await begin(deviceId)) {
      throw StateError('Colour calibration requires operator attention');
    }
    if (_before.contains(filename)) return ColorBinding.none('historical');
    return _binding ?? ColorBinding.none('historical');
  }
}
