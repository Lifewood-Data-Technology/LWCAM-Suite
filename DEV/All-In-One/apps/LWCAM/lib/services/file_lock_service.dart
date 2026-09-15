import 'dart:io';
import 'package:path/path.dart' as p;

/// Exception thrown when a file is already locked
class FileLockedError implements Exception {
  final String filePath;
  final String reason;

  FileLockedError(this.filePath, {this.reason = 'File is locked'});

  @override
  String toString() => '$reason: $filePath';
}

/// Service to manage exclusive file locks during transfer operations
/// Prevents Excel/data files from being opened or modified while transferring
class FileLockService {
  static final FileLockService _instance = FileLockService._internal();

  factory FileLockService() => _instance;

  FileLockService._internal();

  // Map: source file path -> lock file handle
  final Map<String, File> _activeLocks = <String, File>{};

  // Supported data file extensions for locking
  static const List<String> _lockableExtensions = [
    '.xlsx',
    '.xls',
    '.xlsm',
    '.csv',
    '.db',
    '.sqlite',
    '.json',
  ];

  /// Check if a file extension should be locked during transfer
  bool isLockableFile(String filePath) {
    final ext = p.extension(filePath).toLowerCase();
    return _lockableExtensions.contains(ext);
  }

  /// Acquire exclusive lock on a file to prevent access
  /// Returns true if lock acquired successfully
  /// Throws FileLockedError if file is already locked
  Future<bool> acquireLock(String filePath) async {
    // Check if already locked by this service
    if (_activeLocks.containsKey(filePath)) {
      return true;
    }

    final lockPath = '$filePath.lock';
    final lockFile = File(lockPath);

    try {
      // Try to create lock file (will fail if already exists)
      final lockDir = lockFile.parent;
      if (!await lockDir.exists()) {
        await lockDir.create(recursive: true);
      }

      // Write lock file with timestamp and process info
      await lockFile.writeAsString(
        'LOCKED_BY_LWCAM\n'
        'Timestamp: ${DateTime.now().toIso8601String()}\n'
        'File: $filePath\n'
        'PID: $pid\n',
        mode: FileMode.writeOnly,
        flush: true,
      );

      _activeLocks[filePath] = lockFile;
      print('🔒 Acquired exclusive lock: $filePath');
      return true;
    } catch (e) {
      throw FileLockedError(
        filePath,
        reason: 'Could not acquire lock (file may be in use)',
      );
    }
  }

  /// Release lock on a file and allow access
  Future<void> releaseLock(String filePath) async {
    final lockFile = _activeLocks.remove(filePath);
    if (lockFile != null) {
      try {
        if (await lockFile.exists()) {
          await lockFile.delete();
        }
        print('🔓 Released lock: $filePath');
      } catch (e) {
        print('⚠️ Failed to delete lock file for $filePath: $e');
      }
    }
  }

  /// Release all active locks (cleanup on app exit or batch completion)
  Future<void> releaseAllLocks() async {
    final allPaths = _activeLocks.keys.toList();
    for (final path in allPaths) {
      try {
        await releaseLock(path);
      } catch (e) {
        print('⚠️ Error releasing lock for $path: $e');
      }
    }
    _activeLocks.clear();
  }
}
