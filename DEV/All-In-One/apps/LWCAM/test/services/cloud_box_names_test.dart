import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/cloud_box_names.dart';
import 'package:lwcam/services/device_registry.dart';

void main() {
  group('CloudBoxNames', () {
    tearDown(() => CloudBoxNames.instance.clear());

    test('namesFor is empty when never refreshed (sync off ⇒ local-only)', () {
      expect(CloudBoxNames.instance.namesFor('PRJ-1'), isEmpty);
      expect(CloudBoxNames.instance.namesFor(null), isEmpty);
    });

    test('update lowercases; lookup is per project', () {
      CloudBoxNames.instance.update('PRJ-1', {'BOX 9240', ' box 9241 '});
      expect(CloudBoxNames.instance.namesFor('PRJ-1'), contains('box 9240'));
      expect(CloudBoxNames.instance.namesFor('PRJ-1'), contains('box 9241'));
      expect(CloudBoxNames.instance.namesFor('PRJ-2'), isEmpty);
      expect(CloudBoxNames.instance.lastRefreshed, isNotNull);
    });

    test('a later update replaces the project set (deleted boxes drop out)', () {
      CloudBoxNames.instance.update('PRJ-1', {'A'});
      CloudBoxNames.instance.update('PRJ-1', {'B'});
      expect(CloudBoxNames.instance.namesFor('PRJ-1'), {'b'});
    });
  });

  group('DeviceRegistry.evaluate', () {
    test('no existing binding allows', () {
      expect(DeviceRegistry.evaluate(null, 'PH-CEB'), DeviceGate.allowed);
      expect(DeviceRegistry.evaluate('  ', 'PH-CEB'), DeviceGate.allowed);
    });

    test('same code (case-insensitive) allows', () {
      expect(DeviceRegistry.evaluate('ph-ceb', 'PH-CEB'), DeviceGate.allowed);
    });

    test('different code blocks', () {
      expect(DeviceRegistry.evaluate('PH-CEB', 'ZA-CPT'), DeviceGate.blocked);
    });
  });
}
