import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Lifewood brand themes (light + dark).
///
/// ColorSchemes are explicit literals, NOT ColorScheme.fromSeed — seeding
/// drifts the brand hues (Castleton Green / Paper / Saffron) toward Material
/// tonal palettes. Every value here was contrast-checked; see the notes in
/// app_colors.dart before repurposing Saffron/Earth Yellow as text colors.
///
/// NOTE: lib/theme/ is a byte-identical mirror between LWCAM and LWRework —
/// change one, copy to the other (see CHANGELOG convention).
abstract final class AppTheme {
  // "Core UI colors" (v3, 2026-09-04): Sea Salt canvas, white panels, Dark
  // Serpent text, green-grey hairlines (#DDE5E0) and secondary text (#64736C).
  // Castleton Green = action / selected / focus; Paper = hover, AI and
  // secondary-button ground; Saffron = AI / attention accents only.
  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.castletonGreen,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFD9EFE3),
    onPrimaryContainer: Color(0xFF0A3B29),
    // Field-label green-grey; also the "Edited" pill ground.
    secondary: Color(0xFF53635B),
    onSecondary: Colors.white,
    // Paper + Dark Serpent: tonal buttons (Save Draft) and the AI button
    // ground. Saffron stays on the icon, never the whole button.
    secondaryContainer: AppColors.paper,
    onSecondaryContainer: AppColors.darkSerpent,
    tertiary: AppColors.saffron,
    onTertiary: Color(0xFF422D05),
    tertiaryContainer: AppColors.paper,
    onTertiaryContainer: AppColors.darkSerpent,
    // Semantic red (Rework). 4.8:1 on white as text, so it doubles as a fill.
    error: Color(0xFFD92D2D),
    onError: Colors.white,
    errorContainer: Color(0xFFFBE2DC),
    onErrorContainer: Color(0xFF6A1F14),
    surface: Colors.white,
    onSurface: AppColors.darkSerpent,
    onSurfaceVariant: Color(0xFF64736C),
    surfaceContainerLowest: Colors.white,
    // Sea Salt: read-only / system-derived fields and quiet chips.
    surfaceContainerLow: AppColors.seaSalt,
    surfaceContainer: Color(0xFFECEDEC),
    surfaceContainerHigh: Color(0xFFE6E7E6),
    surfaceContainerHighest: Color(0xFFE0E2E1),
    // Muted icon / disabled control grey; hairlines one step lighter.
    outline: Color(0xFF8A9891),
    outlineVariant: Color(0xFFDDE5E0),
    inverseSurface: Color(0xFF2C2F2E),
    onInverseSurface: Color(0xFFF1F2F1),
    inversePrimary: Color(0xFF6FCFA4),
    shadow: Colors.black,
    scrim: Colors.black,
  );

  // Dark mode is graphite/near-black, NOT forest green (v2 user feedback):
  // neutral surfaces with only a whisper of green; brand green appears only
  // as the brightened-Castleton accent.
  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF43C08C),
    onPrimary: Color(0xFF00311E),
    primaryContainer: Color(0xFF0E4A33),
    onPrimaryContainer: Color(0xFFB9ECD3),
    secondary: Color(0xFFA5B5AC),
    onSecondary: Color(0xFF1B2420),
    secondaryContainer: Color(0xFF333B37),
    onSecondaryContainer: Color(0xFFDCE6E0),
    tertiary: AppColors.saffron,
    onTertiary: Color(0xFF402A00),
    tertiaryContainer: Color(0xFF4E3A14),
    onTertiaryContainer: Color(0xFFFFDFB0),
    error: Color(0xFFE5735A),
    onError: Color(0xFF3E0E04),
    errorContainer: Color(0xFF6E2A1C),
    onErrorContainer: Color(0xFFFFDAD2),
    surface: Color(0xFF1B1D1C),
    onSurface: Color(0xFFE3E5E4),
    onSurfaceVariant: Color(0xFFA6ACA9),
    surfaceContainerLowest: Color(0xFF0E100F),
    surfaceContainerLow: Color(0xFF202322),
    surfaceContainer: Color(0xFF242726),
    surfaceContainerHigh: Color(0xFF292C2B),
    surfaceContainerHighest: Color(0xFF2F3231),
    outline: Color(0xFF575E5B),
    outlineVariant: Color(0xFF363A38),
    inverseSurface: Color(0xFFE3E5E4),
    onInverseSurface: Color(0xFF1B1D1C),
    inversePrimary: AppColors.castletonGreen,
    shadow: Colors.black,
    scrim: Colors.black,
  );

  /// Startup window background per mode (windowManager WindowOptions needs a
  /// color before the first Flutter frame; must stay OPAQUE — a transparent
  /// window forces the slow layered-window composition path on Windows).
  static const lightWindowBackground = AppColors.seaSalt;
  static const darkWindowBackground = Color(0xFF131514);

  /// Light-mode field border, state-resolved (Core UI colors): soft green-grey
  /// at rest, Castleton Green on hover, Castleton Green 2px when focused. The
  /// fill is white at rest and Paper when focused (see [_lightFieldFill]), so
  /// editable / focused / read-only fields scan as three distinct grounds.
  static InputBorder _lightFieldBorder(Set<WidgetState> states) {
    final radius = BorderRadius.circular(8);
    if (states.contains(WidgetState.disabled)) {
      return OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: _lightScheme.outlineVariant),
      );
    }
    if (states.contains(WidgetState.error)) {
      return OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(
          color: _lightScheme.error,
          width: states.contains(WidgetState.focused) ? 2 : 1,
        ),
      );
    }
    if (states.contains(WidgetState.focused)) {
      return OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: AppColors.castletonGreen, width: 2),
      );
    }
    if (states.contains(WidgetState.hovered)) {
      return OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(
          color: AppColors.castletonGreen,
          width: 1.5,
        ),
      );
    }
    return OutlineInputBorder(
      borderRadius: radius,
      borderSide: const BorderSide(color: Color(0xFFC8D3CE)),
    );
  }

  /// Editable = white, focused = Paper tint, disabled/read-only = Sea Salt.
  static Color _lightFieldFill(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) return AppColors.seaSalt;
    if (states.contains(WidgetState.focused)) return AppColors.paper;
    return Colors.white;
  }

  static ThemeData get light => _build(
    scheme: _lightScheme,
    scaffoldBackground: AppColors.seaSalt,
    lifewood: LifewoodColors.light,
    // Brand statement: Dark Serpent bar with Paper-cream title/icons on
    // every screen (also what fixed the old white-title-on-light-surface
    // contrast bug at the root).
    appBarBackground: AppColors.darkSerpent,
    appBarForeground: AppColors.paper,
    inputTheme: InputDecorationTheme(
      filled: true,
      fillColor: WidgetStateColor.resolveWith(_lightFieldFill),
      // Border (not fill) signals hover; focus is what tints the fill.
      hoverColor: Colors.transparent,
      labelStyle: TextStyle(color: _lightScheme.secondary),
      hintStyle: TextStyle(color: _lightScheme.onSurfaceVariant),
      border: WidgetStateInputBorder.resolveWith(_lightFieldBorder),
    ),
    // No legacy focus overlay: a grey box lingering after a click on a
    // ListTile row reads as a stuck highlight. Hover IS wanted, and it is
    // Material's own default grey (4% black) — the sheet's Paper read as a
    // status, and Sea Salt vanished on the canvas; the operator asked for
    // the grey back. Left null so ThemeData supplies it.
    legacyFocusHighlight: Colors.transparent,
  );

  static ThemeData get dark => _build(
    scheme: _darkScheme,
    scaffoldBackground: darkWindowBackground,
    lifewood: LifewoodColors.dark,
    appBarBackground: _darkScheme.surfaceContainer,
    appBarForeground: _darkScheme.onSurface,
    inputTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF212724),
      labelStyle: TextStyle(color: _darkScheme.onSurfaceVariant),
      hintStyle: TextStyle(color: _darkScheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _darkScheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _darkScheme.outline),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _darkScheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: _darkScheme.primary, width: 2),
      ),
    ),
  );

  static ThemeData _build({
    required ColorScheme scheme,
    required Color scaffoldBackground,
    required LifewoodColors lifewood,
    required Color appBarBackground,
    required Color appBarForeground,
    required InputDecorationTheme inputTheme,
    Color? legacyFocusHighlight,
    Color? legacyHoverHighlight,
  }) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBackground,
      // Legacy-widget focus/hover overlays (ListTile, InkWell, DropdownButton).
      // Light mode passes transparent focus (no grey box lingering after a
      // click) and leaves hover at Material's default grey.
      focusColor: legacyFocusHighlight,
      hoverColor: legacyHoverHighlight,
      fontFamily: 'Manrope',
      extensions: [lifewood],
      appBarTheme: AppBarTheme(
        elevation: 0,
        centerTitle: false,
        backgroundColor: appBarBackground,
        foregroundColor: appBarForeground,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: appBarForeground,
          letterSpacing: 0.15,
          fontFamily: 'Manrope',
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.0,
        ),
        displayMedium: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.0,
        ),
        displaySmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.0,
        ),
        headlineMedium: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.15,
        ),
        headlineSmall: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.0,
        ),
        titleLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.15,
        ),
        titleMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
        titleSmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.5,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.25,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          letterSpacing: 0.4,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.1,
        ),
      ),
      cardTheme: CardThemeData(
        // Flat panel look (v2): hairline-bordered white/graphite panels on
        // the neutral canvas instead of drop shadows.
        elevation: 0,
        // Kill M3 elevation tinting — it muddies the neutral surfaces with
        // the primary hue.
        surfaceTintColor: Colors.transparent,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      inputDecorationTheme: inputTheme,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outline),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary),
      ),
      // The selected segment is a highlight, not a button: the pre-v3
      // green-grey (#E2EAE5, the old secondaryContainer) in light, one step
      // up from the panel in dark. Tonal FilledButtons keep secondaryContainer
      // (Paper) — the operator wanted only the highlight back, not the buttons.
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? (scheme.brightness == Brightness.light
                      ? const Color(0xFFE2EAE5)
                      : scheme.surfaceContainerLow)
                : null,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? scheme.onSurface : null,
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        selectedColor: scheme.tertiaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(color: scheme.onInverseSurface),
        actionTextColor: scheme.inversePrimary,
        behavior: SnackBarBehavior.floating,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.tertiary,
        foregroundColor: scheme.onTertiary,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        selectedTileColor: scheme.primaryContainer,
        selectedColor: scheme.onPrimaryContainer,
        // Matches the card radius so hover/focus ink follows the rounded
        // corners instead of painting a square box over them.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outline,
        ),
      ),
    );
  }
}

/// The height a scope bar holds every one of its controls to.
///
/// Material's segmented button is 40 by default and VisualDensity.compact —
/// what adaptivePlatformDensity resolves to on Windows — takes 8 off it.
/// Nothing applies that density to an input field, so a search box beside one
/// has to be told. Asserted against the real segmented button in
/// test/pages/scope_bar_height_test.dart, which is the half of this that could
/// drift.
///
/// Lived in `qc_home_page.dart` until the QC screens left this app (Phase 8,
/// 2026-09-22); it is kept because what the test pins is a Material premise,
/// not anything QC owned.
const double scopeBarControlHeight = 32;
