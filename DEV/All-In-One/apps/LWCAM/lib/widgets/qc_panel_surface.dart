import 'package:flutter/material.dart';

/// The ground the review screen's working panels sit on.
///
/// The thumbnail rail, the image toolbar and the metadata column are white
/// panels on the Sea Salt canvas (Core UI colors, 2026-09-04): they frame the
/// page being reviewed instead of blending into the scaffold. They were Paper
/// for one day; Paper now means hover / AI / secondary-button ground, and a
/// panel painted in the hover colour would leave hover with nothing to show.
///
/// Null in dark mode, and that is the point rather than an omission: a
/// BoxDecoration with a null colour is exactly what these Containers already
/// had, so dark mode is left untouched by construction instead of by a second
/// set of colours that would have to be kept in step.
Color? qcPanelSurface(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.light
      ? theme.colorScheme.surface
      : null;
}
