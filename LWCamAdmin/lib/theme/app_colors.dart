// Lifewood brand colour constants and the semantic colour slots (success,
// warning, info and similar) that Material's ColorScheme does not carry.
// Used by app_theme.dart; widgets read the slots through the theme extension
// rather than hard-coding colours. This theme folder is copied between apps.

import 'package:flutter/material.dart';

/// Raw Lifewood brand palette (official Color Palette sheet).
///
/// NOTE: lib/theme/ is a byte-identical mirror between LWCAM and LWRework —
/// change one, copy to the other (see CHANGELOG convention).
abstract final class AppColors {
  static const paper = Color(0xFFF5EEDB);
  static const seaSalt = Color(0xFFF9F7F7);
  static const castletonGreen = Color(0xFF046241);
  static const darkSerpent = Color(0xFF133020);
  static const saffron = Color(0xFFFBB347);
  static const earthYellow = Color(0xFFFFC370);
}

/// Semantic color slots that Material's ColorScheme doesn't carry:
/// status colors (success/warning/info) plus the capture-grid
/// selected/viewing states and the gallery gradient-icon pair.
///
/// Contrast rules baked into these values:
///  - Saffron/Earth Yellow are FILL-ONLY on light surfaces (1.9:1 as text);
///    text on them uses the on* slot (Dark Serpent family, 7.7:1).
///  - Light-mode warning text is #B4690E (4.6:1 on white), never raw Saffron.
class LifewoodColors extends ThemeExtension<LifewoodColors> {
  const LifewoodColors({
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.onWarning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.info,
    required this.onInfo,
    required this.infoContainer,
    required this.onInfoContainer,
    required this.selected,
    required this.selectedContainer,
    required this.viewing,
    required this.viewingContainer,
    required this.accentGradientStart,
    required this.accentGradientEnd,
  });

  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color onWarning;
  final Color warningContainer;
  final Color onWarningContainer;
  final Color info;
  final Color onInfo;
  final Color infoContainer;
  final Color onInfoContainer;

  /// Grid tile "selected for transfer" state (was lightBlueAccent).
  final Color selected;
  final Color selectedContainer;

  /// Grid tile "currently viewing" state (was indigo).
  final Color viewing;
  final Color viewingContainer;

  /// Gradient icon accent pair (was lightBlueAccent -> blueAccent).
  final Color accentGradientStart;
  final Color accentGradientEnd;

  static LifewoodColors of(BuildContext context) =>
      Theme.of(context).extension<LifewoodColors>()!;

  static const light = LifewoodColors(
    success: Color(0xFF257A48),
    onSuccess: Colors.white,
    successContainer: Color(0xFFDCF1E3),
    onSuccessContainer: Color(0xFF0C3A20),
    warning: Color(0xFFB4690E),
    onWarning: Colors.white,
    warningContainer: Color(0xFFFDE9CC),
    onWarningContainer: Color(0xFF5C3A00),
    info: Color(0xFF2A7F8E),
    onInfo: Colors.white,
    infoContainer: Color(0xFFDDEEF1),
    onInfoContainer: Color(0xFF123E46),
    selected: AppColors.saffron,
    selectedContainer: Color(0x2EFBB347),
    viewing: Color(0xFF2A7F8E),
    viewingContainer: Color(0x142A7F8E),
    accentGradientStart: AppColors.saffron,
    accentGradientEnd: AppColors.castletonGreen,
  );

  // Containers lean graphite (v2): status colors read as accents on a
  // neutral near-black UI, not tints of a green theme.
  static const dark = LifewoodColors(
    success: Color(0xFF6FD198),
    onSuccess: Color(0xFF01321A),
    successContainer: Color(0xFF1F4630),
    onSuccessContainer: Color(0xFFC6EFD4),
    warning: AppColors.saffron,
    onWarning: Color(0xFF402A00),
    warningContainer: Color(0xFF53401B),
    onWarningContainer: Color(0xFFFFDFB0),
    info: Color(0xFF79C7D4),
    onInfo: Color(0xFF003741),
    infoContainer: Color(0xFF1E464E),
    onInfoContainer: Color(0xFFC9EAF0),
    selected: AppColors.saffron,
    selectedContainer: Color(0x33FBB347),
    viewing: Color(0xFF79C7D4),
    viewingContainer: Color(0x1F79C7D4),
    accentGradientStart: AppColors.earthYellow,
    accentGradientEnd: Color(0xFF43C08C),
  );

  @override
  LifewoodColors copyWith({
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? onWarning,
    Color? warningContainer,
    Color? onWarningContainer,
    Color? info,
    Color? onInfo,
    Color? infoContainer,
    Color? onInfoContainer,
    Color? selected,
    Color? selectedContainer,
    Color? viewing,
    Color? viewingContainer,
    Color? accentGradientStart,
    Color? accentGradientEnd,
  }) {
    return LifewoodColors(
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
      info: info ?? this.info,
      onInfo: onInfo ?? this.onInfo,
      infoContainer: infoContainer ?? this.infoContainer,
      onInfoContainer: onInfoContainer ?? this.onInfoContainer,
      selected: selected ?? this.selected,
      selectedContainer: selectedContainer ?? this.selectedContainer,
      viewing: viewing ?? this.viewing,
      viewingContainer: viewingContainer ?? this.viewingContainer,
      accentGradientStart: accentGradientStart ?? this.accentGradientStart,
      accentGradientEnd: accentGradientEnd ?? this.accentGradientEnd,
    );
  }

  @override
  LifewoodColors lerp(LifewoodColors? other, double t) {
    if (other is! LifewoodColors) return this;
    return LifewoodColors(
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
      info: Color.lerp(info, other.info, t)!,
      onInfo: Color.lerp(onInfo, other.onInfo, t)!,
      infoContainer: Color.lerp(infoContainer, other.infoContainer, t)!,
      onInfoContainer: Color.lerp(onInfoContainer, other.onInfoContainer, t)!,
      selected: Color.lerp(selected, other.selected, t)!,
      selectedContainer:
          Color.lerp(selectedContainer, other.selectedContainer, t)!,
      viewing: Color.lerp(viewing, other.viewing, t)!,
      viewingContainer:
          Color.lerp(viewingContainer, other.viewingContainer, t)!,
      accentGradientStart:
          Color.lerp(accentGradientStart, other.accentGradientStart, t)!,
      accentGradientEnd:
          Color.lerp(accentGradientEnd, other.accentGradientEnd, t)!,
    );
  }
}
