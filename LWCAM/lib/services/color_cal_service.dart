// ignore_for_file: avoid_print

// Capture submits immutable directory tasks; LWIP owns colour analysis.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:path/path.dart' as p;

import '../db/upload_stats_db.dart';
import 'safe_copy.dart';
import 'calibration_task_client.dart';
import 'node_config_service.dart';
import 'adb_device_service.dart';
import 'package:get/get.dart';
import '../auth/auth_controller.dart';

/// Submits SpyderCheckr Photo tasks and stores confirmed station-scoped state.
/// The capture session copies the profile into its durable per-page binding.
class ColorCalService {
  final String? destinationOverride;
  final Directory? localOverride;
  CalibrationTaskClient? _client;
  ColorCalService({this.destinationOverride, this.localOverride});
  void cancel() => _client?.cancel();

  Future<CalibrationTaskClient> _tasks() async {
    return _client ??= CalibrationTaskClient(
      localOverride ?? Directory(p.join(await _baseDir(), 'tasks')),
      destinationOverride ??
          (Get.isRegistered<NodeConfigService>()
              ? Get.find<NodeConfigService>().cached?.destinationPath ?? ''
              : ''),
    );
  }

  Future<Map<String, dynamic>?> pendingTask(String serial) async =>
      (await _tasks()).pending(serial);

  // ── Directories ──────────────────────────────────────────────────────

  Future<String> _baseDir() async {
    final base = await UploadStatsDB().getBaseFolder();
    final device = Get.isRegistered<AuthController>()
        ? Get.find<AuthController>().deviceId.value
        : 'default';
    final key = base64Url.encode(utf8.encode(device)).replaceAll('=', '');
    return p.join(base, 'color_cal', key);
  }

  Future<String> _activePath() async => p.join(await _baseDir(), 'active.json');

  // ── Active profile ───────────────────────────────────────────────────

