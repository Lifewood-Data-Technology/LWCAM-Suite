import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/fs_probe.dart';
import 'package:lwcam/services/pg_client.dart';
import 'package:lwcam/services/pg_statements.dart';
import 'package:lwcam/services/processing_marker_service.dart';
import 'package:lwcam/services/rework_service.dart';
import 'package:lwcam/services/sync_sink.dart';
import 'package:lwcam/services/transfer_queue_service.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

/// A file whose exists() never answers - a dead SMB share.
class _HangingFile extends Fake implements File {
  @override
  Future<bool> exists() => Completer<bool>().future;
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('r3_'));
  tearDown(() async => tmp.delete(recursive: true));

  group('probeExists', () {
    test('found / not found / unreachable on timeout', () async {
      final f = File(p.join(tmp.path, 'a.txt'))..writeAsStringSync('x');
      expect(await probeExists(f), FsProbe.found);
      expect(await probeExists(File(p.join(tmp.path, 'nope'))), FsProbe.notFound);
      expect(
        await probeExists(_HangingFile(), timeout: const Duration(milliseconds: 20)),
        FsProbe.unreachable,
      );
    });

    test('inputFileFor reports found and not found', () async {
      final f = File(p.join(tmp.path, '20260730', 'F1', 'a.jpg'))
        ..createSync(recursive: true);
      final cfg = NodeConfig(destinationPath: tmp.path);
      final hit = await ReworkService.inputFileFor(cfg,
          folderPath: r'C:\LWIP\20260730\F1', imageName: 'a.jpg');
      expect(hit.status, FsProbe.found);
      expect(hit.file!.path, f.path);
      final miss = await ReworkService.inputFileFor(cfg,
          folderPath: r'C:\LWIP\20260730\F1', imageName: 'b.jpg');
      expect(miss.status, FsProbe.notFound);
      expect(miss.unreachable, isFalse);
    });
  });

  group('thumbnail flag', () {
    void manifest(String dir, bool created) {
      File(p.join(dir, '.deskew_crop_manifest.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode({'thumbnails': {'created': created}}));
    }

    test('re-rooted under the output root; unknown is null, not false', () async {
      final out = p.join(tmp.path, 'out');
      manifest(p.join(out, '20260730', 'F1'), true);
      final cfg = NodeConfig(processingOutputRoot: out);
      expect(
        await ReworkService.thumbnailCreatedForTest(cfg, r'C:\LWIP\2.Batches\20260730\F1'),
        isTrue,
      );
      // LWIP's own spelling is unreadable here and no output root is set.
      expect(
        await ReworkService.thumbnailCreatedForTest(
            NodeConfig(), r'Z:\lwip-gone\20260730\F9'),
        isNull,
      );
    });

    test('a one-PC path still reads directly', () async {
      final dir = p.join(tmp.path, '20260730', 'F2');
      manifest(dir, false);
      expect(await ReworkService.thumbnailCreatedForTest(NodeConfig(), dir), isFalse);
    });

    test('unknown leaves is_created_thumbnail out of the UPDATE', () {
      final unknown = folderQcStatusPendingSql(pgFolderId: 3);
      expect(unknown.sql, isNot(contains('is_created_thumbnail')));
      expect(unknown.parameters.containsKey('is_created_thumbnail'), isFalse);
      final known = folderQcStatusPendingSql(pgFolderId: 3, isCreatedThumbnail: true);
      expect(known.sql, contains('is_created_thumbnail = @is_created_thumbnail'));
      expect(known.parameters['is_created_thumbnail'], isTrue);
    });
  });

  group('PG connectivity mapping', () {
    test('link failures become SyncConnectException; statement errors do not', () async {
      for (final e in <Object>[
        TimeoutException('slow'),
        const SocketException('reset'),
        PgException('Connection is closed'),
      ]) {
        expect(isPgConnectivityError(e), isTrue, reason: '$e');
        await expectLater(
          mapPgConnectivity<void>(() async => throw e),
          throwsA(isA<SyncConnectException>()),
        );
      }
      await expectLater(
        mapPgConnectivity<void>(() async => throw StateError('bad data')),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('transferWaitBacklog counts waiting jobs and the oldest wait', () {
    final now = DateTime(2026, 9, 30, 12);
    expect(transferWaitBacklog(const [], now),
        {'transfers_waiting': 0, 'oldest_transfer_wait_minutes': 0});
    expect(
      transferWaitBacklog([
        now.subtract(const Duration(minutes: 90)),
        now.subtract(const Duration(minutes: 5)),
      ], now),
      {'transfers_waiting': 2, 'oldest_transfer_wait_minutes': 90},
    );
  });

  group('markers', () {
    void marker(String day, String folder, Map<String, Object?> m) =>
        File(p.join(day, folder, kProcessingMarkerName))
          ..createSync(recursive: true)
          ..writeAsStringSync(jsonEncode(m));

    test('a foreign marker reserves the folder name; our own does not', () async {
      final day = p.join(tmp.path, '20260930');
      marker(day, 'Vol', {'project_key': 'P', 'box_name': 'OTHER', 'folder_seq': 1});
      marker(day, 'Mine', {'project_key': 'P', 'box_name': 'BOX', 'folder_seq': 2});
      Directory(p.join(day, 'Empty')).createSync(recursive: true);
      final foreign = await foreignMarkerFolderNames(
        dayDir: day,
        boxKeys: {'project_key': 'P', 'box_name': 'BOX'},
        folderSeqByName: {'Vol': 1, 'Mine': 2, 'Empty': 3, 'Absent': 4},
      );
      expect(foreign, {'vol'});
    });

    test('rework_in_progress is set, then cleared with a fresh image_count', () async {
      final day = p.join(tmp.path, '20260930');
      final dir = p.join(day, 'F');
      marker(day, 'F', {'project_key': 'P', 'image_count': 1, 'extra': 'kept'});
      File(p.join(dir, 'a.jpg')).writeAsStringSync('x');
      File(p.join(dir, 'b.jpg')).writeAsStringSync('x');
      Map<String, dynamic> read() =>
          jsonDecode(File(p.join(dir, kProcessingMarkerName)).readAsStringSync())
              as Map<String, dynamic>;

      await setReworkInProgress(dir, true);
      expect(read()['rework_in_progress'], isTrue);
      expect(read()['image_count'], 1);

      await setReworkInProgress(dir, false);
      expect(read().containsKey('rework_in_progress'), isFalse);
      expect(read()['image_count'], 2);
      expect(read()['extra'], 'kept');
    });

    test('a folder without a marker is left alone', () async {
      final dir = p.join(tmp.path, 'nomarker');
      Directory(dir).createSync();
      await setReworkInProgress(dir, true);
      expect(File(p.join(dir, kProcessingMarkerName)).existsSync(), isFalse);
    });
  });
}
