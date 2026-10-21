import 'color_cal_service.dart';

/// Capture-entry calibration check (WP-D7). Pure, unit-testable — mirrors
/// `device_registry.dart`'s `DeviceRegistry.evaluate`: the async
/// registration/dialog plumbing lives at the call site
/// (`AuthController.enterCaptureWithProject`), this just decides the verdict.
enum CalibrationGate {
  /// Color calibration is off for this station — nothing to check.
  notApplicable,

  /// Calibration is on and today's profile is active — proceed silently.
  calibratedToday,

  /// Calibration is on but no profile was calibrated today (none active, or
  /// the active one is from an earlier day) — the gate dialog should show.
  stale,
}

CalibrationGate evaluateCalibrationGate({
  required bool enabled,
  required ActiveProfile? active,
  DateTime? now,
}) {
  if (!enabled) return CalibrationGate.notApplicable;
  return ColorCalService.isCalibratedToday(active, now: now)
      ? CalibrationGate.calibratedToday
      : CalibrationGate.stale;
}
