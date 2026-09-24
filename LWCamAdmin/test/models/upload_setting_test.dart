import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/node_config.dart';

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

  test('NodeConfig writes every upload field', () {
    final json = const NodeConfig(uploadEnabled: true).toJson();
    for (final key in keys) {
      expect(json.containsKey(key), isTrue, reason: '$key missing from toJson');
    }
  });
}
