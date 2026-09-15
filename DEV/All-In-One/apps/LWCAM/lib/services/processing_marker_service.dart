// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../db/upload_stats_db.dart';
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
      final payload = buildFolderMarkerPayload(
        boxKeys: boxKeys,
        folderSeq: folder.folderSeq,
        folderName: name,
      );
      var found = false;
      for (final dayPath in dayDirs) {
        final folderDir = Directory(p.join(dayPath, name));
        if (!await folderDir.exists()) continue; // this folder didn't land here
        found = true;
        try {
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
  final target = File(p.join(folderPath, kProcessingMarkerName));
  final existing = await _readMarkerIdentity(target);
  if (existing != null && !_sameFolderIdentity(existing, payload)) {
    throw StateError(
      'marker already belongs to project ${existing['project_key']} / '
      'box "${existing['box_name']}" / folder ${existing['folder_seq']} — '
      'another group or PC landed in $folderPath',
    );
  }
  final tmp = File('${target.path}.tmp');
  await tmp.writeAsString(jsonEncode(payload), flush: true);
  if (await target.exists()) await target.delete();
  await tmp.rename(target.path);
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
