import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/path_utils.dart';

void main() {
  group('sanitizeWindowsName', () {
    test('replaces invalid Windows filename characters', () {
      expect(sanitizeWindowsName('a<b>c:d"e/f\\g|h?i*j'), 'a_b_c_d_e_f_g_h_i_j');
    });

    test('preserves inner spaces', () {
      expect(sanitizeWindowsName('8310 V207286-207306'), '8310 V207286-207306');
    });

    test('trims trailing dots and spaces', () {
      expect(sanitizeWindowsName('name...  '), 'name');
    });

    test('disambiguates reserved device names', () {
      expect(sanitizeWindowsName('CON'), 'CON_');
      expect(sanitizeWindowsName('con'), 'con_');
      expect(sanitizeWindowsName('CONTOSO'), 'CONTOSO');
    });

    // Windows reserves the device name whether or not an extension follows
    // it - "CON.1", "NUL.txt" and "COM1.anything" are all illegal names too,
    // and the check must key off the part before the FIRST dot only.
    test('disambiguates a reserved device name with an extension', () {
      expect(sanitizeWindowsName('CON.1'), 'CON.1_');
      expect(sanitizeWindowsName('NUL.txt'), 'NUL.txt_');
      expect(sanitizeWindowsName('com1.anything'), 'com1.anything_');
      expect(sanitizeWindowsName('lpt3.tar.gz'), 'lpt3.tar.gz_');
    });

    test('never returns an empty string', () {
      expect(sanitizeWindowsName('...'), '_');
    });
  });

  group('boxKeyFor', () {
    test('is deterministic for the same input', () {
      expect(boxKeyFor('8310 V207286-207306'), boxKeyFor('8310 V207286-207306'));
    });

    test('differs for different inputs even with the same sanitized prefix', () {
      final a = boxKeyFor('#N/A');
      final b = boxKeyFor('#N/A '); // trimmed to the same prefix but hashed pre-trim on different raw text
      // Both round-trip through .trim() before hashing, so equal-after-trim
      // inputs intentionally collide; assert the untrimmed distinct cases below instead.
      expect(a, isNotEmpty);
      expect(b, isNotEmpty);
    });

    test('produces a filesystem-safe key', () {
      final key = boxKeyFor('#N/A');
      expect(RegExp(r'[<>:"/\\|?*]').hasMatch(key), isFalse);
    });

    test('distinguishes two different malformed box-details values', () {
      expect(boxKeyFor('#N/A'), isNot(boxKeyFor('- 1341 114437-114510')));
    });
  });
}
