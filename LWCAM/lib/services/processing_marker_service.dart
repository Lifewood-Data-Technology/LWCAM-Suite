// ignore_for_file: avoid_print

// Writes the capture marker file into each transferred folder in LWCAM.
// This is the hand-off point to LWIP: the marker tells it the folder is
// complete and carries the folder's identity for later reporting.
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'color_capture_session.dart';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/upload_stats_db.dart';
import 'fs_probe.dart';
import 'safe_copy.dart';
import 'transfer_destination_service.dart';

/// The marker file LWCAM drops into each transferred folder once a box has
/// fully verified. It is BOTH the LWIP watcher's `completion_marker`
/// readiness gate (LWIP won't process a folder until this exists) AND the
/// folder's DB-identity payload (natural keys), so the processing agent that
/// later reports results never has to reverse-engineer identity from paths.
/// `.json` is outside the image extensions. LWIP hashes calibration data
/// separately so parameter changes invalidate a completed folder.
const String kProcessingMarkerName = 'lwcam_capture_marker.json';

class ProcessingMarkerResult {
  final int expectedFolders;
  final int writtenMarkers;
  final int missingFolders;
  final int failedWrites;

  /// Human-readable folder (or box) failures, in the order they happened.
  /// Kept separate from the counts so the transfer error can name the cause
  /// instead of only saying "fix the destination".
  final List<String> folderFailures;

  const ProcessingMarkerResult({
    required this.expectedFolders,
    required this.writtenMarkers,
    required this.missingFolders,
    required this.failedWrites,
    this.folderFailures = const [],
  });

  bool get isSuccess =>
      expectedFolders > 0 &&
      missingFolders == 0 &&
      failedWrites == 0 &&
      writtenMarkers >= expectedFolders;

  String get summary =>
      'expected $expectedFolders, wrote $writtenMarkers, '
      'missing $missingFolders, failed $failedWrites';

  String get details => folderFailures.join(' | ');
}

/// The marker's contents: the parent box's natural keys (same set as the
/// sync outbox's `_parentBoxKeys`) plus the folder's seq + destination name.
Map<String, dynamic> buildFolderMarkerPayload({
  required Map<String, dynamic> boxKeys,
  required int folderSeq,
  required String folderName,
  int? imageCount,
  Map<String, dynamic>? colorCalibration,
  DateTime? now,
}) {
  return {
    'version': 1,
    if (colorCalibration != null) 'color_calibration': colorCalibration,
    'project_key': boxKeys['project_key'],
    'project_id': boxKeys['project_id'],
    'box_name': boxKeys['box_name'],
    'renamed_from': boxKeys['renamed_from'],
    'device_id': boxKeys['device_id'],
    'folder_seq': folderSeq,
    'folder_name': folderName,
    // Images LWCAM copied into the folder: LWIP waits until it sees this many
    // (a share can list a folder before all its files are visible).
    if (imageCount != null) 'image_count': imageCount,
    'created_at': (now ?? DateTime.now()).toIso8601String(),
  };
}

/// Writes the processing marker into every transferred folder of [boxId]
/// under the box's persisted destination day dir (`capture_boxes.
/// transferred_to`, fixed by UploadStatsDB.markCaptureBoxTransferStarted on
/// the first attempt) — never by searching every day dir for the folder NAME,
/// which also found a same-named folder from another box or another PC and
/// stamped this box's identity into it. Every expected folder must be found
/// and every marker write must succeed before the caller can mark the box
/// transferred.
///
/// Boxes copied by a build that did not persist the day dir (transferred_to
/// null or the bare root) fall back to the old scan of [legacyRoot]'s day
/// dirs, so a box left "all copied, not yet marked" across the upgrade can
/// still finish.
Future<ProcessingMarkerResult> writeBoxProcessingMarkers({
  required UploadStatsDB db,
  required String deviceId,
  required int boxId,
  required String legacyRoot,
}) async {
  final folders = await db.getCaptureFolders(deviceId: deviceId, boxId: boxId);
  var written = 0;
  var missing = 0;
  var failures = 0;
  final folderFailures = <String>[];
  try {
    final box = await db.getCaptureBoxById(deviceId: deviceId, boxId: boxId);
    final List<String> dayDirs;
    if (TransferDestinationService.isDayDirectory(box?.transferredTo)) {
      dayDirs = [box!.transferredTo!.trim()];
    } else {
      // ponytail: legacy name scan for boxes copied before the destination
      // was persisted; delete once no pre-2026-09-10 box is still OPEN.
      final root = legacyRoot.trim();
      if (root.isEmpty) {
        return ProcessingMarkerResult(
          expectedFolders: folders.length,
          writtenMarkers: 0,
          missingFolders: folders.length,
          failedWrites: 1,
          folderFailures: const ['destination root is not configured'],
        );
      }
      final rootDir = Directory(root);
      if (!await rootDir.exists()) {
        return ProcessingMarkerResult(
          expectedFolders: folders.length,
          writtenMarkers: 0,
          missingFolders: folders.length,
          failedWrites: 0,
          folderFailures: const ['destination root does not exist'],
        );
      }
      dayDirs = [];
      await for (final entry in rootDir.list(followLinks: false)) {
        if (entry is Directory &&
            TransferDestinationService.isDayDirectory(entry.path)) {
          dayDirs.add(entry.path);
        }
      }
    }
    final boxKeys = await db.boxNaturalKeys(deviceId: deviceId, boxId: boxId);

    for (final folder in folders) {
      final name = folder.folderName?.trim() ?? '';
      if (name.isEmpty) {
        missing++;
        continue;
      }
      var found = false;
      for (final dayPath in dayDirs) {
        final folderDir = Directory(longPath(p.join(dayPath, name)));
        if (!await folderDir.exists()) continue; // this folder didn't land here
        found = true;
        try {
          final calibration = await db.checkFolderColorCalibration(
            deviceId,
            folder.id,
          );
          if (calibration.hasIssues) {
            throw StateError(calibration.issueSummary);
          }
          final payload = buildFolderMarkerPayload(
            boxKeys: boxKeys,
            folderSeq: folder.folderSeq,
            folderName: name,
            imageCount: await countImageFiles(folderDir),
            colorCalibration: calibration.marker,
          );
          await _writeMarkerAtomic(folderDir.path, payload);
          written++;
        } catch (e) {
          failures++;
          folderFailures.add('$name: $e');
          print(
            '⚠️ Could not write processing marker in ${folderDir.path}: $e',
          );
        }
      }
      if (!found) missing++;
    }
  } catch (e) {
    failures++;
    folderFailures.add('box: $e');
    print('⚠️ Processing marker write failed for box $boxId: $e');
  }
  return ProcessingMarkerResult(
    expectedFolders: folders.length,
    writtenMarkers: written,
    missingFolders: missing,
    failedWrites: failures,
    folderFailures: folderFailures,
  );
}

