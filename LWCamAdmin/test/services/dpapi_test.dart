import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/dpapi.dart';

void main() {
  final skip = Platform.isWindows ? false : 'DPAPI is Windows-only';

  test('capture and admin entropies do not decrypt each other', () {
    final capture = dpapiProtect('cap-pw', entropy: captureDpapiEntropy);
    final admin = dpapiProtect('adm-pw');
    expect(dpapiUnprotect(capture, entropy: captureDpapiEntropy), 'cap-pw');
    expect(dpapiUnprotect(admin), 'adm-pw');
    expect(() => dpapiUnprotect(capture), throwsStateError);
    expect(() => dpapiUnprotect(admin, entropy: captureDpapiEntropy),
        throwsStateError);
  }, skip: skip);

  test('a failure names the Win32 error code', () {
    // Valid base64, but not a DPAPI blob.
    expect(
      () => dpapiUnprotect('AAAAAAAAAAAAAAAA'),
      throwsA(predicate((e) => e.toString().contains('Win32 error'))),
    );
  }, skip: skip);

  test('empty, unicode and long passwords round-trip', () {
    for (final s in ['', 'é"quote"日本', 'x' * 5000]) {
      expect(dpapiUnprotect(dpapiProtect(s)), s);
    }
  }, skip: skip);
}
