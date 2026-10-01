import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/safe_copy.dart';
import 'package:path/path.dart' as p;

void main() {
  group('longPath', () {
    final deep = r'C:\' + List.filled(40, 'folder').join(r'\') + r'\x.jpg';
    test('short paths pass through', () {
      expect(longPath(r'C:\a\b.jpg', isWindows: true), r'C:\a\b.jpg');
    });
    test('drive path gets the long-path prefix at 240+ chars', () {
      expect(deep.length, greaterThan(240));
      expect(longPath(deep, isWindows: true), r'\\?\' + deep);
    });
    test('UNC path gets the UNC long-path prefix', () {
      final unc =
          r'\\srv\share\' + List.filled(40, 'folder').join(r'\') + r'\x.jpg';
      expect(longPath(unc, isWindows: true), r'\\?\UNC\' + unc.substring(2));
    });
    test('already prefixed, relative and non-Windows are untouched', () {
      final pre = r'\\?\' + deep;
      expect(longPath(pre, isWindows: true), pre);
      expect(longPath(deep, isWindows: false), deep);
      final rel = List.filled(60, 'folder').join(r'\');
      expect(longPath(rel, isWindows: true), rel);
    });
  });

  group('safeCopy', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('safe_copy_'));
    tearDown(() async => dir.delete(recursive: true));

    test('lands under the final name, no .part left, replaces existing',
        () async {
      final src = File(p.join(dir.path, 'src.jpg'))..writeAsStringSync('new');
      final dest = p.join(dir.path, 'dest.jpg');
      File(dest).writeAsStringSync('old');
      await safeCopy(src, dest);
      expect(File(dest).readAsStringSync(), 'new');
      expect(File('$dest.part').existsSync(), isFalse);
    });

    test('a failed copy leaves neither .part nor a destination', () async {
      final dest = p.join(dir.path, 'dest.jpg');
      await expectLater(
        safeCopy(File(p.join(dir.path, 'missing.jpg')), dest),
        throwsA(isA<FileSystemException>()),
      );
      expect(File(dest).existsSync(), isFalse);
      expect(File('$dest.part').existsSync(), isFalse);
    });
  });
}