/// Two capture PCs sharing one NAS root, the same day and the same Volume
/// name resolve to the same `<root>\<YYYYMMDD>\<name>` — folder-name
/// uniqueness is only checked in the local DB. Their images already share
/// that directory by the time markers are written; the least this can do is
/// refuse to stamp the other PC's folder with this box's identity, so the
/// second box stays untransferred with a message instead of both halves
/// reporting under one identity. Same-identity rewrites (a retried
/// markTransferred) stay idempotent; an unreadable marker is ours to replace.
Future<void> _writeMarkerAtomic(
  String folderPath,
  Map<String, dynamic> payload,
) async {
  final target = File(longPath(p.join(folderPath, kProcessingMarkerName)));
  final existing = await _readMarkerIdentity(target);
  if (existing != null && existing.isNotEmpty && !_sameFolderIdentity(existing, payload)) {
    throw StateError(
      'marker already belongs to project ${existing['project_key']} / '
      'box "${existing['box_name']}" / folder ${existing['folder_seq']} — '
      'another group or PC landed in $folderPath',
    );
  }
  // Temp file then replace: readers (LWIP, on another PC) never see a
  // missing or half-written marker, and there is no delete-then-rename gap.
  await writeStringAtomic(target.path, jsonEncode(payload));
}

/// LWIP's image extensions (`DEFAULT_EXTENSIONS`); `.part`/`.tmp`/`.json` never
/// count.
const _imageExts = {'.jpg', '.jpeg', '.png', '.tif', '.tiff'};

/// Image files directly inside [dir] (the folder LWIP will fingerprint).
Future<int> countImageFiles(Directory dir) async {
  var n = 0;
  await for (final e in dir.list(followLinks: false)) {
    if (e is File && _imageExts.contains(p.extension(e.path).toLowerCase())) {
      n++;
    }
  }
  return n;
}

Future<Map<String, dynamic>?> _readMarkerIdentity(File marker) async {
  try {
    if (!await marker.exists()) return null;
    final text = (await marker.readAsString()).replaceFirst('\uFEFF', '');
    if (text.trim().isEmpty) return <String, dynamic>{};
    final data = jsonDecode(text);
    return data is Map ? Map<String, dynamic>.from(data) : null;
  } catch (_) {
    return null;
  }
}

bool _sameFolderIdentity(Map<String, dynamic> a, Map<String, dynamic> b) =>
    '${a['project_key']}' == '${b['project_key']}' &&
    '${a['box_name']}' == '${b['box_name']}' &&
    '${a['folder_seq']}' == '${b['folder_seq']}';

