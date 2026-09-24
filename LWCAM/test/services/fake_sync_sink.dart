import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/services/sync_models.dart';
import 'package:lwcam/services/sync_sink.dart';

/// Test double for [SyncSink]. Records every batch it's asked to apply and
/// can be configured to throw a queued error on the next N calls, so
/// SyncService's retry/backoff/offline handling can be exercised without a
/// real database.
class FakeSyncSink implements SyncSink {
  final List<List<OutboxRecord>> appliedBatches = [];
  final List<Object> queuedErrors;
  int applyCallCount = 0;

  /// The store [pullStore] returns — set by the test before `syncNow()`.
  UsersStore storeToPull = const UsersStore();

  /// Box names [fetchBoxNames] returns, keyed by projectKey.
  final Map<String, Set<String>> boxNamesByProject = {};

  /// Coarse call log: 'pull', 'apply', 'fetchBoxNames'.
  final List<String> events = [];

  /// Thrown by EVERY [apply] call when set, [queuedErrors] aside.
  ///
  /// Needed because SyncService retries a failed batch one row at a time to
  /// isolate a poison row (handover §7.9): a single queued error is consumed by
  /// the batch attempt, and the row then succeeds alone and is acked. A test
  /// about attempts/backoff has to model a row that is genuinely bad, i.e. one
  /// that fails on the retry too.
  Object? alwaysThrow;

  FakeSyncSink({List<Object> queuedErrors = const [], this.alwaysThrow})
    : queuedErrors = List.of(queuedErrors);

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    applyCallCount++;
    events.add('apply');
    if (queuedErrors.isNotEmpty) {
      throw queuedErrors.removeAt(0);
    }
    if (alwaysThrow != null) throw alwaysThrow!;
    appliedBatches.add(batch);
  }

  @override
  Future<UsersStore> pullStore() async {
    events.add('pull');
    if (queuedErrors.isNotEmpty) {
      throw queuedErrors.removeAt(0);
    }
    return storeToPull;
  }

  @override
  Future<CaptureSnapshotCounts> pullCaptureSnapshot(
    String deviceId, {
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  }) async => const CaptureSnapshotCounts(boxes: 0, folders: 0, images: 0);

  @override
  Future<Set<String>> fetchBoxNames(String projectKey) async {
    events.add('fetchBoxNames');
    return boxNamesByProject[projectKey] ?? const {};
  }

  @override
  Future<void> probe() async {}

  @override
  Future<void> close() async {}
}
