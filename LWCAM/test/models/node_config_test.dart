import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('NodeConfig JSON round-trip', () {
    test('preserves all fields', () {
      final config = NodeConfig(
        pgHost: '192.168.1.10',
        pgPort: 5433,
        pgDatabase: 'lwcam',
        pgUser: 'lwcam_station',
        pgPassword: 'secret',
        pgUseSsl: true,
        syncEnabled: true,
        syncIntervalSeconds: 60,
        usersStorePath: r'\\nas\lwcam_shared',
        pgConnectionEnabled: false,
        destinationPath: r'D:\captures',
        processingEnabled: true,
        processingInputRoot: r'\\nas\captures',
        processingOutputRoot: r'\\nas\captures_processed',
        processingWorkers: 6,
        qcInputRoot: r'D:\QC\Input',
        qcOutputRoot: r'D:\QC\Output',
        qcJwtSecret: '12345678901234567890123456789012',
        qcJwtExpireMinutes: 240,
        exportCsvEncoding: 'utf-8-sig',
        exportCsvLineEnding: 'LF',
        exportTempRetentionHours: 48,
        uploadEnabled: true,
      );
      final back = NodeConfig.fromJson(config.toJson());
      expect(back.pgHost, '192.168.1.10');
      expect(back.pgPort, 5433);
      expect(back.pgDatabase, 'lwcam');
      expect(back.pgUser, 'lwcam_station');
      expect(back.pgPassword, 'secret');
      expect(back.pgUseSsl, isTrue);
      expect(back.syncEnabled, isTrue);
      expect(back.syncIntervalSeconds, 60);
      expect(back.usersStorePath, r'\\nas\lwcam_shared');
      expect(back.pgConnectionEnabled, isFalse);
      expect(back.destinationPath, r'D:\captures');
      expect(back.processingEnabled, isTrue);
      expect(back.processingInputRoot, r'\\nas\captures');
      expect(back.processingOutputRoot, r'\\nas\captures_processed');
      expect(back.processingWorkers, 6);
      expect(back.qcInputRoot, r'D:\QC\Input');
      expect(back.qcOutputRoot, r'D:\QC\Output');
      expect(back.qcJwtSecret, '12345678901234567890123456789012');
      expect(back.qcJwtExpireMinutes, 240);
      expect(back.exportCsvEncoding, 'utf-8-sig');
      expect(back.exportCsvLineEnding, 'LF');
      expect(back.exportTempRetentionHours, 48);
      expect(back.uploadEnabled, isTrue);
    });

    test(
      'destinationPath defaults to null (unconfigured station) when absent',
      () {
        final back = NodeConfig.fromJson(<String, Object?>{});
        expect(back.destinationPath, isNull);
      },
    );

    test(
      'processing, QC paths, and upload fields default off/null/0 when absent '
      '(capture-only station is unaffected)',
      () {
        final back = NodeConfig.fromJson(<String, Object?>{});
        expect(back.processingEnabled, isFalse);
        expect(back.processingInputRoot, isNull);
        expect(back.processingOutputRoot, isNull);
        expect(back.processingWorkers, 0);
        expect(back.qcInputRoot, isNull);
        expect(back.qcOutputRoot, isNull);
        expect(back.qcJwtSecret, isNull);
        expect(back.qcJwtExpireMinutes, 480);
        expect(back.exportCsvEncoding, 'utf-8');
        expect(back.exportCsvLineEnding, 'CRLF');
        expect(back.exportTempRetentionHours, 24);
        expect(back.uploadEnabled, isFalse);
      },
    );

    test(
      'usersStorePath defaults to null (local default folder) when absent',
      () {
        final back = NodeConfig.fromJson(<String, Object?>{});
        expect(back.usersStorePath, isNull);
      },
    );

    test('pgConnectionEnabled defaults to true when absent (existing '
        'stations keep trying PG exactly as before) — LWCAM never reads it, '
        'this is purely so a save from LWCAM never resets LWCam Admin\'s '
        'setting', () {
      final back = NodeConfig.fromJson(<String, Object?>{});
      expect(back.pgConnectionEnabled, isTrue);
    });

    test('defaults missing/malformed fields instead of throwing', () {
      final back = NodeConfig.fromJson(<String, Object?>{});
      expect(back.pgPort, 5432);
      expect(back.pgUseSsl, isFalse);
      expect(back.syncEnabled, isFalse); // critical: default OFF
      expect(back.syncIntervalSeconds, 30);
    });

    test('a legacy config file with role/cloud/machineId keys still loads '
        '(keys ignored)', () {
      final back = NodeConfig.fromJson({
        'role': 'central',
        'cloudUrl': 'https://xyz.supabase.co',
        'cloudToken': 'token123',
        'machineId': 'm123',
        'syncEnabled': true,
      });
      expect(back.syncEnabled, isTrue);
    });
  });

  group('NodeConfigService', () {
    late Directory tempDir;

    NodeConfigService makeService() => NodeConfigService(
      getConfigPath: () => p.join(tempDir.path, NodeConfigService.fileName),
    );

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('node_config_');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test(
      'load() with no file on disk creates and persists a fresh config',
      () async {
        final svc = makeService();
        final config = await svc.load();
        expect(config.syncEnabled, isFalse);
        expect(
          await File(p.join(tempDir.path, NodeConfigService.fileName)).exists(),
          isTrue,
        );
      },
    );

    test(
      'save() then a fresh service instance reloads the saved config',
      () async {
        final svc = makeService();
        final config = await svc.load();
        await svc.save(config.copyWith(syncEnabled: true));

        final reloaded = await makeService().load();
        expect(reloaded.syncEnabled, isTrue);
      },
    );

    test(
      'a corrupt file on disk degrades to a fresh config rather than throwing',
      () async {
        final path = p.join(tempDir.path, NodeConfigService.fileName);
        await File(path).writeAsString('not json');
        final svc = makeService();
        final config = await svc.load();
        expect(config.syncEnabled, isFalse);
      },
    );

    test(
      'cached returns null before load() and the loaded config after',
      () async {
        final svc = makeService();
        expect(svc.cached, isNull);
        final config = await svc.load();
        expect(svc.cached?.syncIntervalSeconds, config.syncIntervalSeconds);
      },
    );

    test(
      'load -> copyWith -> save keeps the adminPg* fields LWCam Admin adds and other '
      'unknown keys byte-for-byte',
      () async {
        final path = p.join(tempDir.path, NodeConfigService.fileName);
        const blob = 'AQAAANCMnd8BFdERjHoAwE/Cl+sBAAAA+/x1==';
        await File(path).writeAsString(jsonEncode({
          'pgHost': 'db',
          'adminPgUser': 'lwcam_admin',
          'adminPgPasswordProtected': blob,
          'role': 'legacy',
          'somethingNew': {'a': [1, 2]},
        }));

        final svc = makeService();
        final config = await svc.load();
        expect(config.extras['adminPgUser'], 'lwcam_admin');
        await svc.save(config.copyWith(syncEnabled: true));

        final saved =
            jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
        expect(saved['adminPgUser'], 'lwcam_admin');
        expect(saved['adminPgPasswordProtected'], blob);
        expect(saved['role'], 'legacy');
        expect(saved['somethingNew'], {'a': [1, 2]});
        expect(saved['syncEnabled'], true);
        expect(saved['pgHost'], 'db');
        // Known keys are never duplicated into extras.
        expect(config.extras.containsKey('pgHost'), isFalse);
      },
    );
  });
}