/// Names (lower-cased) among [folders] whose destination folder under [dayDir]
/// already holds a completion marker of a DIFFERENT project/box/folder_seq -
/// another box or another capture PC landed there first. Copying into such a
/// folder would merge two boxes' images under one identity, so the caller picks
/// a suffixed name instead (computeFolderNames' ` - 0002` scheme). Each probe is
/// time-bounded; an unreachable share reports nothing (the copy itself will
/// queue and retry).
Future<Set<String>> foreignMarkerFolderNames({
  required String dayDir,
  required Map<String, dynamic> boxKeys,
  required Map<String, int> folderSeqByName,
}) async {
  final foreign = <String>{};
  for (final e in folderSeqByName.entries) {
    final marker = File(longPath(p.join(dayDir, e.key, kProcessingMarkerName)));
    Map<String, dynamic>? existing;
    try {
      existing = await _readMarkerIdentity(marker).timeout(kFsProbeTimeout);
    } catch (_) {
      continue;
    }
    if (existing == null || existing.isEmpty) continue;
    final mine = {
      'project_key': boxKeys['project_key'],
      'box_name': boxKeys['box_name'],
      'folder_seq': e.value,
    };
    if (!_sameFolderIdentity(existing, mine)) foreign.add(e.key.toLowerCase());
  }
  return foreign;
}

/// Upgrade a marker-less/empty legacy folder before holding its gate. Preserve
/// existing calibration data, and never claim another folder's identity.
Future<void> ensureReworkCaptureMarker(String inputFolder, Map<String, dynamic> identity) async {
  final target = File(longPath(p.join(inputFolder, kProcessingMarkerName)));
  final existing = await _readMarkerIdentity(target);
  if (await target.exists() && existing == null) {
    throw StateError('Capture marker is unreadable; restore it before recapture');
  }
  final data = existing ?? <String, dynamic>{};
  for (final key in ['project_key', 'box_name', 'folder_seq']) {
    if (data[key] != null && '${data[key]}' != '${identity[key]}') {
      throw StateError('Capture marker belongs to another folder');
    }
  }
  for (final entry in identity.entries) {
    data.putIfAbsent(entry.key, () => entry.value);
  }
  data['rework_in_progress'] = true;
  await writeStringAtomic(target.path, jsonEncode(data));
}

/// Updates only the recaptured page, while the readiness gate is held.
Future<void> updateReworkColorBinding(String inputFolder, String imageName, ColorBinding binding) async {
  final target = File(longPath(p.join(inputFolder, kProcessingMarkerName)));
  final data = await _readMarkerIdentity(target);
  if (data == null) throw StateError('Recapture requires a readable capture marker');
  final raw = data['color_calibration'];
  if (raw != null && raw is! Map) throw StateError('Damaged calibration marker');
  final block = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{
    'version': 1, 'profiles': <String, dynamic>{}, 'images': <String, dynamic>{},
  };
  if (block['version'] != 1) throw StateError('Unsupported calibration marker version');
  final images = Map<String, dynamic>.from(block['images'] as Map);
  final profiles = Map<String, dynamic>.from(block['profiles'] as Map);
  if (raw == null) {
    // Preserve legacy capture-time decisions for untouched pages.
    final legacy = data['color_profile'];
    final legacyPayload = legacy is Map && legacy['calibrated_today'] == true
        ? jsonEncode(Map<String, dynamic>.from(legacy)) : null;
    final legacyHash = legacyPayload == null ? null : sha256.convert(utf8.encode(legacyPayload)).toString();
    if (legacyHash != null) profiles[legacyHash] = legacyPayload;
    await for (final entry in Directory(longPath(inputFolder)).list()) {
      if (entry is File && _imageExts.contains(p.extension(entry.path).toLowerCase())) {
        images[p.basename(entry.path)] = legacyHash == null
            ? {'profile': null, 'reason': 'historical'} : {'profile': legacyHash};
      }
    }
  }
  if (binding.profile != null) profiles[binding.profile!] = binding.payload;
  images[imageName] = binding.marker();
  block['profiles'] = profiles;
  block['images'] = images;
  data['color_calibration'] = block;
  await writeStringAtomic(target.path, jsonEncode(data));
}

/// True when the folder's capture marker still holds the LWIP readiness gate.
/// A missing marker means no gate was written (legacy folder); an existing but
/// unreadable marker fails closed, because it may hide an interrupted submit.
Future<bool> reworkReadinessHeld(String inputFolder) async {
  final marker = File(longPath(p.join(inputFolder, kProcessingMarkerName)));
  if (!await marker.exists()) return false;
  final data = await _readMarkerIdentity(marker);
  if (data == null) {
    throw StateError(
      'Capture marker is unreadable; restore it before submitting rework.',
    );
  }
  return data['rework_in_progress'] == true;
}

/// Holds the LWIP readiness gate while a recapture is being committed.
/// New recapture callers require a readable marker; legacy callers may opt out.
Future<void> setReworkInProgress(String inputFolder, bool inProgress, {bool requireReadable = false}) async {
  final target = File(longPath(p.join(inputFolder, kProcessingMarkerName)));
  final data = await _readMarkerIdentity(target);
  if (data == null) {
    if (requireReadable) throw StateError('Recapture requires a readable capture marker');
    return;
  }
  if (inProgress) {
    data['rework_in_progress'] = true;
  } else {
    data.remove('rework_in_progress');
    data['image_count'] = await countImageFiles(Directory(longPath(inputFolder)));
  }
  await writeStringAtomic(target.path, jsonEncode(data));
}
