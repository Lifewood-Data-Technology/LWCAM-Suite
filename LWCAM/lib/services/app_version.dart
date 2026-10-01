import 'dart:io';

import 'package:path/path.dart' as p;

/// The installed build, from `VERSION.txt` beside the exe (the installers
/// write `1.1.0+<sha>` there); `dev` when there is no such file (dev builds).
String readAppVersion([Directory? dir]) {
  try {
    final folder = dir?.path ?? p.dirname(Platform.resolvedExecutable);
    final text = File(p.join(folder, 'VERSION.txt')).readAsStringSync().trim();
    if (text.isNotEmpty) return text;
  } catch (_) {}
  return 'dev';
}

final String appVersion = readAppVersion();
