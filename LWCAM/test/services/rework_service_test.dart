import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/rework_service.dart';
import 'package:path/path.dart' as p;

Future<File?> resolve(NodeConfig c, {required String folderPath, required String imageName}) async =>
    (await ReworkService.inputFileFor(c, folderPath: folderPath, imageName: imageName)).file;

void main() {
  // Recapture works by OVERWRITING the original in LWIP's input - this
  // station's own image destination. That changes the folder's fingerprint,
  // so LWIP reprocesses it and qc_status flips back to PENDING. Resolving the
  // wrong path would either do nothing or clobber an unrelated image, so this
  // mapping is pinned.
  group('inputFileFor', () {
    late Directory destination;

    setUp(() async {
      destination = await Directory.systemTemp.createTemp('rework_dest_');
    });

    tearDown(() async {
      if (await destination.exists()) await destination.delete(recursive: true);
    });

    NodeConfig config({String? dest}) =>
        NodeConfig(destinationPath: dest ?? destination.path);

    Future<File> original(String date, String folder, String image) async {
      final file = File(p.join(destination.path, date, folder, image));
      await file.parent.create(recursive: true);
      await file.writeAsString('camera bytes');
      return file;
    }

    test('LWIP\'s own path for the folder maps to the original here', () async {
      // LWIP records C:\LWIP\2.Batches\... - its own PC's spelling, which
      // this PC could not open; only the <date>\<folder> tail is used.
      final expected = await original('20260924', '999 8888-9999 file no', 'SAX01_a_001.jpg');
      final file = await resolve(
        config(),
        folderPath: r'C:\LWIP\2.Batches\20260924\999 8888-9999 file no',
        imageName: 'SAX01_a_001.jpg',
      );
      expect(file, isNotNull);
      expect(p.equals(file!.path, expected.path), isTrue, reason: 'got ${file.path}');
    });

    test('any head works: a UNC share, forward slashes, a trailing slash', () async {
      final expected = await original('20260730', 'BOX - 1 - 0001', 'a.jpg');
      for (final folderPath in [
        r'\\FILE-PC\LWCamTest\2.Batches\20260730\BOX - 1 - 0001',
        'D:/Life/Test/2.Batches/20260730/BOX - 1 - 0001/',
      ]) {
        final file = await resolve(config(), folderPath: folderPath, imageName: 'a.jpg');
        expect(file, isNotNull, reason: folderPath);
        expect(p.equals(file!.path, expected.path), isTrue, reason: 'got ${file.path}');
      }
    });

    test('an eight-digit Volume is the folder, not the date', () async {
      // Volume is free text and the folder name IS the Volume.
      final expected = await original('20260924', '19450512', 'a.jpg');
      final file = await resolve(
        config(),
        folderPath: r'C:\LWIP\2.Batches\20260924\19450512',
        imageName: 'a.jpg',
      );
      expect(file, isNotNull);
      expect(p.equals(file!.path, expected.path), isTrue, reason: 'got ${file.path}');
    });

    test('refuses a folder whose original is not on this station', () async {
      // Captured on another station with another destination: overwriting a
      // guessed path could clobber or scatter, so refuse rather than guess.
      expect(
        await resolve(
          config(),
          folderPath: r'E:\OtherStation\2.Batches\20260730\F1',
          imageName: 'a.jpg',
        ),
        isNull,
      );
    });

    test('database-supplied traversal is refused; the outside file is never '
        'returned', () async {
      await original('20260730', 'F1', 'a.jpg');
      final outside = File(p.join(destination.parent.path, 'outside_rework.txt'))
        ..writeAsStringSync('x');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync();
      });
      const folder = r'C:\LWIP\2.Batches\20260730\F1';
      for (final name in [
        r'..\..\..\outside_rework.txt',
        '../../../outside_rework.txt',
        r'sub\a.jpg',
        'sub/a.jpg',
        r'C:\Windows\win.ini',
        'a.jpg:stream',
        '..',
      ]) {
        expect(
          await resolve(config(), folderPath: folder, imageName: name),
          isNull,
          reason: name,
        );
      }
      for (final tail in [
        r'C:\LWIP\20260730\..\..\..\x',
        r'C:\LWIP\20260730\F1\..\..\..',
        r'C:\LWIP\20260730\D:\F1',
      ]) {
        expect(
          await resolve(config(), folderPath: tail, imageName: 'a.jpg'),
          isNull,
          reason: tail,
        );
      }
    });

    test('a cross-PC path (other PC, other root) still re-roots by its date '
        'tail', () async {
      final expected = await original('20260730', 'F1', 'a b.jpg');
      final file = await resolve(
        config(),
        folderPath: r'\\lwip-pc\shared\Batches\20260730\F1',
        imageName: 'a b.jpg',
      );
      expect(file, isNotNull);
      expect(p.equals(file!.path, expected.path), isTrue);
    });

    test('refuses a path with no date folder, or missing arguments', () async {
      await original('20260730', 'F1', 'a.jpg');
      expect(
        await resolve(config(), folderPath: r'C:\LWIP\2.Batches\F1', imageName: 'a.jpg'),
        isNull,
      );
      expect(await resolve(config(), folderPath: '', imageName: 'a.jpg'), isNull);
      expect(
        await resolve(config(), folderPath: r'C:\x\20260730\F1', imageName: '   '),
        isNull,
      );
      expect(
        await resolve(config(dest: '  '), folderPath: r'C:\x\20260730\F1', imageName: 'a.jpg'),
        isNull,
      );
    });
  });
}
