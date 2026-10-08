import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:lwcam_admin/models/node_config.dart';
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
        exportWorkerCount: 12,
        exportZipOutput: false,
        uploadEnabled: true,
        uploadS3Path: 's3://bucket/exports',
        uploadS3Region: 'ap-southeast-1',
        uploadS3AccessKey: 'AKIA',
        uploadS3SecretKey: ' shh ',
        uploadDoneRoot: r'D:\QC\Uploaded',
        uploadSummaryRoot: r'D:\QC\Upload Reports',
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
      expect(back.exportWorkerCount, 12);
      expect(back.exportZipOutput, isFalse);
      expect(back.uploadEnabled, isTrue);
      expect(back.uploadS3Path, 's3://bucket/exports');
      expect(back.uploadS3Region, 'ap-southeast-1');
      expect(back.uploadS3AccessKey, 'AKIA');
      // Byte-for-byte: a secret is not ours to tidy.
      expect(back.uploadS3SecretKey, ' shh ');
      expect(back.uploadDoneRoot, r'D:\QC\Uploaded');
      expect(back.uploadSummaryRoot, r'D:\QC\Upload Reports');
    });

    test(
      'destinationPath defaults to null (unconfigured station) when absent',
      () {
        final back = NodeConfig.fromJson(<String, Object?>{});
        expect(back.destinationPath, isNull);
      },
    );

    test('processing, QC paths, and upload fields default when absent', () {
      final back = NodeConfig.fromJson(<String, Object?>{});
      expect(back.processingEnabled, isFalse);
      expect(back.processingInputRoot, isNull);
      expect(back.processingOutputRoot, isNull);
      expect(back.processingWorkers, 0);
      // 0 = auto. A config written before this field existed must not read as
      // "one worker" - that would silently make every export serial.
      expect(back.exportWorkerCount, 0);
      // A config written before the toggle existed must keep producing ZIPs -
      // defaulting to false would silently change every project's deliverable.
      expect(back.exportZipOutput, isTrue);
      expect(back.qcInputRoot, isNull);
      expect(back.qcOutputRoot, isNull);
      expect(back.qcJwtSecret, isNull);
      expect(back.qcJwtExpireMinutes, 480);
      expect(back.exportCsvEncoding, 'utf-8');
      expect(back.exportCsvLineEnding, 'CRLF');
      expect(back.exportTempRetentionHours, 24);
      expect(back.uploadEnabled, isFalse);
      expect(back.uploadS3Path, isNull);
      expect(back.uploadS3SecretKey, isNull);
    });

    test('pgConnectionEnabled defaults to true when absent (existing '
        'stations keep trying PG exactly as before)', () {
      final back = NodeConfig.fromJson(<String, Object?>{});
      expect(back.pgConnectionEnabled, isTrue);
    });

    test(
      'usersStorePath defaults to null (local default folder) when absent',
      () {
        final back = NodeConfig.fromJson(<String, Object?>{});
        expect(back.usersStorePath, isNull);
      },
    );

    test('defaults missing/malformed fields instead of throwing', () {
      final back = NodeConfig.fromJson(<String, Object?>{});
      expect(back.pgPort, 5432);
      expect(back.pgUseSsl, isFalse);
      expect(back.syncEnabled, isTrue);
      expect(back.syncIntervalSeconds, 30);
    });

    test(
      'a legacy config file with unknown keys still loads (keys ignored)',
      () {
        final back = NodeConfig.fromJson({
          'role': 'central',
          'cloudUrl': 'https://xyz.supabase.co',
          'syncEnabled': true,
        });
        expect(back.syncEnabled, isTrue);
      },
    );
  });

  group('default capture root', () {
    test('is the pipeline folder beside an installed Admin', () {
      final root = defaultCaptureRoot(
        executablePath: r'C:\Program Files\LW Suite\LWCamAdmin\lwcam_admin.exe',
      );
      expect(root, r'C:\Program Files\LW Suite\LWCam Capture');
      expect(
        p.join(root, captureImagesFolder),
        endsWith(r'LWCam Capture\1.Images'),
      );
      expect(
        p.join(root, captureBatchesFolder),
        endsWith(r'LWCam Capture\2.Batches'),
      );
      expect(
        p.join(root, captureExportFolder),
        endsWith(r'LWCam Capture\3.Export'),
      );
    });

    test('follows a custom install folder', () {
      expect(
        defaultCaptureRoot(
          executablePath: r'D:\Apps\LWSuite\LWCamAdmin\lwcam_admin.exe',
          environment: const {'ProgramFiles': r'C:\Program Files'},
        ),
        r'D:\Apps\LWSuite\LWCam Capture',
      );
    });

    test('falls back to Program Files for a dev/portable build', () {
      expect(
        defaultCaptureRoot(
          executablePath: r'D:\src\LWCamAdmin\build\runner\lwcam_admin.exe',
          environment: const {'ProgramFiles': r'C:\Program Files'},
        ),
        r'C:\Program Files\LWCam\LWCAM',
      );
      expect(
        p.join(
          defaultCaptureRoot(
            executablePath: r'D:\src\LWCamAdmin\build\runner\lwcam_admin.exe',
            environment: const {'ProgramFiles': r'C:\Program Files'},
          ),
          captureImagesFolder,
        ),
        r'C:\Program Files\LWCam\LWCAM\1.Images',
      );
    });
  });

  test(
    'Station Setup form save keeps QC, Upload, and AI values it no longer edits',
    () {
      const loaded = NodeConfig(
        qcInputRoot: r'D:\QC\scratch',
        qcOutputRoot: r'D:\QC\export',
        qcJwtSecret: 'jwt-secret',
        uploadEnabled: true,
        uploadS3Path: 's3://bucket/prefix',
        uploadS3SecretKey: 's3-secret',
        aiReviewEnabled: true,
        aiPreanalysisEnabled: false,
        openrouterApiKey: 'api-key',
      );

      final saved = loaded.copyWith(
        pgHost: 'db.example',
        pgPort: 5433,
        pgUseSsl: true,
        syncEnabled: true,
        destinationPath: r'D:\captures',
        processingEnabled: true,
        processingInputRoot: r'D:\captures',
        processingOutputRoot: r'D:\batches',
      );

      expect(saved.pgHost, 'db.example');
      expect(saved.pgPort, 5433);
      expect(saved.destinationPath, r'D:\captures');
      expect(saved.qcInputRoot, loaded.qcInputRoot);
      expect(saved.qcOutputRoot, loaded.qcOutputRoot);
      expect(saved.qcJwtSecret, loaded.qcJwtSecret);
      expect(saved.uploadEnabled, loaded.uploadEnabled);
      expect(saved.uploadS3Path, loaded.uploadS3Path);
      expect(saved.uploadS3SecretKey, loaded.uploadS3SecretKey);
      expect(saved.aiReviewEnabled, loaded.aiReviewEnabled);
      expect(saved.aiPreanalysisEnabled, loaded.aiPreanalysisEnabled);
      expect(saved.openrouterApiKey, loaded.openrouterApiKey);
    },
  );
}
