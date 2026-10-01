import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What a station needs from a folder: LWCAM writes captured images and
/// rework's recaptures; rework only reads LWIP's output.
enum FolderNeed { read, write }

/// Null when [path] can be used as [need] requires, else a plain-English
/// reason. Runs as the Windows account running this app — for a network
/// folder that is exactly the login Windows will hand the other PC for LWCAM,
/// as long as LWCAM runs under the same account.
///
/// `Directory.exists` is useless here: it answers false for a refused login,
/// an unknown PC and a missing folder alike. Listing and writing throw with
/// the Windows error code, which is what tells those apart.
///
/// A network folder whose PC is off can hang for minutes, so the check gives
/// up after [timeout] and says "unreachable" - a different answer from "not
/// found" or "access denied".
Future<String?> checkFolderAccess(
  String path,
  FolderNeed need, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  try {
    return await _check(path, need).timeout(timeout);
  } on TimeoutException {
    return 'Unreachable: ${uncHost(path) ?? 'the folder'} gave no answer in '
        '${timeout.inSeconds} s. Check that the PC is switched on and '
        'connected (Tailscale / network), then test again.';
  }
}

Future<String?> _check(String path, FolderNeed need) async {
  try {
    if (need == FolderNeed.write) {
      final probe = File(
        p.join(
          path,
          '.lwcam-access-test-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      await probe.writeAsString('LWCam Admin folder access test');
      try {
        await probe.delete();
      } on FileSystemException {
        // The write is what was being tested, and it worked.
      }
    } else {
      await Directory(path).list().isEmpty;
    }
    return null;
  } on FileSystemException catch (e) {
    return describeFolderError(e, path: path, need: need);
  }
}

/// The `HOST` of a `\\HOST\share\...` path, or null for a local path.
String? uncHost(String path) {
  final match = RegExp(r'^[\\/]{2}([^\\/]+)').firstMatch(path.trim());
  return match?.group(1);
}

String describeFolderError(
  FileSystemException e, {
  required String path,
  required FolderNeed need,
}) {
  final code = e.osError?.errorCode;
  final detail = (e.osError?.message ?? e.message).trim();
  final host = uncHost(path) ?? 'the other PC';
  switch (code) {
    case 2: // ERROR_FILE_NOT_FOUND
    case 3: // ERROR_PATH_NOT_FOUND
      return 'The folder does not exist.';
    case 5: // ERROR_ACCESS_DENIED
      return 'This Windows account is not allowed to '
          '${need == FolderNeed.write ? 'write to' : 'read'} this folder. '
          'Give it ${need == FolderNeed.write ? 'Modify' : 'Read'} permission '
          '(on the share and on the folder).';
    case 86: // ERROR_INVALID_PASSWORD
    case 1326: // ERROR_LOGON_FAILURE
      return '$host did not accept this Windows account\'s login. Save a '
          'login for it once, as the Windows user who runs LWCAM:\n'
          'cmdkey /add:$host /user:$host\\<user> /pass:<password>';
    case 1219: // ERROR_SESSION_CREDENTIAL_CONFLICT
      return 'Windows is already connected to $host with a different '
          'account. Run "net use \\\\$host /delete" (or sign out and back in), '
          'then test again.';
    case 51: // ERROR_REM_NOT_LIST
    case 53: // ERROR_BAD_NETPATH
    case 64: // ERROR_NETNAME_DELETED
    case 1231: // ERROR_NETWORK_UNREACHABLE
    case 1232: // ERROR_HOST_UNREACHABLE
      return 'Cannot reach $host on the network. Check that it is switched '
          'on and connected, and that the name is spelt right.';
    case 67: // ERROR_BAD_NET_NAME
      return '$host answered, but has no shared folder by that name. Check '
          'the share name after \\\\$host\\.';
    case 1327: // ERROR_ACCOUNT_RESTRICTION (e.g. a blank password)
    case 1330: // ERROR_PASSWORD_EXPIRED
    case 1331: // ERROR_ACCOUNT_DISABLED
    case 1385: // ERROR_LOGON_TYPE_NOT_GRANTED
    case 1907: // ERROR_PASSWORD_MUST_CHANGE
    case 1909: // ERROR_ACCOUNT_LOCKED_OUT
      return '$host refused the login: $detail';
    default:
      return code == null
          ? 'Could not use this folder: $detail'
          : 'Could not use this folder: $detail (Windows error $code)';
  }
}
