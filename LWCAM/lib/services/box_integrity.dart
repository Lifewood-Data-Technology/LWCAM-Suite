// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/upload_stats_db.dart';
import 'audit_log_service.dart';
import 'image_name_mapping.dart';
import 'orphan_image_store.dart';
import 'safe_copy.dart';

export 'image_name_mapping.dart' show baseNameForDeviceFilename;

/// Capture-integrity helpers, kept as FREE FUNCTIONS (no GetX) so they're
/// unit-testable against a temp dir + an sqfliteFfi DB without constructing a
/// BoxSessionController (which needs AuthController). BoxSessionController
/// wraps these; the admin orphan screen calls them directly.

/// Single source of truth for the durable per-box image store path:
/// `<AppSupport>/box_images/<deviceId>/box_<boxId>`. Both
/// BoxSessionController._boxImagesDir and the orphan-resolution screen
/// delegate here so the two never disagree.
Future<Directory> boxImagesDir(String deviceId, int boxId) async {
  final support = await getApplicationSupportDirectory();
  final dir = Directory(
    p.join(support.path, 'box_images', deviceId, 'box_$boxId'),
  );
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}

/// The transfer engine's generated base name for a device filename
/// (`<deviceId>_IMG_YYYYMMDD_HHMMSS`), or '' when the name carries no
/// parseable timestamp. Moved verbatim from
/// BoxSessionController._baseNameForDeviceFilename so the skip/verify logic
/// and the controller agree.
/// Maps a cloud transfer name back to the original device filename LWCAM keeps
/// locally. Transferred-box thumbnails use that local name, while QC rework
/// items use the cloud name (`SAX04_IMG_..._001.jpg`).
String localImageNameForCloudImage(
  String deviceId,
  String cloudName,
  Iterable<String> localNames,
) {
  if (localNames.contains(cloudName)) return cloudName;
  final sourceName = sourceImageNameFromCloudImage(deviceId, cloudName);
  if (sourceName != null && localNames.contains(sourceName)) return sourceName;
  final cloudBase = baseNameForDeviceFilename(deviceId, cloudName);
  if (cloudBase.isEmpty) return cloudName;
  return localNames.firstWhere(
    (name) => baseNameForDeviceFilename(deviceId, name) == cloudBase,
    orElse: () => cloudName,
  );
}

/// Silently re-files every intent-known orphan for [deviceId] into the DB.
/// Each entry is handled in its own try/catch, so one bad entry never blocks
/// the rest and a transient failure simply leaves it for the next pass.
/// Returns the number of entries actually healed (assignment written).
///
/// Per entry:
///  - box gone or already transferred  -> demote to admin (would strand the row)
///  - folder gone                       -> demote ('folder-missing')
///  - assign succeeds                   -> file into the durable store, heal
///  - assign returns false (UNIQUE):
///      already assigned to the intended box -> healed-duplicate: ensure a
///        durable copy exists, drop the stash
///      assigned to a different box           -> demote ('assigned-elsewhere')
Future<int> healOrphanImages({
  required UploadStatsDB db,
  required OrphanImageStore store,
  required String deviceId,
  AuditLogService? audit,
  // Injectable so tests (which have no path_provider) can point the durable
  // store at a temp dir; production uses the real AppSupport location.
  Future<Directory> Function(String deviceId, int boxId)? boxImagesDirResolver,
}) async {
  final resolveBoxDir = boxImagesDirResolver ?? boxImagesDir;
  var healed = 0;
  for (final e in await store.list(deviceId)) {
    if (!e.intentKnown) continue;
    try {
      final box = await db.getCaptureBoxById(
        deviceId: deviceId,
        boxId: e.boxId!,
      );
      if (box == null || box.isTransferred) {
        await store.demoteToUnknown(
          e,
          note: box == null ? 'box-missing' : 'box-transferred',
        );
        continue;
      }
      final folders = await db.getCaptureFolders(
        deviceId: deviceId,
        boxId: e.boxId!,
      );
      if (!folders.any((f) => f.id == e.folderId)) {
        await store.demoteToUnknown(e, note: 'folder-missing');
        continue;
      }

      final ok = await retrying(
        () => db.assignImageToFolder(
          deviceId: deviceId,
          boxId: e.boxId!,
          folderId: e.folderId!,
          deviceFilename: e.deviceFilename,
        ),
      );

      if (ok) {
        await store.resolveInto(e, await resolveBoxDir(deviceId, e.boxId!));
        healed++;
        await audit?.log(
          AuditActions.orphanHealed,
          details: {
            'file': e.deviceFilename,
            'box': e.boxId!,
            'folder': e.folderId!,
          },
        );
      } else {
        // UNIQUE conflict: the name is already assigned somewhere.
        final assignments = await db.getAssignmentsForBox(
          deviceId: deviceId,
          boxId: e.boxId!,
        );
        if (assignments.containsKey(e.deviceFilename)) {
          // Already in the intended box — a duplicate stash. Make sure the
          // durable copy exists, then drop the orphan.
          final dir = await resolveBoxDir(deviceId, e.boxId!);
          final landed = File(p.join(dir.path, e.deviceFilename));
          if (!landed.existsSync()) {
            try {
              await safeCopy(e.file, landed.path);
            } catch (_) {}
          }
          await store.discard(e);
        } else {
          await store.demoteToUnknown(e, note: 'assigned-elsewhere');
        }
      }
    } catch (err) {
      print(
        '⚠️ healOrphanImages: entry ${e.deviceFilename} left stashed: $err',
      );
    }
  }
  return healed;
}

/// Completeness gate run before a box is marked transferred. Returns null when
/// the box is genuinely complete, else a human message for the box tile.
///
/// A box is complete iff:
///  (a) every assigned filename with a parseable base is recorded in
///      upload_records (getUploadedBaseNames) — the robust per-file "landed"
///      check, immune to the skip-on-retry batch arithmetic; and
///  (b) no intent-known orphan still targets this box.
///
/// Unparseable-base names are not per-file checkable here, but they can only
/// reach a box via staging (covered by the batch's own isFullSuccess) and are
/// never in the orphan set with a real base — so excluding them is safe.
Future<String?> verifyBoxComplete({
  required UploadStatsDB db,
  required OrphanImageStore store,
  required String deviceId,
  required int boxId,
}) async {
  final assignments = await db.getAssignmentsForBox(
    deviceId: deviceId,
    boxId: boxId,
  );
  final recordedBases = await db.getUploadedBaseNames(deviceId);

  var notVerified = 0;
  for (final name in assignments.keys) {
    final base = baseNameForDeviceFilename(deviceId, name);
    if (base.isEmpty) continue;
    if (!recordedBases.contains(base)) notVerified++;
  }

  final unresolved = (await store.list(
    deviceId,
  )).where((e) => e.boxId == boxId).length;

  if (notVerified == 0 && unresolved == 0) return null;

  final parts = <String>[];
  if (notVerified > 0)
    parts.add('$notVerified image(s) not verified at destination');
  if (unresolved > 0)
    parts.add('$unresolved unresolved image(s) need admin review');
  return '${parts.join('; ')}.';
}
