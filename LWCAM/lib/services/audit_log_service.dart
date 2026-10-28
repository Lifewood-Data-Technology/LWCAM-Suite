// Local audit trail for the capture app (LWCAM): logins, box and folder changes,
// transfers, image deletions and replacements, written as monthly log files.
// Not synced to PostgreSQL; the logs stay on the capture PC.
// Know before editing: add new action names to AuditActions rather than passing
// ad-hoc strings, and keep this file free of GetX so it stays unit-testable.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Central, kebab-case action names for [AuditLogService.log] — keeps the
/// audit trail grep-able and typo-proof across call sites.
abstract final class AuditActions {
  static const loginSuccess = 'LOGIN_SUCCESS';
  static const loginFailed = 'LOGIN_FAILED';
  static const logout = 'LOGOUT';
  static const passwordChanged = 'PASSWORD_CHANGED';
  static const boxCreate = 'BOX_CREATE';
  static const boxRename = 'BOX_RENAME';
  static const boxDelete = 'BOX_DELETE';
  static const boxTransferred = 'BOX_TRANSFERRED';
  static const folderCreate = 'FOLDER_CREATE';
  static const folderUpdate = 'FOLDER_UPDATE';
  static const folderDelete = 'FOLDER_DELETE';
  static const imageUnassigned = 'IMAGE_UNASSIGNED';
  static const imageDeleted = 'IMAGE_DELETED';
  static const orphanStashed = 'ORPHAN_STASHED';
  static const orphanHealed = 'ORPHAN_HEALED';
  static const orphanAssigned = 'ORPHAN_ASSIGNED';
  static const orphanDiscarded = 'ORPHAN_DISCARDED';
  static const transferStart = 'TRANSFER_START';
  static const transferComplete = 'TRANSFER_COMPLETE';
  static const transferFailed = 'TRANSFER_FAILED';
  static const transferFileFailed = 'TRANSFER_FILE_FAILED';
  static const transferRetry = 'TRANSFER_RETRY';
  static const colorCalibrationAccepted = 'COLOR_CALIBRATION_ACCEPTED';
  static const settingsChanged = 'SETTINGS_CHANGED';
  static const syncConfigSaved = 'SYNC_CONFIG_SAVED';
  static const userManaged = 'USER_MANAGED';
}

/// Local, append-only audit trail + a dedicated replacement log — see
/// AGENTS.md/CHANGELOG.txt: management asked for replacement history to live
/// in human-readable local logs, not the cloud DB (see also
/// upload_stats_db.dart's replacement_records — local-operational only, never
/// synced).
///
/// Deliberately dependency-light: no GetX, no other app services referenced
/// internally — [resolveBaseDir]/[now] are injected so this is trivially
/// unit-testable without touching the real filesystem/clock. Production
/// wiring (which device/operator to stamp on each line) happens via
/// [setContext], called at login/logout — not threaded through every
/// call site.
///
/// Files are monthly-rolled (they grow forever, same reasoning as the device
/// DB's monthly rotation): `<deviceId>_audit_<YYYY-MM>.log` and
/// `<deviceId>_replacements_<YYYY-MM>.log`, both under
/// `getApplicationSupportDirectory()/LWCAM/` (the existing fallback-log
/// location — see transfer_controller.dart's `_getFallbackLogFile`).
class AuditLogService {
  final Future<Directory> Function() _resolveBaseDir;
  final DateTime Function() _now;

  String _deviceId = 'UNKNOWN';
  String _operator = '';
  Future<void> _writeQueue = Future.value();

  AuditLogService({
    required Future<Directory> Function() resolveBaseDir,
    DateTime Function()? now,
  })  : _resolveBaseDir = resolveBaseDir,
        _now = now ?? DateTime.now;

  factory AuditLogService.production() {
    return AuditLogService(
      resolveBaseDir: () async {
        final baseDir = await getApplicationSupportDirectory();
        final appDir = Directory(p.join(baseDir.path, 'LWCAM'));
        if (!appDir.existsSync()) appDir.createSync(recursive: true);
        return appDir;
      },
    );
  }

  /// Sets the identity stamped on every subsequent line — call at login,
  /// and again (with nulls) at logout. Not required before first use:
  /// pre-login events (e.g. a failed login itself) fall back to device id
  /// `UNKNOWN`.
  void setContext({String? deviceId, String? operator}) {
    final trimmedDevice = deviceId?.trim() ?? '';
    _deviceId = trimmedDevice.isEmpty ? 'UNKNOWN' : trimmedDevice;
    _operator = operator?.trim() ?? '';
  }

  /// All file writes go through one chained queue (the established
  /// `_runSerializedArtifactWrite` idiom from transfer_controller.dart) so
  /// concurrent async call sites can never interleave/shear lines. A failed
  /// write doesn't wedge later ones.
  Future<void> _serialize(Future<void> Function() action) {
    _writeQueue = _writeQueue.catchError((_) {}).then((_) => action());
    return _writeQueue;
  }

  String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// No pipes/newlines in a value (they'd corrupt the one-event-per-line
  /// format); spaced values are quoted so the line stays easy to eyeball.
  String _sanitize(Object? value) {
    final s =
        value.toString().replaceAll('|', '/').replaceAll('\n', ' ').replaceAll('\r', ' ');
    return s.contains(' ') ? '"$s"' : s;
  }

  String _formatLine(DateTime at, String deviceId, String operator, String action,
      Map<String, Object?> details) {
    final detailsStr =
        details.entries.map((e) => '${e.key}=${_sanitize(e.value)}').join(' ');
    final buffer = StringBuffer('${at.toIso8601String()} | $deviceId | $operator | $action');
    if (detailsStr.isNotEmpty) buffer.write(' $detailsStr');
    return buffer.toString();
  }

  Future<void> _appendLine(String fileStem, DateTime at, String line) async {
    try {
      final dir = await _resolveBaseDir();
      final file = File(p.join(dir.path, '${fileStem}_${_monthKey(at)}.log'));
      if (!file.existsSync()) await file.create(recursive: true);
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Logging must never break capture/transfer — swallow and move on.
    }
  }

  /// Records one audit-trail event (see [AuditActions] for the vocabulary).
  /// Never throws. Identity/timestamp are captured immediately (not when the
  /// write queue eventually runs), so the log reflects real event order even
  /// under load.
  Future<void> log(String action, {Map<String, Object?> details = const {}}) {
    final at = _now();
    final deviceId = _deviceId;
    final line = _formatLine(at, deviceId, _operator, action, details);
    return _serialize(() => _appendLine('${deviceId}_audit', at, line));
  }

  /// Records a replacement event in BOTH the dedicated replacement log (full
  /// detail, for the on-site record) and a summary line in the audit trail
  /// (so the trail alone still shows every action that happened).
  Future<void> logReplacement({
    required String event, // created | superseded | discarded
    required String originalFilename,
    required String replacementFilename,
    required String replacementType,
    String boxDetails = '',
    Map<String, Object?> extra = const {},
  }) {
    final details = {
      'event': event,
      'original': originalFilename,
      'replacement': replacementFilename,
      'type': replacementType,
      if (boxDetails.isNotEmpty) 'box': boxDetails,
      ...extra,
    };
    final at = _now();
    final deviceId = _deviceId;
    final line = _formatLine(at, deviceId, _operator, 'REPLACEMENT', details);
    return _serialize(() async {
      await _appendLine('${deviceId}_replacements', at, line);
      await _appendLine('${deviceId}_audit', at, line);
    });
  }
}
