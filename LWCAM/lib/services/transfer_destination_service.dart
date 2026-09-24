import 'dart:io';

import 'package:path/path.dart' as p;

class TransferDestinationService {
  static String dayFolderName(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year$month$day';
  }

  /// True when [path] names a `<root>\YYYYMMDD` day directory — the shape
  /// a box's persisted destination (`capture_boxes.transferred_to`) has since
  /// 2026-09-10. Older builds stored the bare root there, on success only.
  static bool isDayDirectory(String? path) {
    if (path == null || path.trim().isEmpty) return false;
    return RegExp(r'^\d{8}$').hasMatch(p.basename(path.trim()));
  }

  static Directory directoryForDate(String rootPath, DateTime date) {
    return Directory(p.join(rootPath, dayFolderName(date)));
  }

  static Future<Directory> ensureDirectoryForDate(
    String rootPath,
    DateTime date,
  ) async {
    final directory = directoryForDate(rootPath, date);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    return directory;
  }
}
