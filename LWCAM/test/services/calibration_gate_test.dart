import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/calibration_gate.dart';
import 'package:lwcam/services/color_cal_service.dart';

ActiveProfile _profile({required DateTime calibratedAt}) => ActiveProfile(
  profileId: 'p1',
  profilePath: r'C:\x\p1.json',
  calibratedAt: calibratedAt,
  calibratedAtRaw: calibratedAt.toIso8601String(),
  deviceId: 'SAX01',
  operator: 'jack',
  workingSpace: 'linear_srgb_d65',
  whiteBalance: const [1.0, 1.0, 1.0],
  correction: const {
    'type': 'matrix3x3',
    'matrix': [
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, 0.0, 1.0],
    ],
    'applied_after_white_balance': true,
  },
);

void main() {
  group('evaluateCalibrationGate', () {
    test('disabled station is notApplicable regardless of profile', () {
      expect(
        evaluateCalibrationGate(enabled: false, active: null),
        CalibrationGate.notApplicable,
      );
      expect(
        evaluateCalibrationGate(
          enabled: false,
          active: _profile(calibratedAt: DateTime.now()),
        ),
        CalibrationGate.notApplicable,
      );
    });

    test('enabled with no active profile is stale', () {
      expect(
        evaluateCalibrationGate(enabled: true, active: null),
        CalibrationGate.stale,
      );
    });

    test('enabled with a profile calibrated today is calibratedToday', () {
      final now = DateTime(2026, 9, 11, 10, 0);
      final active = _profile(calibratedAt: DateTime(2026, 9, 11, 8, 0));
      expect(
        evaluateCalibrationGate(enabled: true, active: active, now: now),
        CalibrationGate.calibratedToday,
      );
    });

    test('enabled with yesterday\'s profile is stale', () {
      final now = DateTime(2026, 9, 11, 10, 0);
      final active = _profile(calibratedAt: DateTime(2026, 9, 10, 23, 59));
      expect(
        evaluateCalibrationGate(enabled: true, active: active, now: now),
        CalibrationGate.stale,
      );
    });
  });
}
