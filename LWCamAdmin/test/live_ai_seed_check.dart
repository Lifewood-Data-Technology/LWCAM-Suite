// Throwaway check against the REAL node config on this machine. Not named
// *_test.dart so `flutter test` skips it.
//
// Proves the seed did what it was for: Admin now loads the AI settings that are
// actually in use, so a Save round-trips them instead of writing its own
// defaults over a working configuration.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/node_config.dart';

void main() {
  test('Admin round-trips the seeded AI settings without losing them', () {
    final path =
        '${Platform.environment['USERPROFILE']}\\LWCAM_DBs\\lwcam_node_config.json';
    final onDisk = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

    // What Admin shows when Station Setup opens.
    final loaded = NodeConfig.fromJson(onDisk);
    print('loaded from disk:');
    print('  aiReviewEnabled       = ${loaded.aiReviewEnabled}');
    print('  aiPreanalysisEnabled  = ${loaded.aiPreanalysisEnabled}');
    print('  apiKey present        = ${(loaded.openrouterApiKey ?? '').isNotEmpty}');
    print('  extractModel          = ${loaded.openrouterExtractModel}');
    print('  compareModel          = ${loaded.openrouterCompareModel}');

    // Before the seed these were false/null, which is the whole bug: a false
    // boolean IS written and DOES override the engine's .env.
    expect(loaded.aiReviewEnabled, isTrue);
    expect(loaded.aiPreanalysisEnabled, isTrue);
    expect(loaded.openrouterApiKey, isNotNull);
    expect(loaded.openrouterExtractModel, 'qwen/qwen3.6-35b-a3b');
    expect(loaded.openrouterCompareModel, 'qwen/qwen3.6-35b-a3b');

    // What a Save writes back out, untouched.
    final saved = loaded.toJson();
    for (final key in [
      'aiReviewEnabled',
      'aiPreanalysisEnabled',
      'openrouterApiKey',
      'openrouterExtractModel',
      'openrouterCompareModel',
    ]) {
      expect(saved[key], onDisk[key], reason: '$key changed across a round trip');
    }
    print('round trip preserved all five AI keys');
  });
}
