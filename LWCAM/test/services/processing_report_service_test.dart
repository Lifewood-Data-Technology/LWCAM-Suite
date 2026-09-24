import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/services/processing_report_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

CaptureFolder _folder(int boxId) => CaptureFolder(
      boxId: boxId,
      coverTag: 'Cover',
      title: 'T',
      volume: 'V file no. 1',
      startDate: '1914',
      endDate: '1918',
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory work;
  late String stateFile;

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

  setUp(() async {
    work = await _tempDir('proc_report_svc_');
    stateFile = p.join(work.path, 'state.json');
  });

  Future<void> writeState(Map<String, Map<String, dynamic>> completed) async {
    await File(stateFile)
        .writeAsString(jsonEncode({'version': 1, 'completed': completed}));
  }

  Future<String> writeOutput(
    String name,
    Map<String, dynamic> manifest,
  ) async {
    final out = p.join(work.path, 'out', name);
    await Directory(out).create(recursive: true);
    await File(p.join(out, '.deskew_crop_manifest.json'))
        .writeAsString(jsonEncode(manifest));
    return out;
  }

  Future<List<Map<String, dynamic>>> outboxRows(
      UploadStatsDB db, String deviceId) async {
    final d = await db.getDatabase(deviceId);
    return d.query('sync_outbox', where: 'entity = ?', whereArgs: ['capture_folder_processing']);
  }

  Map<String, dynamic> manifestWithIdentity({
    required String fingerprint,
    bool thumbCreated = true,
    Map<String, dynamic>? identity,
  }) =>
      {
        'version': 1,
        'source_fingerprint': fingerprint,
        'thumbnails': {'created': thumbCreated, 'dirname': 'thumbs', 'files': []},
        if (identity != null) 'source_identity': identity,
      };

  test('reports a completed folder: enqueues the outbox row, ledgers it, and '
      'mirrors the local folder columns', () async {
    final db = await freshDb('rep_happy_');
    const deviceId = 'SAX01';
    final boxId = await db.insertCaptureBox(
        deviceId: deviceId, boxDetails: 'BOX-1', projectId: 'PRJ-1', projectKey: 'pabc');
    final folderId =
        await db.insertCaptureFolder(deviceId: deviceId, folder: _folder(boxId), isComplete: true);

    final out = await writeOutput(
      'F001',
      manifestWithIdentity(fingerprint: 'fp1', identity: {
        'project_key': 'pabc',
        'project_id': 'PRJ-1',
        'box_name': 'BOX-1',
        'device_id': deviceId,
        'folder_seq': 1,
        'folder_name': 'F001',
      }),
    );
    await writeState({
      r'D:\CAP\20260722\F001': {
        'fingerprint': 'fp1',
        'output_folder': out,
        'retry_required': false,
      },
    });

    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);
    await svc.pollOnce();

    expect(await outboxRows(db, deviceId), hasLength(1));
    expect(
        await db.isProcessingReported(
            inputPath: r'D:\CAP\20260722\F001', fingerprint: 'fp1'),
        isTrue);
    final row = (await (await db.getDatabase(deviceId))
            .query('capture_folders', where: 'id = ?', whereArgs: [folderId]))
        .single;
    expect(row['is_deskewed'], 1);
    expect(row['is_created_thumbnail'], 1);
    expect(row['folder_path'], out);
    expect(row['thumbnail_path'], p.join(out, 'thumbs'));

    // Second poll is a no-op (deduped by the ledger).
    await svc.pollOnce();
    expect(await outboxRows(db, deviceId), hasLength(1));
  });

  // Must match LWIP's own cloud_report.py bit-for-bit: NULL, not a path that
  // doesn't exist, so the two writers of this row never disagree.
  test('thumbnails.created: false reports a NULL thumbnail_path, locally and '
      'in the outbox payload', () async {
    final db = await freshDb('rep_nothumb_');
    const deviceId = 'SAX01';
    final boxId = await db.insertCaptureBox(
        deviceId: deviceId, boxDetails: 'BOX-1', projectId: 'PRJ-1', projectKey: 'pabc');
    final folderId =
        await db.insertCaptureFolder(deviceId: deviceId, folder: _folder(boxId), isComplete: true);

    final out = await writeOutput(
      'F004',
      manifestWithIdentity(fingerprint: 'fp4', thumbCreated: false, identity: {
        'project_key': 'pabc',
        'project_id': 'PRJ-1',
        'box_name': 'BOX-1',
        'device_id': deviceId,
        'folder_seq': 1,
        'folder_name': 'F004',
      }),
    );
    await writeState({
      r'D:\CAP\20260722\F004': {
        'fingerprint': 'fp4',
        'output_folder': out,
        'retry_required': false,
      },
    });

    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);
    await svc.pollOnce();

    final row = (await (await db.getDatabase(deviceId))
            .query('capture_folders', where: 'id = ?', whereArgs: [folderId]))
        .single;
    expect(row['is_created_thumbnail'], 0);
    expect(row['thumbnail_path'], isNull);

    final outboxPayload = jsonDecode(
        (await outboxRows(db, deviceId)).single['payload'] as String) as Map;
    expect(outboxPayload['thumbnail_path'], isNull);
  });

  test('a manifest with no usable identity is skip-ledgered, not reported', () async {
    final db = await freshDb('rep_noid_');
    const deviceId = 'PROCESSING';
    final out = await writeOutput('F002', manifestWithIdentity(fingerprint: 'fp2')); // no identity
    await writeState({
      'in2': {'fingerprint': 'fp2', 'output_folder': out, 'retry_required': false},
    });

    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);
    await svc.pollOnce();

    expect(await outboxRows(db, deviceId), isEmpty);
    // Ledgered so it isn't re-read/re-warned forever.
    expect(
        await db.isProcessingReported(inputPath: 'in2', fingerprint: 'fp2'),
        isTrue);
  });

  test('a retry_required entry is ignored (neither reported nor ledgered)', () async {
    final db = await freshDb('rep_retry_');
    const deviceId = 'PROCESSING';
    final out = await writeOutput(
        'F003',
        manifestWithIdentity(fingerprint: 'fp3', identity: {
          'project_key': 'pabc',
          'box_name': 'BOX-1',
          'folder_seq': 1,
        }));
    await writeState({
      'in3': {'fingerprint': 'fp3', 'output_folder': out, 'retry_required': true},
    });

    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);
    await svc.pollOnce();

    expect(await outboxRows(db, deviceId), isEmpty);
    expect(
        await db.isProcessingReported(inputPath: 'in3', fingerprint: 'fp3'),
        isFalse);
  });

  test('a fingerprint mismatch (output lags state) is left for a later tick', () async {
    final db = await freshDb('rep_mismatch_');
    const deviceId = 'PROCESSING';
    final out = await writeOutput(
        'F004',
        manifestWithIdentity(fingerprint: 'OLD', identity: {
          'project_key': 'pabc',
          'box_name': 'BOX-1',
          'folder_seq': 1,
        }));
    await writeState({
      'in4': {'fingerprint': 'NEW', 'output_folder': out, 'retry_required': false},
    });

    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);
    await svc.pollOnce();

    expect(await outboxRows(db, deviceId), isEmpty);
    expect(
        await db.isProcessingReported(inputPath: 'in4', fingerprint: 'NEW'),
        isFalse); // not ledgered — will retry when the output catches up
  });

  test('a torn/missing state.json never throws and reports nothing', () async {
    final db = await freshDb('rep_torn_');
    const deviceId = 'PROCESSING';
    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);

    // Missing file.
    await svc.pollOnce();
    expect(await outboxRows(db, deviceId), isEmpty);

    // Half-written file.
    await File(stateFile).writeAsString('{"version":1,"comple');
    await svc.pollOnce();
    expect(await outboxRows(db, deviceId), isEmpty);
  });

  test('a re-transfer (new fingerprint) is re-reported after the first was '
      'already ledgered', () async {
    final db = await freshDb('rep_reproc_');
    const deviceId = 'PROCESSING';
    final identity = {'project_key': 'pabc', 'box_name': 'BOX-1', 'folder_seq': 1};

    final out1 = await writeOutput('F005', manifestWithIdentity(fingerprint: 'fpA', identity: identity));
    await writeState({
      'in5': {'fingerprint': 'fpA', 'output_folder': out1, 'retry_required': false},
    });
    final svc = ProcessingReportService(
        db: db, deviceId: deviceId, stateFilePath: stateFile);
    await svc.pollOnce();
    expect(await outboxRows(db, deviceId), hasLength(1));

    // Reprocessed: same folder, new fingerprint + fresh manifest.
    final out2 = await writeOutput('F005', manifestWithIdentity(fingerprint: 'fpB', identity: identity));
    await writeState({
      'in5': {'fingerprint': 'fpB', 'output_folder': out2, 'retry_required': false},
    });
    await svc.pollOnce();

    expect(
        await db.isProcessingReported(inputPath: 'in5', fingerprint: 'fpB'),
        isTrue);
    // Outbox coalesced to one row (same natural key) at the latest state.
    final rows = await outboxRows(db, deviceId);
    expect(rows, hasLength(1));
    expect((jsonDecode(rows.single['payload'] as String) as Map)['folder_path'], out2);
  });
}
