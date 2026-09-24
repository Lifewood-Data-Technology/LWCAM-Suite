import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/node_config.dart';

/// The AI switches carry three states, not two: on, off, and never configured.
///
/// The QC engine skips a null override and keeps whatever it is already set to,
/// but a written `false` overrides it. So collapsing "unset" to false is not a
/// cosmetic sloppiness - it is how a first Save on a fresh station silently
/// turns off an AI review that was working.
Map<String, Object?> base() => {
      'pgHost': 'localhost',
      'pgPort': 5432,
      'pgDatabase': 'testlwcam',
      'pgUser': 'someone',
      'pgPassword': 'secret',
      'qcJwtSecret': 'x' * 43,
      'qcInputRoot': r'C:\ProgramData\LWCAM',
      'qcOutputRoot': r'C:\out',
    };

void main() {
  group('a station where nobody has touched the AI switches', () {
    test('reads as unset, not as off', () {
      final config = NodeConfig.fromJson(base());
      expect(config.aiReviewEnabled, isNull);
      expect(config.aiPreanalysisEnabled, isNull);
    });

    test('writes null, so the engine keeps its own setting', () {
      // This is the whole fix: before, this wrote false and overrode the engine.
      final saved = NodeConfig.fromJson(base()).toJson();
      expect(saved['aiReviewEnabled'], isNull);
      expect(saved['aiPreanalysisEnabled'], isNull);
    });
  });

  group('a station that has been configured', () {
    test('a deliberate off is preserved, not mistaken for unset', () {
      // Someone turned it off on purpose; that must keep overriding the engine.
      final json = base()
        ..['aiReviewEnabled'] = false
        ..['aiPreanalysisEnabled'] = false;
      final config = NodeConfig.fromJson(json);
      expect(config.aiReviewEnabled, isFalse);
      expect(config.toJson()['aiReviewEnabled'], isFalse);
      expect(config.toJson()['aiPreanalysisEnabled'], isFalse);
    });

    test('on is preserved', () {
      final json = base()
        ..['aiReviewEnabled'] = true
        ..['aiPreanalysisEnabled'] = true;
      final config = NodeConfig.fromJson(json);
      expect(config.aiReviewEnabled, isTrue);
      expect(config.toJson()['aiReviewEnabled'], isTrue);
    });

    test('all three states survive a load/save round trip', () {
      for (final state in <bool?>[null, true, false]) {
        final json = base();
        if (state != null) json['aiReviewEnabled'] = state;
        final out = NodeConfig.fromJson(json).toJson();
        expect(out['aiReviewEnabled'], state,
            reason: 'state $state did not survive the round trip');
      }
    });

    test('the master switch and the scanner are independent', () {
      // Turning the scanner off must not read as the master switch being unset.
      final json = base()
        ..['aiReviewEnabled'] = true
        ..['aiPreanalysisEnabled'] = false;
      final config = NodeConfig.fromJson(json);
      expect(config.aiReviewEnabled, isTrue);
      expect(config.aiPreanalysisEnabled, isFalse);
    });
  });
}
