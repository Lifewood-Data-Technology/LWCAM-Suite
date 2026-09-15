// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/node_config.dart';
import 'admin_bootstrap.dart';

/// Writes LWIP's `deskew_crop_config.json`.
///
/// This moved here from LWCAM (`lwip_service.dart::writeGeneratedConfig`) when
/// LWIP became a background service that starts on boot: LWCAM generated the file
/// immediately before spawning python, which is safe only while LWCAM is the thing
/// that starts it. A service starts before any app has run, so the config has to
/// exist beforehand — and Station Setup, which owns every path in it, is the right
/// place to produce it.
///
/// The file LWCAM ships at `LWIP\config\deskew_crop_config.json` is a DIFFERENT
/// file: the manual/standalone config used by `START_DESKEW_CROP.bat`. It is not
/// touched here and never was.
///
/// Paths are absolute on purpose — LWIP resolves relative paths against its own
/// install root, which is not where any of this lives.

/// Marker LWCAM drops into a destination folder once every image of that folder has
/// transferred and verified. LWIP ignores a folder until it appears.
///
/// Duplicated from LWCAM's `processing_marker_service.dart` because the two apps are
/// separate Dart packages with no shared library, by the same convention that keeps
/// `lib/theme/` duplicated. Change one, change the other.
const String kProcessingMarkerName = 'lwcam_capture_marker.json';

/// Root of the generated LWIP runtime: `%USERPROFILE%\LWCAM_DBs\lwip`.
///
/// LWCAM's `LwipService.generatedStateFilePath()` derives `state.json` from this
/// same location, and its ProcessingReportService polls it. Move this and image
/// processing keeps running but stops being REPORTED, which is a silent failure.
String lwipRuntimeDir() => p.join(defaultLwcamDbsDir(), 'lwip');

String lwipConfigPath() => p.join(lwipRuntimeDir(), 'deskew_crop_config.json');

/// The processing input actually in effect: the explicit root, else the capture
/// destination (the common same-PC case).
String? effectiveProcessingInput(NodeConfig config) {
  final explicit = config.processingInputRoot?.trim() ?? '';
  if (explicit.isNotEmpty) return explicit;
  final destination = config.destinationPath?.trim() ?? '';
  return destination.isEmpty ? null : destination;
}

String effectiveProcessingOutput(NodeConfig config, String input) {
  final explicit = config.processingOutputRoot?.trim() ?? '';
  return explicit.isEmpty ? '${input}_processed' : explicit;
}

/// Builds the config map. Pure, so the golden test can assert the exact shape
/// without touching the filesystem.
Map<String, Object?> buildLwipConfig(
  NodeConfig config, {
  required String input,
  required String output,
  required String runtimeDir,
}) {
  final runtime = p.join(runtimeDir, 'runtime');
  return <String, Object?>{
    'input_root': input,
    'output_root': output,
    'work_root': p.join(runtime, 'work'),
    'state_file': p.join(runtime, 'state.json'),
    'log_file': p.join(runtime, 'deskew_crop.log'),
    'workers': config.processingWorkers,
    'poll_interval_seconds': 5,
    'stable_seconds': 60,
    'minimum_file_age_seconds': 30,
    // Belt-and-braces: the bundled LWIP no longer has an idle audit at all (it
    // deep-verifies each output once at publish, then RELEASES the folder to QC —
    // which edits those files in place, and whose edits the old audit silently
    // reverted). These ~10-year intervals only matter if this config is ever read
    // by an OLDER LWIP build that still audits, so keep them.
    'presence_check_interval_seconds': 315360000,
    'checksum_check_interval_seconds': 315360000,
    // Readiness is the per-folder marker, not the timers.
    'completion_marker': kProcessingMarkerName,
    'recursive': true,
    // No '.bmp': image_ops.py's _write_image_atomic has no BMP branch, so a
    // single .bmp in a watched folder raised "Unsupported output format",
    // failing that folder forever (retried every poll, never published).
    // LWCAM never produces BMP on any path, so the fix is to stop watching it.
    'extensions': ['.jpg', '.jpeg', '.png', '.tif', '.tiff'],
    // Station Setup owns this; nothing downstream carries its own copy.
    'crop_padding': config.processingCropPadding,
    // LWIP reports finished folders to PostgreSQL itself when this is on, so a
    // batch reaches QC even with LWCAM closed. It reads the credentials from the
    // node config the launcher points it at - this key only decides whether it
    // tries. LWIP's own default is false, so a standalone run never does.
    'cloud_report': config.processingCloudReport,
    // 100, not the q90 this used to write. At 100 with 4:4:4 chroma libjpeg
    // emits quantization tables of all 1s — the same tables the capture phone
    // writes — so the processed page cannot be called more compressed than the
    // original. q90's tables (maxima 24 and 20) were visibly coarser, and that
    // is what FamilySearch rejected the Taiping delivery over: "evidence of
    // image enhancement ... any compression". Measured max error against the
    // capture fell from 21 DN to 3. Files are roughly 4x larger.
    'jpeg_quality': 100,
    // Below this a page is straight enough that rotating it costs more than it
    // fixes — every rotation resamples every pixel. LWIP's old 0.01 threshold
    // meant deskew fired on almost every handheld capture.
    'deskew_min_degrees': 0.5,
    // Watch <dest>/YYYYMMDD/<folder>; mirror and generate 512px JPEG thumbs.
    'folder_depth': 2,
    'thumbnail_width': 512,
    'thumbnail_quality': 85,
    'thumbnail_dirname': 'thumbs',
  };
}

/// Validation shared with the writer, so Station Setup can reject a bad pair before
/// saving rather than leaving a crash-looping python watcher on the capture PC.
/// Returns null when the pair is usable, else the reason.
String? lwipConfigProblem(NodeConfig config) {
  final input = effectiveProcessingInput(config);
  if (input == null) {
    return 'Set the image destination folder (or an explicit processing input) '
        'before enabling image processing.';
  }
  final output = effectiveProcessingOutput(config, input);
  if (p.equals(input, output) || p.isWithin(input, output)) {
    return 'The processing output folder must not be the same as, or inside, '
        'the input folder.';
  }
  // Same rule python enforces (`crop_padding cannot be negative`). Catching it
  // here means a bad value is rejected at the point someone typed it, instead
  // of leaving a crash-looping watcher on the capture PC.
  if (config.processingCropPadding < 0) {
    return 'Crop padding cannot be negative.';
  }
  // Same range python enforces for `workers`: 0 = auto, otherwise 1..61
  // (Windows ProcessPool cap).
  if (config.processingWorkers < 0 || config.processingWorkers > 61) {
    return 'Processing workers must be 0 (auto) or between 1 and 61.';
  }
  return null;
}

/// Writes the config for [config], or returns null when processing is off or the
/// paths are unusable. tmp-file + rename, so a crash mid-write cannot leave a torn
/// file that python would fail to parse on its next start.
Future<File?> writeLwipConfig(NodeConfig config) async {
  if (!config.processingEnabled) return null;
  if (lwipConfigProblem(config) != null) return null;

  final input = effectiveProcessingInput(config)!;
  final output = effectiveProcessingOutput(config, input);
  final runtimeDir = lwipRuntimeDir();
  final json = buildLwipConfig(
    config,
    input: input,
    output: output,
    runtimeDir: runtimeDir,
  );

  final file = File(lwipConfigPath());
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(
    const JsonEncoder.withIndent('  ').convert(json),
    flush: true,
  );
  if (await file.exists()) await file.delete();
  await tmp.rename(file.path);
  print('🖼️ Wrote LWIP config: ${file.path}');
  return file;
}
