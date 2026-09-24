import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/node_config.dart';
import 'package:lwcam_admin/services/lwip_config_writer.dart';

/// Byte-for-byte copy of a config LWCAM itself generated (2026-08-17) with
/// `lwip_service.dart::writeGeneratedConfig`, before that responsibility moved
/// here. Writing this file is now Station Setup's job, and LWIP reads the result
/// with no idea which app produced it — so any drift from this shape is a silent
/// behaviour change on every capture station.
///
/// The four values that differ from LWIP's own shipped defaults are the ones worth
/// guarding: folder_depth 2 (watch `<dest>/YYYYMMDD/<folder>`), the completion marker,
/// thumbnail_width 512 (QC needs thumbs), and the ~10-year audit intervals that keep
/// the old idle audit from reverting QC's in-place edits.
const String _golden = '''
{
  "input_root": "C:\\\\Users\\\\operator\\\\Desktop\\\\LWIP\\\\1.Images",
  "output_root": "C:\\\\Users\\\\operator\\\\Desktop\\\\LWIP\\\\2.Batches",
  "work_root": "C:\\\\Users\\\\operator\\\\LWCAM_DBs\\\\lwip\\\\runtime\\\\work",
  "state_file": "C:\\\\Users\\\\operator\\\\LWCAM_DBs\\\\lwip\\\\runtime\\\\state.json",
  "log_file": "C:\\\\Users\\\\operator\\\\LWCAM_DBs\\\\lwip\\\\runtime\\\\deskew_crop.log",
  "workers": 0,
  "poll_interval_seconds": 5,
  "stable_seconds": 60,
  "minimum_file_age_seconds": 30,
  "presence_check_interval_seconds": 315360000,
  "checksum_check_interval_seconds": 315360000,
  "completion_marker": "lwcam_capture_marker.json",
  "recursive": true,
  "extensions": [
    ".jpg",
    ".jpeg",
    ".png",
    ".tif",
    ".tiff"
  ],
  "crop_padding": 200,
  "cloud_report": true,
  "jpeg_quality": 100,
  "deskew_min_degrees": 0.5,
  "folder_depth": 2,
  "thumbnail_width": 512,
  "thumbnail_quality": 85,
  "thumbnail_dirname": "thumbs"
}''';

