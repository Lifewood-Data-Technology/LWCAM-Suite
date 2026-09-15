import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/sync_models.dart';
import 'package:lwcam/services/sync_service.dart';
import 'package:lwcam/services/sync_sink.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A tick must drain EVERY device's outbox on this PC, not just the bound one.
///
/// Draining only the bound device stranded other operators' rows on a shared
/// station: a device pushed only while its own account was logged in. Live on
/// 2026-07-31, capturing + transferring on SAX01 and then switching to SAX04
/// left 14 SAX01 rows unsent (attempts=0, never tried), so the cloud held a
/// fully transferred box at status 'OPEN' with empty folder_names and
/// pre-rename image names until SAX01 logged back in.

class _RecordingSink implements SyncSink {
  final List<OutboxRecord> applied = [];

  @override
  Future<void> apply(List<OutboxRecord> batch) async => applied.addAll(batch);

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

Future<UploadStatsDB> _freshDb(String prefix) async {
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

Future<int> _outboxCount(UploadStatsDB db, String deviceId) async {
  final handle = await db.getDatabase(deviceId);
  final rows = await handle.rawQuery('SELECT COUNT(*) AS c FROM sync_outbox');
  return (rows.first['c'] as num).toInt();
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('outbox sources span every device on the PC', () {
    test(
      'getOutboxDatabases lists all device DBs, bound device FIRST',
      () async {
        final db = await _freshDb('sources_all_devices_');

        // Three devices have captured on this station at some point.
        for (final dev in ['SAX01', 'SAX04', 'PROCESSING']) {
          await db.insertCaptureBox(
            deviceId: dev,
            boxDetails: 'BOX-$dev',
            projectId: 'PRJ-1',
          );
        }

        final sources = await db.getOutboxDatabases('SAX04');
        expect(sources, hasLength(3));
        // Bound device first — its rows are the ones actively being written.
        expect(sources.first, same(await db.getDatabase('SAX04')));
        expect(
          sources.map((s) => s.path.split(Platform.pathSeparator).last).toSet(),
          {
            'lwcam_stats_SAX04.db',
            'lwcam_stats_SAX01.db',
            'lwcam_stats_PROCESSING.db',
          },
        );
      },
    );

    test('a device with no DB file yet contributes nothing', () async {
      final db = await _freshDb('sources_single_');
      await db.insertCaptureBox(
        deviceId: 'SAX01',
        boxDetails: 'BOX-1',
        projectId: 'PRJ-1',
      );

      // Binding to a device that has never captured still yields its own
      // (freshly created) DB plus the one that exists.
      final sources = await db.getOutboxDatabases('SAX09');
      expect(sources, hasLength(2));
      expect(sources.first, same(await db.getDatabase('SAX09')));
    });

    test("one tick drains the OTHER device's stranded rows", () async {
      final db = await _freshDb('drain_other_device_');

      // SAX01 captures and transfers a box, then the operator logs into SAX04
      // before SAX01's rows ever drained — the live scenario.
      final boxId = await db.insertCaptureBox(
        deviceId: 'SAX01',
        boxDetails: '676 7676-6767',
        projectId: 'PRJ-1',
        projectKey: 'pk1',
      );
      await db.markCaptureBoxTransferred(
        deviceId: 'SAX01',
        boxId: boxId,
        transferredTo: r'C:\out',
      );
      await db.insertCaptureBox(
        deviceId: 'SAX04',
        boxDetails: '787 7878-8787',
        projectId: 'PRJ-1',
      );

      final strandedBefore = await _outboxCount(db, 'SAX01');
      expect(strandedBefore, greaterThan(0));

      final sink = _RecordingSink();
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: 'SAX04', // bound to the OTHER device
        tickInterval: const Duration(hours: 1),
      );
      await service.syncNow();

      // Both devices' outboxes are now empty, and the sink saw both boxes.
      expect(await _outboxCount(db, 'SAX01'), 0);
      expect(await _outboxCount(db, 'SAX04'), 0);
      final names = sink.applied
          .where((r) => r.entity == 'capture_boxes')
          .map((r) => r.payload?['box_name'])
          .toSet();
      expect(names, containsAll(['676 7676-6767', '787 7878-8787']));

      // The stranded box's TRANSFERRED status is what the cloud was missing.
      final transferred = sink.applied.firstWhere(
        (r) =>
            r.entity == 'capture_boxes' &&
            r.payload?['box_name'] == '676 7676-6767',
      );
      expect(transferred.payload?['status'], 'TRANSFERRED');
      expect(transferred.payload?['transfer_end_at'], isNotNull);

      expect(service.state.value, SyncState.idle);
      expect(service.pendingCount.value, 0);
    });

    test(
      'rows are ordered parents-before-children WITHIN each device',
      () async {
        final db = await _freshDb('drain_order_');

        for (final dev in ['SAX01', 'SAX04']) {
          final boxId = await db.insertCaptureBox(
            deviceId: dev,
            boxDetails: 'BOX-$dev',
            projectId: 'PRJ-1',
            projectKey: 'pk1',
          );
          await db.insertCaptureFolder(
            deviceId: dev,
            folder: CaptureFolder(
              boxId: boxId,
              coverTag: 'Cover Will Be Captured',
              title: 'WWI Medical Files',
              volume: 'V file no. 1',
              startDate: '1914',
              endDate: '1918',
            ),
            isComplete: true,
          );
        }

        final sink = _RecordingSink();
        await SyncService(
          db: db,
          sink: sink,
          deviceId: 'SAX04',
          tickInterval: const Duration(hours: 1),
        ).syncNow();

        // Each device's box must be applied before that device's folder.
        for (final dev in ['SAX01', 'SAX04']) {
          final box = sink.applied.indexWhere(
            (r) =>
                r.entity == 'capture_boxes' &&
                r.payload?['box_name'] == 'BOX-$dev',
          );
          final folder = sink.applied.indexWhere(
            (r) =>
                r.entity == 'capture_folders' &&
                r.payload?['box_name'] == 'BOX-$dev',
          );
          expect(box, isNonNegative, reason: '$dev box row must be applied');
          expect(
            folder,
            isNonNegative,
            reason: '$dev folder row must be applied',
          );
          expect(
            box,
            lessThan(folder),
            reason: '$dev: box must land before its folder',
          );
        }
      },
    );
  });
}
