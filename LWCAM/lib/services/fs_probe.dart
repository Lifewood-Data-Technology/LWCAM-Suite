import 'dart:async';
import 'dart:io';

/// How long any check of a network (UNC) path may take before the share is
/// treated as down. A dead SMB share otherwise blocks a call for the OS
/// timeout (30+ s) - on the UI isolate that is a frozen window.
const Duration kFsProbeTimeout = Duration(seconds: 5);

/// Reachable-and-there / reachable-but-absent / could not be asked.
enum FsProbe { found, notFound, unreachable }

/// Async, time-bounded existence check for a file or directory. Never blocks
/// the caller's isolate; a timeout or an OS error reads as [FsProbe.unreachable].
Future<FsProbe> probeExists(
  FileSystemEntity entity, {
  Duration timeout = kFsProbeTimeout,
}) async {
  try {
    final found = await entity.exists().timeout(timeout);
    return found ? FsProbe.found : FsProbe.notFound;
  } catch (_) {
    return FsProbe.unreachable;
  }
}
