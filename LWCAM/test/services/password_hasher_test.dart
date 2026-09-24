import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/password_hasher.dart';

void main() {
  group('PasswordHasher', () {
    test('hash is not the plaintext and verifies correctly', () {
      const pw = 'Sup3r-Secret!';
      final hash = PasswordHasher.hash(pw);
      expect(hash, isNot(pw));
      expect(hash, startsWith(r'$2')); // bcrypt hash prefix
      expect(PasswordHasher.verify(pw, hash), isTrue);
    });

    test('rejects the wrong password', () {
      final hash = PasswordHasher.hash('correct horse');
      expect(PasswordHasher.verify('battery staple', hash), isFalse);
    });

    test('two hashes of the same password differ (random salt)', () {
      const pw = 'same-password';
      expect(PasswordHasher.hash(pw), isNot(PasswordHasher.hash(pw)));
    });

    test('verify never throws on a malformed or empty hash', () {
      expect(PasswordHasher.verify('x', ''), isFalse);
      expect(PasswordHasher.verify('x', 'not-a-bcrypt-hash'), isFalse);
    });
  });
}