void main() {
  test('generated config still matches what LWCAM used to write', () {
    const config = NodeConfig(
      processingEnabled: true,
      processingWorkers: 0,
      destinationPath: r'C:\Users\operator\Desktop\LWIP\1.Images',
      processingInputRoot: r'C:\Users\operator\Desktop\LWIP\1.Images',
      processingOutputRoot: r'C:\Users\operator\Desktop\LWIP\2.Batches',
    );

    final json = buildLwipConfig(
      config,
      input: r'C:\Users\operator\Desktop\LWIP\1.Images',
      output: r'C:\Users\operator\Desktop\LWIP\2.Batches',
      runtimeDir: r'C:\Users\operator\LWCAM_DBs\lwip',
    );

    expect(const JsonEncoder.withIndent('  ').convert(json), _golden);
  });

  test('crop padding comes from Station Setup, not a hardcoded literal', () {
    // The whole point of the field: change it in Station Setup and every
    // consumer follows, because they all read the generated config.
    const config = NodeConfig(
      processingEnabled: true,
      processingInputRoot: r'D:\Capture.Images',
      processingOutputRoot: r'D:\Capture.Batches',
      processingCropPadding: 75,
    );
    final json = buildLwipConfig(
      config,
      input: r'D:\Capture.Images',
      output: r'D:\Capture.Batches',
      runtimeDir: r'C:\LWCAM_DBs\lwip',
    );
    expect(json['crop_padding'], 75);

    // 0 is meaningful (crop tight to the detected edge) and must survive rather
    // than being treated as "unset" and replaced by the default.
    final tight = buildLwipConfig(
      config.copyWith(processingCropPadding: 0),
      input: r'D:\Capture.Images',
      output: r'D:\Capture.Batches',
      runtimeDir: r'C:\LWCAM_DBs\lwip',
    );
    expect(tight['crop_padding'], 0);
  });

  test('cloud reporting follows Station Setup, and defaults on', () {
    // The station most at risk is the one nobody revisits to configure, so the
    // default has to be on. LWIP's OWN default is off (a standalone run must
    // never reach for a database) - this key is how a managed station differs.
    const on = NodeConfig(
      processingEnabled: true,
      processingInputRoot: r'D:\Capture\1.Images',
      processingOutputRoot: r'D:\Capture\2.Batches',
    );
    expect(on.processingCloudReport, isTrue);
    expect(
      buildLwipConfig(on,
          input: r'D:\Capture\1.Images',
          output: r'D:\Capture\2.Batches',
          runtimeDir: r'C:\LWCAM_DBs\lwip')['cloud_report'],
      isTrue,
    );

    expect(
      buildLwipConfig(on.copyWith(processingCloudReport: false),
          input: r'D:\Capture\1.Images',
          output: r'D:\Capture\2.Batches',
          runtimeDir: r'C:\LWCAM_DBs\lwip')['cloud_report'],
      isFalse,
    );
  });

  test('cloud reporting survives a NodeConfig JSON round-trip', () {
    // Both apps read this file and LWCAM can rewrite it; a key its model did not
    // know would be dropped on that write, silently turning reporting off.
    const config = NodeConfig(processingCloudReport: false);
    expect(
      NodeConfig.fromJson(jsonDecode(jsonEncode(config.toJson()))
              as Map<String, dynamic>)
          .processingCloudReport,
      isFalse,
    );
  });

  test('a negative crop padding is rejected before it reaches python', () {
    // python raises `crop_padding cannot be negative` at load, which would
    // leave a crash-looping watcher instead of a message in Station Setup.
    const bad = NodeConfig(
      processingEnabled: true,
      processingInputRoot: r'D:\Capture.Images',
      processingOutputRoot: r'D:\Capture.Batches',
      processingCropPadding: -1,
    );
    expect(lwipConfigProblem(bad), isNotNull);
  });

  test('crop padding survives a NodeConfig JSON round-trip', () {
    // Both apps read this file and LWCAM can rewrite it, so a key its model did
    // not know about would be silently dropped and the padding would revert.
    const config = NodeConfig(processingCropPadding: 123);
    expect(
      NodeConfig.fromJson(jsonDecode(jsonEncode(config.toJson()))
              as Map<String, dynamic>)
          .processingCropPadding,
      123,
    );
  });

  test('processing input falls back to the capture destination', () {
    const config = NodeConfig(
      processingEnabled: true,
      destinationPath: r'D:\Capture\1.Images',
    );
    expect(effectiveProcessingInput(config), r'D:\Capture\1.Images');
    expect(
      effectiveProcessingOutput(config, r'D:\Capture\1.Images'),
      r'D:\Capture\1.Images_processed',
    );
  });

  test('explicit input/output roots (split-PC, UNC) are honored verbatim', () {
    // A capture PC writing to a NAS while processing runs elsewhere: the explicit
    // roots must survive untouched, including the UNC prefix.
    const config = NodeConfig(
      processingEnabled: true,
      destinationPath: r'D:\CAP',
      processingInputRoot: r'\\CAPPC\CAP',
      processingOutputRoot: r'\\NAS\processed',
    );
    final input = effectiveProcessingInput(config)!;
    final json = buildLwipConfig(
      config,
      input: input,
      output: effectiveProcessingOutput(config, input),
      runtimeDir: r'C:\LWCAM_DBs\lwip',
    );
    expect(json['input_root'], r'\\CAPPC\CAP');
    expect(json['output_root'], r'\\NAS\processed');
  });

  test('an output inside the input is rejected before it reaches python', () {
    // LWIP refuses this at load, so catching it here turns a crash-looping
    // watcher on a capture PC into a message in Station Setup.
    const nested = NodeConfig(
      processingEnabled: true,
      processingInputRoot: r'D:\Capture',
      processingOutputRoot: r'D:\Capture\out',
    );
    expect(lwipConfigProblem(nested), isNotNull);

    const same = NodeConfig(
      processingEnabled: true,
      processingInputRoot: r'D:\Capture',
      processingOutputRoot: r'D:\Capture',
    );
    expect(lwipConfigProblem(same), isNotNull);

    const ok = NodeConfig(
      processingEnabled: true,
      processingInputRoot: r'D:\Capture\1.Images',
      processingOutputRoot: r'D:\Capture\2.Batches',
    );
    expect(lwipConfigProblem(ok), isNull);
  });

  test('no input path at all is a problem, not a crash', () {
    const config = NodeConfig(processingEnabled: true);
    expect(lwipConfigProblem(config), isNotNull);
    expect(effectiveProcessingInput(config), isNull);
  });
}
