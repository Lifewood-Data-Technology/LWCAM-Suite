// Small path and hashing helpers for LWCAM: making names safe for Windows
// folders and a stable content fingerprint.
import 'dart:convert';

/// Windows-invalid filename characters and control characters.
final RegExp _invalidWindowsChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

const Set<String> _reservedWindowsNames = {
  'CON', 'PRN', 'AUX', 'NUL',
  'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
  'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9',
};

/// Sanitizes [input] for use as a single Windows path segment: replaces
/// invalid characters, trims trailing dots/spaces (Windows disallows them),
/// and disambiguates reserved device names. Inner spaces are preserved.
String sanitizeWindowsName(String input) {
  var result = input.replaceAll(_invalidWindowsChars, '_');
  result = result.replaceAll(RegExp(r'[. ]+$'), '');
  if (result.isEmpty) return '_';
  // Windows reserves the device name whether or not it carries an extension
  // ("CON.1", "NUL.txt", "COM1.anything" are all illegal) — only the part
  // before the FIRST dot is the device name; "CONTOSO" is not one.
  if (_reservedWindowsNames.contains(result.split('.').first.toUpperCase())) {
    result = '${result}_';
  }
  return result;
}

/// Deterministic 64-bit FNV-1a hash, hex-encoded. Used instead of a crypto
/// package (not a project dependency) wherever a stable content fingerprint
/// is needed but not a security boundary — box-key disambiguation and
/// upload-queue checkpoint signatures.
/// Native `int` is 64-bit on the Dart VM (this app only targets Windows
/// desktop, never web), so arithmetic wraps as intended.
String fnv1a64Hex(String input) {
  const int fnvOffsetBasis = 0xcbf29ce484222325;
  const int fnvPrime = 0x100000001b3;
  int hash = fnvOffsetBasis;
  for (final byte in utf8.encode(input)) {
    hash ^= byte;
    hash = hash * fnvPrime;
  }
  return hash.toRadixString(16).padLeft(16, '0').substring(0, 16);
}

/// A stable key for a box-details value, safe to use as a filename. Two
/// different raw values that sanitize to the same prefix (e.g. differing
/// only in case or an ignored character) still get distinct keys because the
/// hash is computed over the untouched original string.
String boxKeyFor(String boxDetails) {
  final trimmed = boxDetails.trim();
  final sanitized = sanitizeWindowsName(trimmed);
  final prefix = sanitized.isEmpty ? 'UNKNOWN' : sanitized;
  final hash = fnv1a64Hex(trimmed).substring(0, 8);
  return '${prefix}_$hash';
}
