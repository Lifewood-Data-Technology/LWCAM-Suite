import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/cloud_box_names.dart';
import 'package:lwcam/services/sync_models.dart';
import 'package:lwcam/services/sync_service.dart';
import 'package:lwcam/services/sync_sink.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_sync_sink.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

CaptureFolder _folder(int boxId) {
  return CaptureFolder(
    boxId: boxId,
    coverTag: 'Cover Will Be Captured',
    title: 'WWI Medical Files',
    volume: 'V file no. 1',
    startDate: '1914',
    endDate: '1918',
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const deviceId = 'devSync';

  Future<UploadStatsDB> freshDb(String prefix) async {
    final base = await _tempDir(prefix);
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() {
      return db.debugCloseAllForTests();
    });
    return db;
  }

  group('kSyncEntityOrder', () {
    test('capture_folder_processing sorts AFTER capture_folders so a same-tick '
        'folder upsert applies before the processing update that targets it', () {
      expect(compareEntityOrder('capture_folder_processing', 'capture_folders'),
          greaterThan(0));
      expect(compareEntityOrder('capture_folders', 'capture_folder_processing'),
          lessThan(0));
      // And after images too (it's a leaf update, never a parent).
      expect(compareEntityOrder('capture_folder_processing', 'capture_images'),
          greaterThan(0));
    });
  });

  group('SyncService', () {
    test('a tick first queues what PG never got, then drains it', () async {
      final db = await freshDb('sync_svc_catchup_');
      await db.insertCaptureBox(
        deviceId: deviceId,
        boxDetails: 'BOX-OLD',
        projectKey: 'pk1',
      );
      // Captured before the hooks always recorded: nothing in the outbox.
      await (await db.getDatabase(deviceId)).delete('sync_outbox');

      final sink = FakeSyncSink();
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: deviceId,
        cloudCaptureKeys: (_) async => <String>{},
      );
      await service.syncNow();

      expect(sink.appliedBatches.single.single.entity, 'capture_boxes');
      expect(service.pendingCount.value, 0);
    });

    test('idle when the outbox is empty; the sink is never touched', () async {
      final db = await freshDb('sync_svc_empty_');
      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();

      expect(service.state.value, SyncState.idle);
      expect(service.pendingCount.value, 0);
      expect(sink.applyCallCount, 0);
    });

    test('drains outbox rows, acks them, and updates pendingCount',
        () async {
      final db = await freshDb('sync_svc_drain_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();

      expect(sink.applyCallCount, 1);
      expect(sink.appliedBatches.single, hasLength(1));
      expect(service.state.value, SyncState.idle);
      expect(service.pendingCount.value, 0);

      final raw = await db.getDatabase(deviceId);
      expect(await raw.query('sync_outbox'), isEmpty);
    });

    test('drains a batch in parents-first order regardless of insert order',
        () async {
      final db = await freshDb('sync_svc_order_');
      // Deliberately write children before/around the parent — the drain
      // must re-sort by kSyncEntityOrder (boxes → folders → images).
      // upload_records no longer enqueues at all.
      await db.insertUploadRecord(
        deviceId: deviceId,
        scanningOpr: 'alice',
        boxDetails: 'BOX-1',
        filename: 'IMG_1.jpg',
        format: 'jpg',
        createdAt: DateTime(2026, 1, 1),
      );
      final boxId =
          await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');
      final folderId = await db.insertCaptureFolder(
        deviceId: deviceId,
        folder: _folder(boxId),
        isComplete: false,
      );
      await db.assignImageToFolder(
        deviceId: deviceId,
        boxId: boxId,
        folderId: folderId,
        deviceFilename: 'IMG_1.jpg',
      );

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      // One source (the stable DB — monthly files no longer carry outboxes),
      // one batch: box + folder + image, parents first.
      expect(sink.appliedBatches, hasLength(1));
      final applied = sink.appliedBatches.single;
      expect(applied, hasLength(3));
      final order = applied.map((r) => r.entity).toList();
      expect(order.indexOf('capture_boxes'), lessThan(order.indexOf('capture_folders')));
      expect(order.indexOf('capture_folders'), lessThan(order.indexOf('capture_images')));
    });

    test('inserting a replacement record never enqueues an outbox row, '
        'even with sync enabled', () async {
      final db = await freshDb('sync_svc_replacement_');
      await db.insertReplacementRecord(
        deviceId: deviceId,
        sequenceIndex: 1,
        dateKey: '20260101',
        originalFilename: 'IMG_2.jpg',
        replacementFilename: 'IMG_2_r1.jpg',
        replacementLocalPath: 'C:/tmp/IMG_2_r1.jpg',
      );

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      expect(sink.applyCallCount, 0);
      expect(service.state.value, SyncState.idle);
      expect(service.pendingCount.value, 0);
    });

    test('respects batchSize: drains at most N rows per tick', () async {
      final db = await freshDb('sync_svc_batch_');
      for (var i = 0; i < 5; i++) {
        await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-$i');
      }

      final sink = FakeSyncSink();
      final service =
          SyncService(db: db, sink: sink, deviceId: deviceId, batchSize: 2);

      await service.syncNow();
      expect(sink.appliedBatches, hasLength(1));
      expect(sink.appliedBatches[0], hasLength(2));
      expect(service.pendingCount.value, 3);

      await service.syncNow();
      expect(sink.appliedBatches, hasLength(2));
      expect(sink.appliedBatches[1], hasLength(2));
      expect(service.pendingCount.value, 1);
    });

    test('a generic write failure leaves the row pending with attempts++ '
        'and a scheduled retry, state=error', () async {
      final db = await freshDb('sync_svc_fail_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      // alwaysThrow, not a single queued error: a batch failure is retried row
      // by row to isolate a poison row, so a row that only failed once would be
      // acked on the retry (see sync_batch_isolation_test.dart).
      final sink = FakeSyncSink(alwaysThrow: Exception('boom'));
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      expect(service.state.value, SyncState.error);
      expect(service.lastError.value, contains('boom'));

      final raw = await db.getDatabase(deviceId);
      final rows = await raw.query('sync_outbox');
      expect(rows, hasLength(1)); // not acked — still pending
      expect(rows.single['attempts'], 1);
      expect(rows.single['next_attempt_at'], isNotNull);
      expect(rows.single['last_error'], contains('boom'));
      expect(service.pendingCount.value, 1);
    });

    test('exponential backoff grows across repeated failures', () async {
      final db = await freshDb('sync_svc_backoff_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink(alwaysThrow: Exception('e1'));
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      final raw = await db.getDatabase(deviceId);
      final firstNext = DateTime.parse(
          (await raw.query('sync_outbox')).single['next_attempt_at'] as String);
      final firstDelay = firstNext.difference(DateTime.now());

      // Simulate the retry becoming due; the sink keeps failing.
      await raw.update('sync_outbox', {'next_attempt_at': null});
      await service.syncNow();

      final secondRow = (await raw.query('sync_outbox')).single;
      expect(secondRow['attempts'], 2);
      final secondDelay =
          DateTime.parse(secondRow['next_attempt_at'] as String)
              .difference(DateTime.now());

      // attempt 2's base delay (10s) should clearly exceed attempt 1's (5s),
      // allowing generous slack for jitter and test execution time.
      expect(secondDelay, greaterThan(firstDelay - const Duration(seconds: 2)));
      expect(secondDelay, greaterThan(const Duration(seconds: 8)));
    });

    test('a connect failure sets state=offline without touching attempts '
        '(transient, not a write failure)', () async {
      final db = await freshDb('sync_svc_offline_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink =
          FakeSyncSink(queuedErrors: [const SyncConnectException('no route to host')]);
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      expect(service.state.value, SyncState.offline);
      expect(service.lastError.value, 'no route to host');

      final raw = await db.getDatabase(deviceId);
      final row = (await raw.query('sync_outbox')).single;
      expect(row['attempts'], 0); // untouched — no per-row backoff
      expect(row['next_attempt_at'], isNull);
    });

    test('a non-connect write failure sets state=error and backs the row off',
        () async {
      final db = await freshDb('sync_svc_drift_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink =
          FakeSyncSink(alwaysThrow: StateError('project not in PG yet'));
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      expect(service.state.value, SyncState.error);
      expect(service.lastError.value, contains('project not in PG yet'));
      final raw = await db.getDatabase(deviceId);
      final row = (await raw.query('sync_outbox')).single;
      expect(row['attempts'], 1); // standard per-batch backoff
      expect(row['next_attempt_at'], isNotNull);
    });

    test('a row scheduled in the future is not selected until its time arrives',
        () async {
      final db = await freshDb('sync_svc_future_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');
      final raw = await db.getDatabase(deviceId);
      await raw.update('sync_outbox', {
        'next_attempt_at':
            DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
      });

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      expect(sink.applyCallCount, 0);
      expect(service.state.value, SyncState.idle);
      expect(service.pendingCount.value, 1); // pending, just not due yet
    });

    test('reentrancy guard: overlapping syncNow calls only drain once', () async {
      final db = await freshDb('sync_svc_reentrant_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await Future.wait([service.syncNow(), service.syncNow()]);

      expect(sink.applyCallCount, lessThanOrEqualTo(1));
    });

    test(
        'drainEnabled=false skips the outbox drain but the users/projects '
        'pull still runs (Fix 7: the pull can never be turned off '
        'independently of PG being configured)', () async {
      final db = await freshDb('sync_svc_drain_disabled_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink();
      final store =
          UsersStore(updatedAt: DateTime(2026, 7, 21), updatedBy: 'pg-pull');
      sink.storeToPull = store;
      UsersStore? applied;
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: deviceId,
        drainEnabled: false,
        applyPulledStore: (s) async => applied = s,
      );
      await service.syncNow();

      expect(applied, same(store));
      expect(sink.applyCallCount, 0);
      expect(service.pendingCount.value, 0); // never touched, drain disabled
      expect(service.state.value, SyncState.idle);

      final raw = await db.getDatabase(deviceId);
      expect(await raw.query('sync_outbox'), hasLength(1)); // untouched
    });

    test(
        'a torn outbox payload escapes the fine-grained handling but is '
        'caught by the catch-all tick backstop instead of reaching the '
        'unawaited timer caller (Fix 9)', () async {
      final db = await freshDb('sync_svc_torn_payload_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');
      final raw = await db.getDatabase(deviceId);
      await raw.update('sync_outbox', {'payload': '{not valid json'});

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow(); // must complete, not throw

      expect(service.state.value, SyncState.error);
      expect(service.lastError.value, isNotNull);
      expect(sink.applyCallCount, 0);
    });

    test('pull runs BEFORE the outbox drain (FK parents first) and the '
        'box-name pull runs at the tail', () async {
      final db = await freshDb('sync_svc_pull_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink();
      sink.boxNamesByProject['PRJ-1'] = {'CLOUD BOX'};
      final store = UsersStore(updatedAt: DateTime(2026, 7, 21), updatedBy: 'pg-pull');
      sink.storeToPull = store;
      UsersStore? applied;
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: deviceId,
        applyPulledStore: (s) async => applied = s,
        activeProjectKey: () => 'PRJ-1',
      );
      await service.syncNow();

      expect(applied, same(store));
      expect(sink.events, ['pull', 'apply', 'fetchBoxNames']);
      expect(CloudBoxNames.instance.namesFor('PRJ-1'), {'cloud box'});
      CloudBoxNames.instance.clear();
    });

    test('no applyPulledStore configured skips the pull but still drains',
        () async {
      final db = await freshDb('sync_svc_pull_skip_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();

      expect(sink.events, isNot(contains('pull')));
      expect(sink.applyCallCount, 1);
      expect(service.state.value, SyncState.idle);
    });

    test('a connect failure during the pull sets state=offline and skips '
        'the rest of the tick', () async {
      final db = await freshDb('sync_svc_pull_offline_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink(
          queuedErrors: [const SyncConnectException('no route to host')]);
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: deviceId,
        applyPulledStore: (_) async {},
      );
      await service.syncNow();

      expect(service.state.value, SyncState.offline);
      expect(service.lastError.value, 'no route to host');
      expect(sink.applyCallCount, 0); // tick bailed before the drain
    });

    test('a generic pull failure keeps the existing snapshot untouched, '
        'sets state=error, and the drain still runs', () async {
      final db = await freshDb('sync_svc_pull_error_');
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');

      final sink = FakeSyncSink(queuedErrors: [Exception('boom')]);
      var applyCalled = false;
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: deviceId,
        applyPulledStore: (_) async => applyCalled = true,
      );
      await service.syncNow();

      expect(applyCalled, isFalse);
      expect(service.state.value, SyncState.error);
      expect(service.lastError.value, contains('boom'));
      expect(sink.applyCallCount, 1); // drain still ran despite the pull failure
    });
  });
}
