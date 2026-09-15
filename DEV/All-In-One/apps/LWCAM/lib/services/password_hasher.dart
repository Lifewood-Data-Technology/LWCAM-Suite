import 'package:bcrypt/bcrypt.dart';

/// Thin wrapper over the pure-Dart `bcrypt` package so tests and any future
/// algorithm change touch exactly one file. bcrypt embeds the salt and cost
/// factor in the `$2b$...` hash string, so callers store a single
/// `passwordHash` field with no salt/iteration bookkeeping (spec §10 names
/// bcrypt as an acceptable choice).
class PasswordHasher {
  const PasswordHasher._();

  /// Hashes [plaintext] with a fresh random salt at the default cost factor.
  static String hash(String plaintext) {
    return BCrypt.hashpw(plaintext, BCrypt.gensalt());
  }

  /// Verifies [plaintext] against a stored [hash]. Returns false (never
  /// throws) on a malformed/empty hash, so a corrupt users file can't crash
  /// login — it just fails the password check.
  static bool verify(String plaintext, String hash) {
    if (hash.isEmpty) return false;
    try {
      return BCrypt.checkpw(plaintext, hash);
    } catch (_) {
      return false;
    }
  }
}
