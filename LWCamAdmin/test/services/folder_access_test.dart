import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/folder_access.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('folder_access_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a writable folder passes and keeps no test file behind', () async {
    expect(await checkFolderAccess(temp.path, FolderNeed.write), isNull);
    expect(await temp.list().toList(), isEmpty);
  });

  test('a readable folder passes', () async {
    expect(await checkFolderAccess(temp.path, FolderNeed.read), isNull);
  });

  test('a missing folder says so, for writing and for reading', () async {
    final missing = p.join(temp.path, 'nope');
    expect(
      await checkFolderAccess(missing, FolderNeed.write),
      'The folder does not exist.',
    );
    expect(
      await checkFolderAccess(missing, FolderNeed.read),
      'The folder does not exist.',
    );
  });

  test('uncHost finds the PC name of a network path only', () {
    expect(uncHost(r'\\WIN-AOCAA208T6A\Users\x'), 'WIN-AOCAA208T6A');
    expect(uncHost('//nas/share'), 'nas');
    expect(uncHost(r'C:\LWIP\1.Images'), isNull);
  });

  group('describeFolderError', () {
    String describe(int code, {FolderNeed need = FolderNeed.write}) =>
        describeFolderError(
          FileSystemException('x', r'\\PC1\share', OSError('msg', code)),
          path: r'\\PC1\share\1.Images',
          need: need,
        );

    test('a refused login names the PC and the cmdkey fix', () {
      expect(describe(1326), contains(r'cmdkey /add:PC1 /user:PC1\<user>'));
      expect(describe(86), contains('did not accept'));
    });

    test('access denied names the permission the folder needs', () {
      expect(describe(5), contains('write to this folder'));
      expect(describe(5, need: FolderNeed.read), contains('read this folder'));
    });

    test('unknown PC, missing share and a clashing session differ', () {
      expect(describe(53), startsWith('Cannot reach PC1'));
      expect(describe(67), contains('no shared folder by that name'));
      expect(describe(1219), contains(r'net use \\PC1 /delete'));
    });

    test('anything else keeps the Windows message and code', () {
      expect(describe(9999), 'Could not use this folder: msg (Windows error 9999)');
    });
  });

  test('a check that gets no answer says unreachable, not missing', () async {
    // Zero timeout: the check cannot finish, exactly like a dead UNC host.
    final msg = await checkFolderAccess(
      r'\\LWIP-PC\input',
      FolderNeed.read,
      timeout: Duration.zero,
    );
    expect(msg, contains('Unreachable'));
    expect(msg, contains('LWIP-PC'));
    expect(msg, isNot(contains('does not exist')));
  });
}