  /// Never throws: a missing or corrupt `active.json` reads as "no active
  /// profile" rather than blocking the caller.
  Future<ActiveProfile?> loadActive() async {
    try {
      final file = File(await _activePath());
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map) return null;
      final profile = ActiveProfile.fromJson(Map<String, dynamic>.from(data));
      if (profile.sourceTask == null || profile.phoneSerial == null || profile.deviceId == null) return null;
      CalibrationTaskClient.validateProfile({...profile.toJson(), 'schema_version': 1});
      return profile;
    } catch (_) {
      return null;
    }
  }

  /// Tmp + rename, like `processing_marker_service.dart`'s `_writeMarkerAtomic`.
  Future<void> setActive(ActiveProfile profile) async {
    if (profile.sourceTask == null || !isCalibratedToday(profile)) {
      throw StateError('A current directory-task result is required');
    }
    final serial = profile.phoneSerial;
    if (serial == null) throw StateError('Calibration phone is missing');
    final pending = await (await _tasks()).pending(serial);
    if (pending?['task_id'] != profile.sourceTask?['task_id']) {
      throw StateError('Calibration task superseded');
    }
    final verified = await (await _tasks()).readResult(pending!);
    if (verified?['ok'] != true ||
        (verified?['profile'] as Map?)?['profile_id'] != profile.profileId) {
      throw StateError('Calibration result no longer valid');
    }
    final checked = ActiveProfile.fromProfileJson(
      Map<String, dynamic>.from(verified!['profile'] as Map),
      verified['profile_path'] as String,
    );
    if (jsonEncode(checked.toJson()) != jsonEncode(profile.toJson()) ||
        profile.sourceTask!['capture_local_date'] !=
            DateTime.now().toIso8601String().substring(0, 10)) {
      throw StateError('Calibration parameters or capture date changed');
    }
    final dir = Directory(await _baseDir());
    if (!await dir.exists()) await dir.create(recursive: true);
    final targetPath = await _activePath();
    await writeStringAtomic(targetPath, jsonEncode(profile.toJson()));
    await (await _tasks()).accepted(
      serial,
      profile.sourceTask!['task_id'] as String,
    );
  }

  /// Whether [profile] was calibrated on the same LOCAL calendar day as
  /// [now] (defaults to `DateTime.now()`). A profile calibrated with an
  /// offset timestamp is compared after converting to local time, not by
  /// UTC date — a calibration at 23:59 local yesterday must read as stale
  /// today even if its UTC date is still "today" somewhere else.
  static bool isCalibratedToday(ActiveProfile? profile, {DateTime? now}) {
    if (profile == null) return false;
    final at = profile.calibratedAt.toLocal();
    final today = (now ?? DateTime.now()).toLocal();
    return at.year == today.year &&
        at.month == today.month &&
        at.day == today.day;
  }

  /// Legacy fragment helper. New markers use frozen per-page bindings, not
  /// this transfer-time date calculation.
  static Map<String, dynamic>? colorProfileStamp(
    ActiveProfile? profile, {
    DateTime? now,
  }) {
    if (profile == null) return null;
    return {
      'profile_id': profile.profileId,
      'calibrated_at': profile.calibratedAtRaw,
      'calibrated_today': isCalibratedToday(profile, now: now),
      'working_space': profile.workingSpace,
      'white_balance': profile.whiteBalance,
      'correction': profile.correction,
    };
  }

  // ── Directory tasks ──────────────────────────────────────────────────

  /// Submits [image] to LWIP (a photographed SpyderCheckr
  /// Photo chart). [corners] (TL,TR,BR,BL, source px) forces manual corner
  /// mode instead of auto-detection. Never throws — every failure path
  /// returns a typed [CalibrationResult].
  Future<CalibrationResult> runCalibration({
    required File image,
    List<Offset>? corners,
    bool force = false,
    required String deviceId,
    required String operator,
    String? phoneSerial,
    DateTime? capturedAt,
    void Function(String)? onWaiting,
  }) async {
    try {
      final serial = phoneSerial ?? await AdbDeviceService().deviceSerial();
      if (serial == null) {
        return const CalibrationError(
          'phone_missing',
          'Connect the calibration phone first.',
        );
      }
      final captured = (capturedAt ?? DateTime.now()).toLocal();
      final offset = captured.timeZoneOffset;
      final zone =
          '${offset.isNegative ? '-' : '+'}${offset.inHours.abs().toString().padLeft(2, '0')}:${(offset.inMinutes.abs() % 60).toString().padLeft(2, '0')}';
      final tasks = await _tasks();
      final task = await tasks.submit(image, {
        'device_id': deviceId,
        'phone_serial': serial,
        'operator': operator,
        'captured_at': '${captured.toIso8601String()}$zone',
        'capture_local_date': captured.toIso8601String().substring(0, 10),
        'analysis': {
          'force': force,
          if (corners != null)
            'corners': corners.map((c) => [c.dx, c.dy]).toList(),
        },
      });
      return await resumeTask(task, onWaiting: onWaiting);
    } catch (e) {
      return CalibrationError('submission_error', '$e');
    }
  }

  Future<CalibrationResult> resumeTask(
    Map<String, dynamic> task, {
    void Function(String)? onWaiting,
  }) async {
    try {
      final data = await (await _tasks()).wait(task, onWaiting: onWaiting);
      return _decode(data);
    } catch (e) {
      return CalibrationError('task_error', '$e');
    }
  }

  CalibrationResult _decode(Map<String, dynamic> data) {
    // Result fields remain untrusted after their transport hashes are verified. A shape
    // that doesn't match what's expected here (wrong type for a field,
    // 'error'/'detection' not a Map, …) must not crash the caller with a
    // raw TypeError.
    try {
      if (data['ok'] == true) {
        return CalibrationSuccess(
          profilePath: data['profile_path'] as String,
          profile: Map<String, dynamic>.from(
            data['profile'] as Map? ?? const {},
          ),
          detection: (data['detection'] as Map?)?.cast<String, dynamic>(),
          detectedPng: _fileFromDebug(data, 'detected_png'),
          rectifiedPng: _fileFromDebug(data, 'rectified_png'),
          warnings:
              (data['warnings'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
        );
      }

      final error =
          (data['error'] as Map?)?.cast<String, dynamic>() ?? const {};
      final code = (error['code'] as String?) ?? 'io_error';
      final message = (error['message'] as String?) ?? 'color_cal_tool failed.';
      final detection = (data['detection'] as Map?)?.cast<String, dynamic>();

      const detectionCodes = {
        'no_chart_found',
        'low_confidence',
        'clipped_patches',
        'fit_failed',
      };
      if (detectionCodes.contains(code)) {
        return CalibrationDetectionFailed(
          code: code,
          message: message,
          quad: _quadFromDetection(detection),
          detectedPng: _fileFromDebug(data, 'detected_png'),
        );
      }

      return CalibrationError(code, message);
    } catch (e) {
      return CalibrationError(
        'bad_output',
        'Calibration tool returned malformed JSON: $e',
      );
    }
  }

  File? _fileFromDebug(Map<String, dynamic> data, String key) {
    final debug = data['debug'] as Map?;
    final value = debug?[key];
    if (value is! String || value.isEmpty) return null;
    return File(value);
  }

  List<Offset>? _quadFromDetection(Map<String, dynamic>? detection) {
    final quad = detection?['quad'];
    if (quad is! List) return null;
    try {
      return quad
          .map(
            (pt) => Offset(
              ((pt as List)[0] as num).toDouble(),
              (pt[1] as num).toDouble(),
            ),
          )
          .toList();
    } catch (_) {
      return null;
    }
  }
}

/// Active station profile, copied into per-page bindings at capture time.
class ActiveProfile {
  final String profileId;
  final String profilePath;
  final DateTime calibratedAt;

  /// [calibratedAt]'s ORIGINAL capture-PC string, verbatim — `created_at` in the
  /// profile JSON / `calibrated_at` in `active.json`. `calibratedAt` is
  /// parsed for date comparisons (`isCalibratedToday`); this is what gets
  /// re-emitted (`toJson`, `colorProfileStamp`) so an offset timestamp
  /// isn't silently re-serialised as UTC `Z` by `DateTime.toIso8601String`.
  final String calibratedAtRaw;
  final String? deviceId;
  final String? operator;
  final String? phoneSerial;
  final Map<String, dynamic>? sourceTask;
  final String workingSpace;
  final List<double> whiteBalance;
  final Map<String, dynamic> correction;
  final double? meanDe00;

  const ActiveProfile({
    required this.profileId,
    required this.profilePath,
    required this.calibratedAt,
    required this.calibratedAtRaw,
    this.deviceId,
    this.operator,
    this.phoneSerial,
    this.sourceTask,
    required this.workingSpace,
    required this.whiteBalance,
    required this.correction,
    this.meanDe00,
  });

  Map<String, dynamic> toJson() => {
    'profile_id': profileId,
    'profile_path': profilePath,
    'calibrated_at': calibratedAtRaw,
    'device_id': deviceId,
    'operator': operator,
    'phone_serial': phoneSerial,
    'source_task': sourceTask,
    'working_space': workingSpace,
    'white_balance': whiteBalance,
    'correction': correction,
    'mean_de00': meanDe00,
  };

  factory ActiveProfile.fromJson(Map<String, dynamic> json) => ActiveProfile(
    profileId: json['profile_id'] as String,
    profilePath: json['profile_path'] as String,
    calibratedAt: DateTime.parse(json['calibrated_at'] as String),
    calibratedAtRaw: json['calibrated_at'] as String,
    deviceId: json['device_id']?.toString(),
    operator: json['operator']?.toString(),
    phoneSerial: json['phone_serial']?.toString(),
    sourceTask: (json['source_task'] as Map?)?.cast<String, dynamic>(),
    workingSpace: json['working_space']?.toString() ?? 'linear_srgb_d65',
    whiteBalance: (json['white_balance'] as List)
        .map((e) => (e as num).toDouble())
        .toList(),
    correction: Map<String, dynamic>.from(json['correction'] as Map),
    meanDe00: (json['mean_de00'] as num?)?.toDouble(),
  );

  /// Builds an [ActiveProfile] from the verified `CalibrationSuccess.profile`
  /// and local cached profile path, including capture task provenance. It is
  /// written to — used when the operator hits "Save & activate".
  factory ActiveProfile.fromProfileJson(
    Map<String, dynamic> profile,
    String profilePath,
  ) {
    final camera = profile['camera'] as Map?;
    final stats = profile['stats'] as Map?;
    final createdAt = profile['created_at'] as String;
    return ActiveProfile(
      profileId: profile['profile_id'] as String,
      profilePath: profilePath,
      calibratedAt: DateTime.parse(createdAt),
      calibratedAtRaw: createdAt,
      deviceId: camera?['device_id']?.toString(),
      operator: profile['operator']?.toString(),
      phoneSerial: profile['phone_serial']?.toString(),
      sourceTask: (profile['source_task'] as Map?)?.cast<String, dynamic>(),
      workingSpace: profile['working_space']?.toString() ?? 'linear_srgb_d65',
      whiteBalance: (profile['white_balance'] as List)
          .map((e) => (e as num).toDouble())
          .toList(),
      correction: Map<String, dynamic>.from(profile['correction'] as Map),
      meanDe00: (stats?['mean_de00'] as num?)?.toDouble(),
    );
  }
}

/// Outcome of [ColorCalService.runCalibration].
sealed class CalibrationResult {
  const CalibrationResult();
}

/// `ok:true` — a profile was written.
class CalibrationSuccess extends CalibrationResult {
  final String profilePath;
  final Map<String, dynamic> profile;
  final Map<String, dynamic>? detection;
  final File? detectedPng;
  final File? rectifiedPng;
  final List<String> warnings;

  const CalibrationSuccess({
    required this.profilePath,
    required this.profile,
    this.detection,
    this.detectedPng,
    this.rectifiedPng,
    this.warnings = const [],
  });
}

/// Analysis failure: `no_chart_found | low_confidence | clipped_patches | fit_failed`.
/// Recoverable via manual corners or (for `low_confidence`) `--force`.
class CalibrationDetectionFailed extends CalibrationResult {
  final String code;
  final String message;
  final List<Offset>? quad;
  final File? detectedPng;

  const CalibrationDetectionFailed({
    required this.code,
    required this.message,
    this.quad,
    this.detectedPng,
  });
}

/// A protocol, transport or worker error. Submitted tasks remain recoverable.
class CalibrationError extends CalibrationResult {
  final String code;
  final String message;

  const CalibrationError(this.code, this.message);
}
