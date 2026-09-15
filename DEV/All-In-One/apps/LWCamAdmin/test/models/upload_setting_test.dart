import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:lwcam_admin/models/node_config.dart';

/// The S3 settings cross the same unchecked boundary exportWorkerCount does
/// (see export_worker_setting_test.dart): Station Setup writes them by string
/// key and the QC engine reads them back by that string. A rename on either
/// side leaves a working-looking form whose values reach nothing.
void main() {
  const keys = [
    'uploadEnabled',
    'uploadS3Path',
    'uploadS3Region',
    'uploadS3AccessKey',
    'uploadS3SecretKey',
    'uploadDoneRoot',
    'uploadSummaryRoot',
  ];

  test('the QC engine maps every upload key Station Setup writes', () {
    final mapping = File(
      '../LWCam_QC_Platform/backend/app/core/node_config.py',
    );
    if (!mapping.existsSync()) {
      markTestSkipped('QC backend not present at ${mapping.path}');
      return;
    }
    final source = mapping.readAsStringSync();
    for (final key in keys) {
      expect(source, contains('"$key":'), reason: '$key is not mapped');
    }
  });

  test('the config writes every upload key', () {
    final json = const NodeConfig(uploadEnabled: true).toJson();
    for (final key in keys) {
      expect(json.containsKey(key), isTrue, reason: '$key missing from toJson');
    }
  });

  group('uploadConfigProblem mirrors the engine', () {
    const ok = NodeConfig(
      uploadEnabled: true,
      uploadS3Path: 's3://bucket/exports',
      uploadS3AccessKey: 'AKIA',
      uploadS3SecretKey: 'shh',
      qcOutputRoot: r'D:\LWCam Capture\3.Export',
      uploadDoneRoot: r'D:\LWCam Capture\4.Uploaded',
      uploadSummaryRoot: r'D:\Upload Reports',
    );

    test('a complete config has no problem', () {
      expect(StationSetupController.uploadConfigProblem(ok), isNull);
    });

    test('off is never a problem, whatever else is blank', () {
      expect(
        StationSetupController.uploadConfigProblem(
          const NodeConfig(uploadEnabled: false),
        ),
        isNull,
      );
    });

    test('the path must be an s3:// URI', () {
      expect(
        StationSetupController.uploadConfigProblem(
          ok.copyWith(uploadS3Path: 'https://bucket.s3.amazonaws.com'),
        ),
        contains('s3://'),
      );
      expect(
        StationSetupController.uploadConfigProblem(
          ok.copyWith(uploadS3Path: 's3://'),
        ),
        contains('s3://'),
      );
    });

    test('the Uploaded folder is required and must be outside the output', () {
      expect(
        StationSetupController.uploadConfigProblem(
          ok.copyWith(uploadDoneRoot: ''),
        ),
        contains('Uploaded folder'),
      );
      for (final inside in [
        r'D:\LWCam Capture\3.Export',
        r'd:\lwcam capture\3.export\',
        r'D:\LWCam Capture\3.Export\Uploaded',
        r'D:/LWCam Capture/3.Export/Uploaded',
      ]) {
        expect(
          StationSetupController.uploadConfigProblem(
            ok.copyWith(uploadDoneRoot: inside),
          ),
          contains('outside the QC output folder'),
          reason: inside,
        );
      }
      // A sibling that merely shares the prefix is fine.
      expect(
        StationSetupController.uploadConfigProblem(
          ok.copyWith(uploadDoneRoot: r'D:\LWCam Capture\3.Export-done'),
        ),
        isNull,
      );
    });

    test('the Upload Summary folder is required', () {
      expect(
        StationSetupController.uploadConfigProblem(
          ok.copyWith(uploadSummaryRoot: ' '),
        ),
        contains('Upload Summary folder'),
      );
    });

    test('both keys are required', () {
      // copyWith cannot null a field, so build the short ones directly.
      expect(
        StationSetupController.uploadConfigProblem(
          const NodeConfig(
            uploadEnabled: true,
            uploadS3Path: 's3://bucket',
            uploadS3AccessKey: 'AKIA',
            uploadDoneRoot: r'D:\up',
            uploadSummaryRoot: r'D:\reports',
          ),
        ),
        contains('secret key'),
      );
      expect(
        StationSetupController.uploadConfigProblem(
          const NodeConfig(
            uploadEnabled: true,
            uploadS3Path: 's3://bucket',
            uploadS3SecretKey: 'shh',
            uploadDoneRoot: r'D:\up',
            uploadSummaryRoot: r'D:\reports',
          ),
        ),
        contains('access key'),
      );
    });
  });
}
