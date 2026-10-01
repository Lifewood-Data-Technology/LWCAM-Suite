import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/node_config.dart';
import 'package:lwcam_admin/services/admin_login.dart';
import 'package:lwcam_admin/services/dpapi.dart';

void main() {
  const capture = NodeConfig(pgUser: 'lwcam_capture', pgPassword: 'cap-pw');

  test('uses the admin login when both fields are set', () {
    final c = capture.copyWith(
      adminPgUser: 'lwcam_admin',
      adminPgPasswordProtected: 'BLOB',
    );
    final l = adminLoginFor(c, unprotect: (b) => b == 'BLOB' ? 'adm-pw' : '');
    expect((l.user, l.password), ('lwcam_admin', 'adm-pw'));
  });

  test('falls back to pgUser/pgPassword when the admin fields are empty', () {
    for (final c in [
      capture,
      capture.copyWith(adminPgUser: 'lwcam_admin'), // no password
      capture.copyWith(adminPgPasswordProtected: 'BLOB'), // no user
    ]) {
      final l = adminLoginFor(c, unprotect: (_) => 'x');
      expect((l.user, l.password), ('lwcam_capture', 'cap-pw'));
    }
  });

  test('falls back when the blob cannot be decrypted', () {
    final c = capture.copyWith(
      adminPgUser: 'lwcam_admin',
      adminPgPasswordProtected: 'BLOB',
    );
    final l = adminLoginFor(c, unprotect: (_) => throw StateError('no'));
    expect(l.user, 'lwcam_capture');
  });

  test('NodeConfig JSON round-trips the two admin fields', () {
    final c = capture.copyWith(
      adminPgUser: 'lwcam_admin',
      adminPgPasswordProtected: 'QUJD',
    );
    final back = NodeConfig.fromJson(
      jsonDecode(jsonEncode(c.toJson())) as Map<String, Object?>,
    );
    expect(back.adminPgUser, 'lwcam_admin');
    expect(back.adminPgPasswordProtected, 'QUJD');
    expect(back.pgPassword, 'cap-pw');
  });

  test(
    'DPAPI round-trip; the saved JSON never holds the plaintext',
    () {
      const secret = 'S3cret-pw é "quote"';
      final blob = dpapiProtect(secret);
      expect(blob, isNot(contains('S3cret')));
      expect(dpapiUnprotect(blob), secret);
      final json = jsonEncode(
        capture
            .copyWith(adminPgUser: 'lwcam_admin', adminPgPasswordProtected: blob)
            .toJson(),
      );
      expect(json, isNot(contains(secret)));
      expect(json, contains(blob));
    },
    skip: Platform.isWindows ? false : 'DPAPI is Windows-only',
  );
}
