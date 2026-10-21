import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/color_cal_service.dart';

ActiveProfile _profile({DateTime? calibratedAt, String? calibratedAtRaw}) =>
    ActiveProfile(
      profileId: 'p1',
      profilePath: r'C:\x\p1.json',
      calibratedAt: calibratedAt ?? DateTime.now(),
      calibratedAtRaw:
          calibratedAtRaw ?? (calibratedAt ?? DateTime.now()).toIso8601String(),
      deviceId: 'SAX01',
      operator: 'jack',
      workingSpace: 'linear_srgb_d65',
      whiteBalance: const [1.04, 1.0, 0.96],
      correction: const {
        'type': 'matrix3x3',
        'matrix': [
          [1.0, 0.0, 0.0],
          [0.0, 1.0, 0.0],
          [0.0, 0.0, 1.0],
        ],
        'applied_after_white_balance': true,
      },
      meanDe00: 1.23,
    );

void main() {
  group('ColorCalService.isCalibratedToday', () {
    test('same local calendar day is true', () {
      final now = DateTime(2026, 9, 11, 10, 0);
      final profile = _profile(calibratedAt: DateTime(2026, 9, 11, 8, 0));
      expect(ColorCalService.isCalibratedToday(profile, now: now), isTrue);
    });

    test('23:59 to 00:01 crosses midnight and is false', () {
      final profile = _profile(calibratedAt: DateTime(2026, 9, 10, 23, 59));
      final now = DateTime(2026, 9, 11, 0, 1);
      expect(ColorCalService.isCalibratedToday(profile, now: now), isFalse);
    });

    test('null profile is false', () {
      expect(ColorCalService.isCalibratedToday(null), isFalse);
    });

    test('an offset ISO timestamp is compared after conversion to local '
        'time, not by its UTC date', () {
      final calibratedAt = DateTime.parse('2026-09-11T23:30:00+08:00');
      final sameInstantLocal = calibratedAt.toLocal();
      expect(
        ColorCalService.isCalibratedToday(
          _profile(calibratedAt: calibratedAt),
          now: sameInstantLocal,
        ),
        isTrue,
      );
      final nextDaySameLocalTime = sameInstantLocal.add(
        const Duration(days: 1),
      );
      expect(
        ColorCalService.isCalibratedToday(
          _profile(calibratedAt: calibratedAt),
          now: nextDaySameLocalTime,
        ),
        isFalse,
      );
    });
  });

  group('ColorCalService.colorProfileStamp', () {
    test('null profile stamps null', () {
      expect(ColorCalService.colorProfileStamp(null), isNull);
    });

    test('carries exactly the marker-fragment key set', () {
      final stamp = ColorCalService.colorProfileStamp(
        _profile(calibratedAt: DateTime.now()),
      );
      expect(stamp, isNotNull);
      expect(stamp!.keys.toSet(), {
        'profile_id',
        'calibrated_at',
        'calibrated_today',
        'working_space',
        'white_balance',
        'correction',
      });
      expect(stamp['profile_id'], 'p1');
      expect(stamp['calibrated_today'], isTrue);
    });

    test("carries the profile's ORIGINAL calibrated_at string, not a "
        're-serialised (UTC Z) one', () {
      const raw = '2026-09-11T23:30:00+08:00';
      final stamp = ColorCalService.colorProfileStamp(
        _profile(calibratedAt: DateTime.parse(raw), calibratedAtRaw: raw),
      );
      expect(stamp!['calibrated_at'], raw);
    });
  });

  test(
    'legacy active profile cannot be activated in the directory workflow',
    () async {
      await expectLater(
        ColorCalService().setActive(_profile()),
        throwsStateError,
      );
    },
  );
}
