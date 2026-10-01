import 'package:shared_preferences/shared_preferences.dart';

/// How long a user may keep signing in on a TEMPORARY password while the
/// database (where the forced change happens) cannot be reached: at most
/// [maxSignIns] sign-ins or [maxAge], whichever comes first. Stored per user
/// on THIS PC (a capture PC may be offline for days, so the limit cannot be
/// enforced anywhere else). ponytail: local clock, so setting it back extends
/// the window - acceptable, the password is still only a temporary one.
class OfflineTempPassword {
  static const maxSignIns = 3;
  static const maxAge = Duration(days: 7);

  static String _key(String user) =>
      'offline_temp_pw.${user.trim().toLowerCase()}';

  /// Counts one offline sign-in. Returns true while inside the allowance.
  static Future<bool> tryConsume(String user, {DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final at = now ?? DateTime.now();
    final raw = prefs.getString(_key(user))?.split('|');
    var count = 0;
    var first = at;
    if (raw != null && raw.length == 2) {
      count = int.tryParse(raw[0]) ?? 0;
      first = DateTime.fromMillisecondsSinceEpoch(
          int.tryParse(raw[1]) ?? at.millisecondsSinceEpoch);
    }
    if (count >= maxSignIns || at.difference(first) > maxAge) return false;
    await prefs.setString(
        _key(user), '${count + 1}|${first.millisecondsSinceEpoch}');
    return true;
  }

  /// Forget the allowance (the password was changed).
  static Future<void> clear(String user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(user));
  }
}
