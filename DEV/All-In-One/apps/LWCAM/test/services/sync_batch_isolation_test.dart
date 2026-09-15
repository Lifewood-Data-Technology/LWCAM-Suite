import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/services/sync_models.dart';
import 'package:lwcam/services/sync_service.dart';
import 'package:lwcam/services/sync_sink.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Applies batches like PgSyncSink does — all-or-nothing — but throws for any
/// batch containing [poisonKey]. That is the shape that matters: the real sink
/// wraps the whole batch in one transaction, so ONE bad row rolls back the
/// healthy ones with it.
class _PoisonSink implements SyncSink {
  _PoisonSink(this.poisonKey);
  final String poisonKey;

  final List<List<OutboxRecord>> appliedBatches = [];
  int applyCallCount = 0;

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    applyCallCount++;
    if (batch.any((r) => r.entityKey == poisonKey)) {
      throw StateError('project "x" not in PG yet (pull pending?)');
    }
    appliedBatches.add(batch);
  }

  @override
  Future<UsersStore> pullStore() async => const UsersStore();
  @override
  Future<CaptureSnapshotCounts> pullCaptureSnapshot(
    String deviceId, {
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  }) async => const CaptureSnapshotCounts(boxes: 0, folders: 0, images: 0);
  @override
  Future<Set<String>> fetchBoxNames(String projectKey) async => const {};
  @override
  Future<void> probe() async {}
  @override
  Future<void> close() async {}
}

/// Fails the first (whole-batch) call, then succeeds for every single-row
/// retry — the "batch failed on cross-row state, not bad data" case.
class _FlakyOnceSink implements SyncSink {
  int applyCallCount = 0;

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    applyCallCount++;
    if (applyCallCount == 1) throw StateError('transient batch failure');
  }

  @override
  Future<UsersStore> pullStore() async => const UsersStore();
  @override
  Future<CaptureSnapshotCounts> pullCaptureSnapshot(
    String deviceId, {
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  }) async => const CaptureSnapshotCounts(boxes: 0, folders: 0, images: 0);
  @override
  Future<Set<String>> fetchBoxNames(String projectKey) async => const {};
  @override
  Future<void> probe() async {}
  @override
  Future<void> close() async {}
}

/// Unreachable for every call after the first batch attempt.
class _OfflineSink implements SyncSink {
  int applyCallCount = 0;

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    applyCallCount++;
    throw const SyncConnectException('connection refused');
  }

  @override
  Future<UsersStore> pullStore() async => const UsersStore();
  @override
  Future<CaptureSnapshotCounts> pullCaptureSnapshot(
    String deviceId, {
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  }) async => const CaptureSnapshotCounts(boxes: 0, folders: 0, images: 0);
  @override
  Future<Set<String>> fetchBoxNames(String projectKey) async => const {};
  @override
  Future<void> probe() async {}
  @override
  Future<void> close() async {}
}

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const deviceId = 'devIsolate';

  Future<UploadStatsDB> freshDb(String prefix) async {
    final base = await _tempDir(prefix);
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    db.syncEnabled = true;
    addTearDown(() {
      db.syncEnabled = false;
      return db.debugCloseAllForTests();
    });
    return db;
  }

  /// Three boxes ⇒ three capture_boxes outbox rows, one per entity key.
  Future<List<String>> seedThreeBoxes(UploadStatsDB db) async {
    for (final name in ['BOX-1', 'BOX-2', 'BOX-3']) {
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: name);
    }
    final raw = await db.getDatabase(deviceId);
    final rows = await raw.query('sync_outbox', orderBy: 'id ASC');
    return [for (final r in rows) r['entity_key'] as String];
  }

  // Handover §7.9. The batch is applied in ONE transaction, so a single bad row
  // rolls back the healthy ones and _backoff used to bump attempts on all of
  // them — up to batchSize rows stuck behind one poison row, on a backoff capped
  // at 15 minutes, indefinitely.
  group('batch poisoning', () {
    test('healthy rows are acked and only the poison row is retried', () async {
      final db = await freshDb('isolate_poison_');
      final keys = await seedThreeBoxes(db);
      expect(keys, hasLength(3));
      final poisonKey = keys[1];

      final sink = _PoisonSink(poisonKey);
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();

      final raw = await db.getDatabase(deviceId);
      final left = await raw.query('sync_outbox');
      expect(left, hasLength(1), reason: 'only the poison row may survive');
      expect(left.single['entity_key'], poisonKey);
      expect(left.single['attempts'], 1);
      expect(left.single['next_attempt_at'], isNotNull);
      expect(left.single['last_error'], contains('not in PG yet'));

      // 1 whole-batch attempt + 3 individual retries.
      expect(sink.applyCallCount, 4);
      expect(service.state.value, SyncState.error);
    });

    test(
      'a poison row does not consume the healthy rows\' retry budget',
      () async {
        final db = await freshDb('isolate_budget_');
        final keys = await seedThreeBoxes(db);
        final sink = _PoisonSink(keys[0]);
        final service = SyncService(db: db, sink: sink, deviceId: deviceId);

        await service.syncNow();

        final raw = await db.getDatabase(deviceId);
        final rows = await raw.query('sync_outbox');
        // The two healthy rows are gone, so their attempts can never climb toward
        // the 20-attempt skip-ack ceiling on a sibling's behalf.
        expect(rows.map((r) => r['entity_key']), [keys[0]]);
      },
    );

    test('when every row succeeds alone, nothing is left pending', () async {
      final db = await freshDb('isolate_flaky_');
      await seedThreeBoxes(db);
      final sink = _FlakyOnceSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();

      final raw = await db.getDatabase(deviceId);
      expect(await raw.query('sync_outbox'), isEmpty);
      expect(service.pendingCount.value, 0);
      expect(service.lastError.value, isNull);
    });

    // An unreachable destination is pending, not poison: the rows must keep
    // their attempts low and not be mistaken for bad data.
    test('an offline sink leaves every row queued', () async {
      final db = await freshDb('isolate_offline_');
      final keys = await seedThreeBoxes(db);
      final sink = _OfflineSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();

      final raw = await db.getDatabase(deviceId);
      final rows = await raw.query('sync_outbox');
      expect(rows.map((r) => r['entity_key']).toSet(), keys.toSet());
      expect(rows.every((r) => r['attempts'] == 0), isTrue);
      expect(service.state.value, SyncState.offline);
    });
  });
}
