import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/auth/offline_temp_password.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('three offline sign-ins are allowed, the fourth is refused', () async {
    for (var i = 0; i < 3; i++) {
      expect(await OfflineTempPassword.tryConsume('Alice'), isTrue);
    }
    expect(await OfflineTempPassword.tryConsume('alice'), isFalse);
  });

  test('seven days after the first one it is refused, per user', () async {
    final t0 = DateTime(2026, 9, 1);
    expect(await OfflineTempPassword.tryConsume('bob', now: t0), isTrue);
    expect(
      await OfflineTempPassword.tryConsume('bob',
          now: t0.add(const Duration(days: 6, hours: 23))),
      isTrue,
    );
    expect(
      await OfflineTempPassword.tryConsume('bob',
          now: t0.add(const Duration(days: 7, hours: 1))),
      isFalse,
    );
    expect(await OfflineTempPassword.tryConsume('carol', now: t0), isTrue);
  });

  test('clear resets the allowance', () async {
    for (var i = 0; i < 3; i++) {
      await OfflineTempPassword.tryConsume('dan');
    }
    await OfflineTempPassword.clear('dan');
    expect(await OfflineTempPassword.tryConsume('dan'), isTrue);
  });
}
