import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/rework_service.dart';
import 'package:path/path.dart' as p;

NodeConfig _config({String? input, String? output, String? destination}) =>
    NodeConfig(
      destinationPath: destination,
      processingInputRoot: input,
      processingOutputRoot: output,
    );

void main() {
  // Recapture works by OVERWRITING the LWIP input file: that changes the
  // folder's fingerprint, so LWIP reprocesses it, the report agent re-reports,
  // and qc_status flips back to PENDING. Resolving the wrong path would either
  // do nothing or clobber an unrelated image, so this mapping is pinned.
  group('inputFileFor', () {
    const folderPath = r'D:\Life\Test\2.Batches\20260730\BOX - 1 - 0001';

    test('maps an output folder back to its input twin', () {
      final file = ReworkService.inputFileFor(
        _config(input: r'D:\Life\Test\1.Images', output: r'D:\Life\Test\2.Batches'),
        folderPath: folderPath,
        imageName: 'SAX01_a_001.jpg',
      );
      expect(file, isNotNull);
      expect(
        p.equals(file!.path,
            r'D:\Life\Test\1.Images\20260730\BOX - 1 - 0001\SAX01_a_001.jpg'),
        isTrue,
        reason: 'got ${file.path}',
      );
    });

    test('falls back to destinationPath as the input root', () {
      final file = ReworkService.inputFileFor(
        _config(destination: r'D:\Life\Test\1.Images', output: r'D:\Life\Test\2.Batches'),
        folderPath: folderPath,
        imageName: 'a.jpg',
      );
      expect(file, isNotNull);
      expect(file!.path, contains(r'1.Images'));
    });

    test('derives the default output root when none is configured', () {
      // The default output root is '<input>_processed'.
      final file = ReworkService.inputFileFor(
        _config(input: r'D:\cap'),
        folderPath: r'D:\cap_processed\20260730\F1',
        imageName: 'a.jpg',
      );
      expect(file, isNotNull);
      expect(p.equals(file!.path, r'D:\cap\20260730\F1\a.jpg'), isTrue,
          reason: 'got ${file.path}');
    });

    test('refuses a folder outside this station\'s output root', () {
      // Captured on another station: overwriting a guessed local path could
      // clobber an unrelated image, so refuse rather than guess.
      expect(
        ReworkService.inputFileFor(
          _config(input: r'D:\Life\Test\1.Images', output: r'D:\Life\Test\2.Batches'),
          folderPath: r'E:\OtherStation\2.Batches\20260730\F1',
          imageName: 'a.jpg',
        ),
        isNull,
      );
    });

    test('refuses when roots or arguments are missing', () {
      expect(
        ReworkService.inputFileFor(_config(),
            folderPath: folderPath, imageName: 'a.jpg'),
        isNull,
      );
      expect(
        ReworkService.inputFileFor(
            _config(input: r'D:\in', output: r'D:\out'),
            folderPath: '',
            imageName: 'a.jpg'),
        isNull,
      );
      expect(
        ReworkService.inputFileFor(
            _config(input: r'D:\in', output: r'D:\out'),
            folderPath: r'D:\out\F1',
            imageName: '   '),
        isNull,
      );
    });

    test('tolerates trailing separators and mixed slashes in the roots', () {
      final file = ReworkService.inputFileFor(
        _config(input: r'D:\Life\Test\1.Images\', output: r'D:/Life/Test/2.Batches'),
        folderPath: folderPath,
        imageName: 'a.jpg',
      );
      expect(file, isNotNull);
      expect(file!.path, contains('20260730'));
      expect(file.path, contains('1.Images'));
    });
  });

  group('effective roots', () {
    test('explicit input wins over destination; output defaults to _processed', () {
      final config = _config(input: r'D:\in', destination: r'D:\dest');
      expect(ReworkService.effectiveInputRoot(config), r'D:\in');
      expect(ReworkService.effectiveOutputRoot(config, r'D:\in'), r'D:\in_processed');
    });

    test('blank strings are treated as unset', () {
      final config = _config(input: '   ', output: '  ', destination: r'D:\dest');
      expect(ReworkService.effectiveInputRoot(config), r'D:\dest');
      expect(ReworkService.effectiveOutputRoot(config, r'D:\dest'),
          r'D:\dest_processed');
    });

    test('no roots at all yields null', () {
      expect(ReworkService.effectiveInputRoot(_config()), isNull);
    });
  });
}
