import 'dart:io';

/// Paths this long (MAX_PATH is 260, minus room for a file name / `.part`)
/// get the `\\?\` prefix so Win32 file calls do not fail on deep NAS trees.
const int kLongPathThreshold = 240;

/// [path] in a form safe for File/Directory calls: `\\?\C:\...` or
/// `\\?\UNC\server\share\...` once it reaches [kLongPathThreshold] characters.
/// Shorter, relative, already-prefixed and non-Windows paths pass through.
/// Use it for the OPERATION only - store and display the original path.
String longPath(String path, {bool? isWindows}) {
  if (!(isWindows ?? Platform.isWindows)) return path;
  if (path.length < kLongPathThreshold || path.startsWith(r'\\?\')) return path;
  final flat = path.replaceAll('/', r'\');
  if (flat.startsWith(r'\\')) return r'\\?\UNC\' + flat.substring(2);
  if (RegExp(r'^[A-Za-z]:\\').hasMatch(flat)) return r'\\?\' + flat;
  return path; // relative: prefixing would break it
}

/// Copies [source] to [destPath] via `<destPath>.part` and a rename, so a
/// crash or dropped share never leaves a torn file under the final name.
/// Replaces an existing [destPath] (callers that must not do that choose a
/// fresh name first). Returns the destination file.
Future<File> safeCopy(File source, String destPath) async {
  final part = File(longPath('$destPath.part'));
  try {
    await File(longPath(source.path)).copy(part.path);
    return await part.rename(longPath(destPath));
  } catch (_) {
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Write [text] atomically: temp file then replace (never delete-then-rename,
/// so there is no moment without the file).
Future<void> writeStringAtomic(String path, String text) async {
  final tmp = File(longPath('$path.tmp'));
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(longPath(path));
}
