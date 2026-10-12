// Interface between LWCAM's sync loop and the database it writes to.
// Implemented by pg_sync_sink.dart; tests use a fake.
import '../models/app_user.dart';
import 'sync_models.dart';

/// The seam between `SyncService`'s loop and wherever the rows actually go:
/// the configured PostgreSQL (`PgSyncSink` — LAN or cloud, same direct
/// connection). Also the test seam — a fake sink lets the
/// drain/retry/ordering/coalescing logic in `SyncService` be verified
/// without a real database (see test/services/sync_service_test.dart).
abstract class SyncSink {
  /// Applies an entire drained batch as one logical unit, in the order the
  /// caller supplies (see `kSyncEntityOrder` — parents before children, so
  /// a folder never lands before the box it references). Implementors
  /// should make this atomic where the backing store supports it (a single
  /// PG transaction), so a partial failure can never leave the sink holding
  /// only half of a coalesced generation.
  ///
  /// Throws [SyncConnectException] when the sink could not be reached at
  /// all (network down, refused, DNS). Any other exception is treated as an
  /// ordinary write failure and triggers the standard per-batch backoff.
  Future<void> apply(List<OutboxRecord> batch);

  /// Rebuilds a [UsersStore] from PostgreSQL's users/projects/user_projects/
  /// app_settings — run at the START of every sync tick, before the outbox
  /// drain, so its FK parents (users, projects) always exist by the time
  /// rows resolve against them. Pull-only: LWCAM never writes these tables
  /// (see pg_statements.dart's "PG write whitelist" for the 3 exceptions);
  /// LWCam Admin owns every other write.
  Future<UsersStore> pullStore();

  /// Reads one consistent, paged capture-history snapshot for a device.
  Future<CaptureSnapshotCounts> pullCaptureSnapshot(
    String deviceId, {
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  });

  /// The box names already recorded in PG for [projectKey] (the project's
  /// stable client identity — `projects.project_key`), for the box-name
  /// uniqueness cache. Excludes soft-deleted boxes.
  Future<Set<String>> fetchBoxNames(String projectKey);

  /// A cheap reachability check (expected to time out quickly) used by the
  /// Settings "Test connection" button. Throws on failure; returns
  /// normally on success.
  Future<void> probe();

  /// Upserts this PC's `service_heartbeat` row (part `capture`). Throws
  /// [SchemaTooOldException] on an old schema, [SyncConnectException] when
  /// unreachable. Callers must never let a failure here break capture.
  Future<void> heartbeat({
    required String host,
    required String version,
    required DateTime startedAt,
    required Map<String, Object?> backlog,
    DateTime? lastOk,
    String? lastError,
    DateTime? lastErrorAt,
  });

  /// Releases any held connection. Safe to call multiple times.
  Future<void> close();
}

/// Failed attempts after which a row is HELD instead of retried further.
const int kSyncAttemptCap = 20;

/// The database schema level this program needs (`schema_migrations`).
const int kRequiredSchema = 7;

/// Thrown by a [SyncSink] for a row that has used up [kSyncAttemptCap]
/// attempts. The service keeps the row (marked held), never deletes it.
class SyncHoldException implements Exception {
  final String reason;
  const SyncHoldException(this.reason);
  @override
  String toString() => 'SyncHoldException: $reason';
}

/// Thrown by a [SyncSink] that connected to a database older than
/// [kRequiredSchema]. Nothing was written.
class SchemaTooOldException implements Exception {
  final int level;
  const SchemaTooOldException(this.level);
  String get message =>
      'The database is older than this program (needs level $kRequiredSchema, '
      'has $level). Run LWCamDatabaseSetup on the database PC.';
  @override
  String toString() => message;
}

/// Thrown by a [SyncSink] when the sink could not be reached at all.
class SyncConnectException implements Exception {
  final String message;
  const SyncConnectException(this.message);
  @override
  String toString() => 'SyncConnectException: $message';
}
