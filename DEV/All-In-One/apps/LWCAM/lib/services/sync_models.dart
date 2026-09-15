/// Shared types for the sync outbox drain pipeline (SyncService + SyncSink
/// implementations). Pure Dart — no sqflite/postgres imports here, so this
/// file can be imported by every sink and by tests without pulling in a
/// database driver.
library;

/// `SyncService`'s current activity, surfaced to Settings as a status chip.
enum SyncState {
  /// syncEnabled is false (NodeConfig) — the default; no timer runs.
  disabled,

  /// Timer running, outbox empty, nothing to do.
  idle,

  /// A drain tick is in flight.
  syncing,

  /// The last connection attempt failed to reach the sink at all (as
  /// opposed to a write failing after connecting).
  offline,

  /// A non-connectivity failure (e.g. a write rejected by the schema) that
  /// may need attention; the batch retries on its backoff schedule.
  error,
}

/// One durable outbox row, decoded from `sync_outbox` for draining. Mirrors
/// the table's columns (see upload_stats_db.dart _ensureSyncSchema) plus the
/// already-JSON-decoded payload.
class OutboxRecord {
  final int id;
  final String entity;
  final String entityKey;
  final String op; // 'upsert' | 'delete'
  final Map<String, dynamic>? payload;
  final int attempts;

  const OutboxRecord({
    required this.id,
    required this.entity,
    required this.entityKey,
    required this.op,
    required this.payload,
    required this.attempts,
  });
}

/// PostgreSQL's durable capture history used when a station loses its local
/// SQLite file.  These are deliberately plain values so recovery can run
/// without importing either sqflite or Flutter.
class CaptureSnapshotCounts {
  final int boxes;
  final int folders;
  final int images;

  const CaptureSnapshotCounts({
    required this.boxes,
    required this.folders,
    required this.images,
  });

  int get total => boxes + folders + images;
  bool get isEmpty => total == 0;
}

typedef CaptureBoxPageWriter =
    Future<void> Function(List<CaptureSnapshotBox> rows);
typedef CaptureFolderPageWriter =
    Future<void> Function(List<CaptureSnapshotFolder> rows);
typedef CaptureImagePageWriter =
    Future<void> Function(List<CaptureSnapshotImage> rows);

/// A bound snapshot pull (the device id is already owned by SyncService).
/// PostgreSQL supplies one page at a time; recovery writes it immediately to
/// its temporary SQLite file instead of retaining the station's full history.
typedef CaptureSnapshotPull =
    Future<CaptureSnapshotCounts> Function({
      required CaptureBoxPageWriter onBoxes,
      required CaptureFolderPageWriter onFolders,
      required CaptureImagePageWriter onImages,
    });

class CaptureSnapshotBox {
  final int id;
  final String boxName;
  final String status;
  final String? userId;
  final String? projectId;
  final String? projectKey;
  final String? templateJson;
  final String? createdAt;
  final String? transferEndAt;
  final String? transferredTo;

  const CaptureSnapshotBox({
    required this.id,
    required this.boxName,
    required this.status,
    this.userId,
    this.projectId,
    this.projectKey,
    this.templateJson,
    this.createdAt,
    this.transferEndAt,
    this.transferredTo,
  });
}

class CaptureSnapshotFolder {
  final int id;
  final int boxId;
  final int folderSeq;
  final String? folderName;
  final Map<String, Object?> metadata;
  final String? sourceCreatedAt;
  final String? sourceUpdatedAt;
  final bool isDeskewed;
  final bool isCropped;
  final bool isCreatedThumbnail;
  final String? folderPath;
  final String? thumbnailPath;
  final String? qcStatus;

  const CaptureSnapshotFolder({
    required this.id,
    required this.boxId,
    required this.folderSeq,
    this.folderName,
    this.metadata = const {},
    this.sourceCreatedAt,
    this.sourceUpdatedAt,
    this.isDeskewed = false,
    this.isCropped = false,
    this.isCreatedThumbnail = false,
    this.folderPath,
    this.thumbnailPath,
    this.qcStatus,
  });
}

class CaptureSnapshotImage {
  final int id;
  final int folderId;
  final String imageName;
  final String deviceId;
  final String fileFormat;
  final String? imageCreatedAt;
  final String? imageUpdatedAt;

  const CaptureSnapshotImage({
    required this.id,
    required this.folderId,
    required this.imageName,
    required this.deviceId,
    required this.fileFormat,
    this.imageCreatedAt,
    this.imageUpdatedAt,
  });
}

/// Drain order: parents before children, so a folder never arrives at the
/// sink before the box it references and an image never before its folder
/// (the sink resolves real PG FKs from the payloads' natural keys).
/// upload_records / daily_summary / replacement_records are deliberately
/// absent — local-operational data, never synced.
const List<String> kSyncEntityOrder = [
  'capture_boxes',
  'capture_folders',
  'capture_images',
  // The image-processing phase's per-folder result (deskew/crop/thumbnail
  // flags + paths + qc_status). Sorts AFTER capture_folders so a same-tick
  // folder upsert always applies before the processing UPDATE that targets
  // it. It is an UPDATE of an existing folder row, never a parent of anything.
  'capture_folder_processing',
  // A rework submit's folder side: the metadata columns the operator corrected,
  // plus a qc_status reset when the fix was metadata-only. Also an UPDATE of an
  // existing folder row, so it sorts with the other folder UPDATEs and before
  // the closures below.
  'capture_folder_rework',
  // The CLOSED row that retires a QC recapture request, appended after the
  // recaptured image has transferred. Last: it references an image row, so any
  // same-tick capture_images upsert must land first.
  'rework_logs',
];

int compareEntityOrder(String a, String b) {
  final ia = kSyncEntityOrder.indexOf(a);
  final ib = kSyncEntityOrder.indexOf(b);
  // Unknown entities (shouldn't happen) sort after every known one rather
  // than crashing on indexOf's -1.
  return (ia == -1 ? kSyncEntityOrder.length : ia).compareTo(
    ib == -1 ? kSyncEntityOrder.length : ib,
  );
}
