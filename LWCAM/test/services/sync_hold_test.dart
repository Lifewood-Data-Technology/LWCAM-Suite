import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/app_version.dart';
import 'package:lwcam/services/pg_statements.dart' as st;
import 'package:lwcam/services/pg_sync_sink.dart';
import 'package:lwcam/services/sync_models.dart';
import 'package:lwcam/services/sync_service.dart';
import 'package:lwcam/services/sync_sink.dart';
import 'package:postgres/postgres.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_sync_sink.dart';

/// Throws [error] from apply() while [failing]; records heartbeats.
class _ScriptedSink extends FakeSyncSink {
  Object? error;
  final heartbeats = <Map<String, Object?>>[];

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    applyCallCount++;
    if (error != null) throw error!;
  }

  @override
  Future<void> heartbeat({
    required String host,
    required String version,
    required DateTime startedAt,
    required Map<String, Object?> backlog,
    DateTime? lastOk,
    String? lastError,
    DateTime? lastErrorAt,
  }) async {
    heartbeats.add({'host': host, 'version': version, 'backlog': backlog});
  }
}

/// Holds any batch containing a box; applies everything else and logs it.
class _BoxHoldSink extends FakeSyncSink {
  final applied = <String>[];

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    applyCallCount++;
    if (batch.any((r) => r.entity == 'capture_boxes')) {
      throw const SyncHoldException('box belongs to another device');
    }
    applied.addAll(batch.map((r) => '${r.entity}:${r.entityKey}'));
  }
}

/// Answers the schema query with [level] and records every other statement.
class _FakeConnection implements Connection {
  _FakeConnection(this.level);
  final int level;
  final executed = <(String, Object?)>[];

