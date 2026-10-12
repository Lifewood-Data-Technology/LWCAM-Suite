// ignore_for_file: avoid_print

// Writes the capture marker file into each transferred folder in LWCAM.
// This is the hand-off point to LWIP: the marker tells it the folder is
// complete and carries the folder's identity for later reporting.
import 'dart:convert';
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
/// `.json` is deliberately outside LWIP's image extensions, so the marker
/// never perturbs the folder's content fingerprint.
const String kProcessingMarkerName = 'lwcam_capture_marker.json';

class ProcessingMarkerResult {
  final int expectedFolders;
  final int writtenMarkers;
  final int missingFolders;
  final int failedWrites;

  const ProcessingMarkerResult({
    required this.expectedFolders,
    required this.writtenMarkers,
    required this.missingFolders,
    required this.failedWrites,
  });

  bool get isSuccess =>
      expectedFolders > 0 &&
      missingFolders == 0 &&
      failedWrites == 0 &&
      writtenMarkers >= expectedFolders;

  String get summary =>
      'expected $expectedFolders, wrote $writtenMarkers, '
      'missing $missingFolders, failed $failedWrites';
}

/// The marker's contents: the parent box's natural keys (same set as the
/// sync outbox's `_parentBoxKeys`) plus the folder's seq + destination name.
Map<String, dynamic> buildFolderMarkerPayload({
  required Map<String, dynamic> boxKeys,
  required int folderSeq,
  required String folderName,
  int? imageCount,
  DateTime? now,
}) {
  return {
    'version': 1,
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
        );
      }
      final rootDir = Directory(root);
      if (!await rootDir.exists()) {
        return ProcessingMarkerResult(
          expectedFolders: folders.length,
          writtenMarkers: 0,
          missingFolders: folders.length,
          failedWrites: 0,
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
          final payload = buildFolderMarkerPayload(
            boxKeys: boxKeys,
            folderSeq: folder.folderSeq,
            folderName: name,
            imageCount: await countImageFiles(folderDir),
          );
          await _writeMarkerAtomic(folderDir.path, payload);
          written++;
        } catch (e) {
          failures++;
          print(
            '⚠️ Could not write processing marker in ${folderDir.path}: $e',
          );
        }
      }
      if (!found) missing++;
    }
  } catch (e) {
    failures++;
    print('⚠️ Processing marker write failed for box $boxId: $e');
  }
  return ProcessingMarkerResult(
    expectedFolders: folders.length,
    writtenMarkers: written,
    missingFolders: missing,
    failedWrites: failures,
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
  if (existing != null && !_sameFolderIdentity(existing, payload)) {
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
    final data = jsonDecode(await marker.readAsString());
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
    if (existing == null) continue;
    final mine = {
      'project_key': boxKeys['project_key'],
      'box_name': boxKeys['box_name'],
      'folder_seq': e.value,
    };
    if (!_sameFolderIdentity(existing, mine)) foreign.add(e.key.toLowerCase());
  }
  return foreign;
}

/// Flags a completed input folder as being reworked (or clears the flag).
/// LWIP treats a marker with `rework_in_progress: true` as NOT ready, so it
/// never fingerprints a half-replaced folder. Clearing also refreshes
/// `image_count` from what is on disk now. A folder with no marker (an old
/// capture) has nothing to gate and is left alone.
Future<void> setReworkInProgress(String inputFolder, bool inProgress) async {
  final target = File(longPath(p.join(inputFolder, kProcessingMarkerName)));
  final data = await _readMarkerIdentity(target);
  if (data == null) return;
  if (inProgress) {
    data['rework_in_progress'] = true;
  } else {
    data.remove('rework_in_progress');
    data['image_count'] = await countImageFiles(Directory(longPath(inputFolder)));
  }
  await writeStringAtomic(target.path, jsonEncode(data));
}
