import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/device_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('offline with a cached binding: same project allowed', () async {
    await DeviceRegistry.rememberBinding('SAX01', 'PH-CEB');
    final r = await DeviceRegistry.offlineDecision('SAX01', 'ph-ceb');
    expect(r.gate, DeviceGate.allowed);
    expect(r.fromCache, isTrue);
  });

  test('offline with a cached binding: a different project is blocked, with '
      'the bound code for the message', () async {
    await DeviceRegistry.rememberBinding('SAX01', 'PH-CEB');
    final r = await DeviceRegistry.offlineDecision('SAX01', 'ZA-CPT');
    expect(r.gate, DeviceGate.blocked);
    expect(r.boundLocationCode, 'PH-CEB');
    expect(r.fromCache, isTrue);
  });

  test('offline and never bound: capture stays allowed (skipped)', () async {
    final r = await DeviceRegistry.offlineDecision('SAX01', 'ZA-CPT');
    expect(r.gate, DeviceGate.skipped);
  });

  test('the cache is per device', () async {
    await DeviceRegistry.rememberBinding('SAX01', 'PH-CEB');
    expect((await DeviceRegistry.offlineDecision('SAX02', 'ZA-CPT')).gate,
        DeviceGate.skipped);
  });
}
