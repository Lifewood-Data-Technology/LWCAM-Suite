// Reads the database logins that LWCam Admin stores in the node config. Each
// password is saved DPAPI-encrypted, so it opens only for the Windows account
// that saved it; the functions here decrypt it or report that it cannot be read.
import 'package:get/get.dart';

import '../models/node_config.dart';
import 'dpapi.dart';

/// Message shown wherever the saved admin login cannot be used.
const adminLoginUnreadableMessage =
    'The saved LWCam Admin login cannot be read on this Windows account '
    '— re-enter it in Station Setup.';

/// True while the last [adminLoginFor] found an `adminPgPasswordProtected`
/// blob it could not decrypt (saved by another Windows user/PC). The home
/// page and Station Setup show [adminLoginUnreadableMessage] while it is set.
final adminLoginUnreadable = false.obs;

String _unprotectCapture(String blob) =>
    dpapiUnprotect(blob, entropy: captureDpapiEntropy);

/// The capture login's password: `pgPasswordProtected` (DPAPI, entropy
/// "LWCam") first, else the plain `pgPassword` of an old file. Throws when
/// the blob is present but cannot be decrypted and there is no plain copy.
/// [unprotect] is injectable for tests.
String capturePasswordOf(
  NodeConfig c, {
  String Function(String) unprotect = _unprotectCapture,
}) {
  final blob = c.pgPasswordProtected ?? '';
  if (blob.isNotEmpty) {
    try {
      return unprotect(blob);
    } catch (_) {
      final plain = c.pgPassword ?? '';
      if (plain.isNotEmpty) return plain;
      rethrow;
    }
  }
  return c.pgPassword ?? '';
}

/// Which database login LWCam Admin uses for admin work: its own
/// (`adminPgUser` + DPAPI-decrypted `adminPgPasswordProtected`) when both are
/// set, else the shared `pgUser`/capture password — so old stations still on
/// `postgres` keep working. [unprotect] is injectable for tests.
///
/// A blob that cannot be decrypted still falls back to the capture login (so
/// the app keeps working), but raises [adminLoginUnreadable] so the operator
/// is told instead of silently running as a different database user.
({String user, String password}) adminLoginFor(
  NodeConfig c, {
  String Function(String) unprotect = dpapiUnprotect,
  String Function(String)? unprotectCapture,
}) {
  final user = c.adminPgUser?.trim() ?? '';
  final blob = c.adminPgPasswordProtected ?? '';
  adminLoginUnreadable.value = false;
  if (user.isNotEmpty && blob.isNotEmpty) {
    try {
      return (user: user, password: unprotect(blob));
    } catch (e) {
      adminLoginUnreadable.value = true;
      print('⚠️ Admin database password could not be decrypted ($e); using the capture login.');
    }
  }
  String capture;
  try {
    capture = unprotectCapture == null
        ? capturePasswordOf(c)
        : capturePasswordOf(c, unprotect: unprotectCapture);
  } catch (e) {
    print('⚠️ Capture database password could not be decrypted ($e).');
    capture = '';
  }
  return (user: c.pgUser ?? '', password: capture);
}