  @override
  dynamic noSuchMethod(Invocation i) {
    if (i.memberName == #isOpen) return true;
    if (i.memberName == #execute) {
      final sql = (i.positionalArguments.first as dynamic).sql as String;
      executed.add((sql, i.namedArguments[#parameters]));
      final schema = ResultSchema([]);
      final rows = sql.contains('schema_migrations')
          ? [
              ResultRow(values: [level], schema: schema),
            ]
          : <ResultRow>[];
      return Future.value(Result(rows: rows, affectedRows: 0, schema: schema));
    }
    return super.noSuchMethod(i);
  }
}

PgSyncSink _sinkOn(_FakeConnection conn) => PgSyncSink(
  host: 'x',
  port: 5432,
  database: 'd',
  user: 'u',
  password: 'p',
  useSsl: false,
)..useConnection(conn);

OutboxRecord _record() => const OutboxRecord(
  id: 1,
  entity: 'capture_boxes',
  entityKey: 'k',
  op: 'upsert',
  payload: {'project_key': 'p'},
  attempts: 0,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const deviceId = 'devHold';

  Future<UploadStatsDB> freshDb() async {
    final base = await Directory.systemTemp.createTemp('sync_hold_');
    final db = UploadStatsDB();
    db.debugOverrideBaseFolderForTests(base.path);
    addTearDown(() async {
      await db.debugCloseAllForTests();
      if (await base.exists()) await base.delete(recursive: true);
    });
    return db;
  }

  Future<Database> seedOne(UploadStatsDB db, {int attempts = 0}) async {
    await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-1');
    final raw = await db.getDatabase(deviceId);
    await raw.update('sync_outbox', {'attempts': attempts});
    return raw;
  }

  group('held records', () {
    test(
      'a record past the cap is held, not deleted; drain skips it',
      () async {
        final db = await freshDb();
        final raw = await seedOne(db, attempts: kSyncAttemptCap);
        final sink = _ScriptedSink()
          ..error = const SyncHoldException('box upsert after 20 attempts');
        final service = SyncService(db: db, sink: sink, deviceId: deviceId);

        await service.syncNow();

        final rows = await raw.query('sync_outbox');
        expect(rows, hasLength(1), reason: 'nothing may be lost');
        expect(rows.single['held'], 1);
        expect(rows.single['last_error'], contains('20 attempts'));
        expect(service.heldCount.value, 1);
        expect(service.pendingCount.value, 0);

        final calls = sink.applyCallCount;
        await service.syncNow();
        expect(sink.applyCallCount, calls, reason: 'held rows are not drained');
        expect(await raw.query('sync_outbox'), hasLength(1));
      },
    );

    test(
      'Try again un-holds, resets attempts, and the next drain sends',
      () async {
        final db = await freshDb();
        final raw = await seedOne(db, attempts: kSyncAttemptCap);
        final sink = _ScriptedSink()
          ..error = const SyncHoldException('never appeared');
        final service = SyncService(db: db, sink: sink, deviceId: deviceId);
        await service.syncNow();
        expect(service.heldCount.value, 1);

        sink.error = null; // the cause is fixed
        expect(await service.retryHeld(), 1);
        expect(service.heldCount.value, 0);

        // retryHeld kicks a drain without awaiting it.
        for (var i = 0; i < 100; i++) {
          if ((await raw.query('sync_outbox')).isEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          await raw.query('sync_outbox'),
          isEmpty,
          reason: 'sent and acked',
        );
      },
    );

    test('un-held row starts again from zero attempts', () async {
      final db = await freshDb();
      final raw = await seedOne(db, attempts: kSyncAttemptCap);
      final sink = _ScriptedSink()..error = const SyncHoldException('x');
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await service.syncNow();
      sink.error = StateError('still bad'); // keep it from being acked
      service.paused = true; // so the kicked drain does not run
      await service.retryHeld();
      final row = (await raw.query('sync_outbox')).single;
      expect(row['held'], 0);
      expect(row['attempts'], 0);
      expect(row['next_attempt_at'], isNull);
    });
  });

  group('dependents of a held parent', () {
    Future<void> row(Database raw, String entity, String key, Map payload) =>
        raw.insert('sync_outbox', {
          'entity': entity,
          'entity_key': key,
          'op': 'upsert',
          'payload': jsonEncode(payload),
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        });

    Future<Database> seed(UploadStatsDB db) async {
      final raw = await db.getDatabase(deviceId);
      Map keys(String box, {int? seq, String? image}) => {
        'project_key': 'pabc',
        'box_name': box,
        if (seq != null) 'folder_seq': seq,
        if (image != null) 'image_name': image,
      };
      await row(raw, 'capture_boxes', '1', keys('BOX-1'));
      await row(raw, 'capture_folders', '1', keys('BOX-1', seq: 1));
      await row(raw, 'capture_images', '1|a.jpg', keys('BOX-1', seq: 1, image: 'a.jpg'));
      await row(raw, 'capture_images', '2|b.jpg', keys('BOX-1', seq: 2, image: 'b.jpg'));
      await row(raw, 'capture_boxes', '9', keys('BOX-OTHER'));
      return raw;
    }

    test('a held box holds its folders and images at once, no attempts '
        'burned; another box is unaffected', () async {
      final db = await freshDb();
      final raw = await seed(db);
      // The other box must not be held by the sink either.
      final sink = _BoxHoldSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);
      await raw.delete('sync_outbox', where: "entity_key = '9'");

      await service.syncNow();

      final rows = await raw.query('sync_outbox');
      expect(rows, hasLength(4), reason: 'nothing may be lost');
      expect(rows.every((r) => r['held'] == 1), isTrue);
      expect(rows.every((r) => r['attempts'] == 0), isTrue);
      expect(sink.applied, isEmpty, reason: 'children must not be sent');
      expect(service.heldCount.value, 4);
    });

    test('a held folder holds only its own folder images; a row queued later '
        'is caught by the next tick; Try again releases all together',
        () async {
      final db = await freshDb();
      final raw = await db.getDatabase(deviceId);
      Map k(int seq) => {'project_key': 'pabc', 'box_name': 'B', 'folder_seq': seq};
      await row(raw, 'capture_folders', '1', k(1));
      await row(raw, 'capture_images', '1|a', k(1));
      await row(raw, 'capture_images', '2|b', k(2));
      await raw.update('sync_outbox', {'held': 1}, where: "entity = 'capture_folders'");
      final sink = _BoxHoldSink();
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();
      var held = {
        for (final r in await raw.query('sync_outbox')) r['entity_key']: r['held'],
      };
      expect(held['1'], 1);
      expect(held['1|a'], 1);
      expect(held['2|b'], isNull, reason: 'other folder was sent and acked');

      await row(raw, 'capture_images', '1|late', k(1));
      await service.syncNow();
      held = {
        for (final r in await raw.query('sync_outbox')) r['entity_key']: r['held'],
      };
      expect(held['1|late'], 1);

      service.paused = true; // do not drain the released rows
      expect(await service.retryHeld(), 3);
      expect((await raw.query('sync_outbox')).every((r) => r['held'] == 0), isTrue);
    });
  });

  group('schema level', () {
    test('too old: the service queues, counts no attempt, warns', () async {
      final db = await freshDb();
      final raw = await seedOne(db);
      final sink = _ScriptedSink()..error = const SchemaTooOldException(6);
      final service = SyncService(db: db, sink: sink, deviceId: deviceId);

      await service.syncNow();

      final row = (await raw.query('sync_outbox')).single;
      expect(row['attempts'], 0);
      expect(row['held'], 0);
      expect(service.schemaWarning.value, contains('needs level 7, has 6'));
      expect(service.schemaWarning.value, contains('LWCamDatabaseSetup'));

      sink.error = null; // database upgraded: re-checked on the next tick
      await service.syncNow();
      expect(service.schemaWarning.value, isNull);
      expect(await raw.query('sync_outbox'), isEmpty);
    });

    test('sink: level 6 -> no write is attempted', () async {
      final conn = _FakeConnection(6);
      final sink = _sinkOn(conn);
      await expectLater(
        sink.apply([_record()]),
        throwsA(isA<SchemaTooOldException>()),
      );
      await expectLater(
        sink.heartbeat(
          host: 'h',
          version: 'v',
          startedAt: DateTime.now(),
          backlog: {},
        ),
        throwsA(isA<SchemaTooOldException>()),
      );
      expect(
        conn.executed,
        hasLength(2),
        reason: 'only the level query, twice',
      );
      expect(
        conn.executed.every((e) => e.$1.contains('schema_migrations')),
        isTrue,
      );
    });

    test('sink: level 7 -> heartbeat upserts once', () async {
      final conn = _FakeConnection(7);
      final sink = _sinkOn(conn);
      await sink.heartbeat(
        host: 'PC1',
        version: '1.1.0+abc',
        startedAt: DateTime.utc(2026, 9, 30, 1),
        backlog: {'unsent': 2, 'oldest_unsent_minutes': 3, 'held': 1},
      );
      expect(conn.executed, hasLength(2));
      expect(conn.executed.last.$1, contains('INSERT INTO service_heartbeat'));
    });
  });

  group('heartbeat', () {
    test('statement shape', () {
      final s = st.heartbeatUpsertSql(
        host: 'PC1',
        version: '1.1.0+abc',
        startedAt: DateTime.utc(2026, 9, 30, 1),
        backlog: {'unsent': 2, 'oldest_unsent_minutes': 3, 'held': 1},
      );
      expect(s.sql, contains("VALUES ('capture', @host"));
      expect(s.sql, contains('ON CONFLICT (part, host) DO UPDATE'));
      // Recovery clears the error; only last_ok is sticky.
      expect(s.sql, contains('last_error = EXCLUDED.last_error,'));
      expect(s.sql, contains('last_error_at = EXCLUDED.last_error_at,'));
      expect(s.sql, contains('COALESCE(EXCLUDED.last_ok'));
      expect(s.parameters['host'], 'PC1');
      expect(s.parameters['version'], '1.1.0+abc');
      expect(s.parameters['started_at'], '2026-09-30T01:00:00.000Z');
      expect(s.parameters['last_ok'], isNull);
      expect(
        s.parameters['backlog'],
        '{"unsent":2,"oldest_unsent_minutes":3,"held":1}',
      );
    });

    test('backlog counts unsent (not held) and held', () async {
      final db = await freshDb();
      await seedOne(db);
      await db.insertCaptureBox(deviceId: deviceId, boxDetails: 'BOX-2');
      final raw = await db.getDatabase(deviceId);
      final firstId = (await raw.query(
        'sync_outbox',
        orderBy: 'id',
      )).first['id'];
      await raw.update(
        'sync_outbox',
        {'held': 1},
        where: 'id = ?',
        whereArgs: [firstId],
      );
      final sink = _ScriptedSink();
      final service = SyncService(
        db: db,
        sink: sink,
        deviceId: deviceId,
        version: '1.1.0+abc',
        hostName: 'PC1',
      );

      await service.heartbeatNow();

      expect(sink.heartbeats, hasLength(1));
      final beat = sink.heartbeats.single;
      expect(beat['host'], 'PC1');
      expect(beat['version'], '1.1.0+abc');
      final backlog = beat['backlog'] as Map<String, Object?>;
      expect(backlog['unsent'], 1);
      expect(backlog['held'], 1);
      expect(backlog['oldest_unsent_minutes'], 0);
    });
  });

  test('version: VERSION.txt is read, dev when absent', () async {
    final dir = await Directory.systemTemp.createTemp('ver_');
    addTearDown(() => dir.delete(recursive: true));
    expect(readAppVersion(dir), 'dev');
    await File('${dir.path}/VERSION.txt').writeAsString('1.1.0+abc123\r\n');
    expect(readAppVersion(dir), '1.1.0+abc123');
  });
}
