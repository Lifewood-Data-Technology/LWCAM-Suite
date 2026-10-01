import 'dart:convert';
import 'dart:io';

/// Wrong-password lock for the SuperAdmin login. 5 consecutive wrong
/// passwords lock for 1 minute; every further wrong attempt doubles the lock
/// (cap 15 min). A correct login resets. State lives in a small JSON file so
/// restarting the app does not clear it.
///
/// This is a UI speed-bump, NOT a security boundary: the SuperAdmin password
/// hash is a factory value shared by every install (the user's accepted
/// choice), and anyone who can read or delete the lock file, or edit the
/// registry/clock, can already do more than guess passwords here. What it does
/// cover is the cheap ways around the delay:
/// - inside one running process the lock is timed with a monotonic clock, so
///   moving the Windows clock forward/back or deleting the file does not
///   shorten it;
/// - a lock file that is corrupt is treated as locked for the maximum window
///   (from the file's last-modified time), never as unlocked;
/// - a clock moved BACKWARDS keeps the lock (the wall-clock end is capped at
///   the maximum window, and a "now" earlier than the lock start counts the
///   full window).
class LoginLock {
  static const fileName = 'lwcam_admin_login_lock.json';
  static const freeAttempts = 5;
  static const maxLock = Duration(minutes: 15);

  final String path;
  final DateTime Function() now;

  /// Monotonic time since some fixed point (default: a [Stopwatch] started
  /// with this object). Injectable for tests.
  final Duration Function() elapsed;

  // In-process state, which survives the lock file going missing or corrupt.
  int _memFails = 0;
  Duration? _memLockEnd; // value of [elapsed] at which the lock ends

  LoginLock(this.path, {DateTime Function()? now, Duration Function()? elapsed})
      : now = now ?? DateTime.now,
        elapsed = elapsed ?? _stopwatch();

  static Duration Function() _stopwatch() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  ({int fails, DateTime? until, DateTime? lockedAt}) _read() {
    final file = File(path);
    try {
      if (!file.existsSync()) return (fails: 0, until: null, lockedAt: null);
      final j = jsonDecode(file.readAsStringSync()) as Map;
      final ms = (j['lockedUntilMs'] as num?)?.toInt();
      final at = (j['lockedAtMs'] as num?)?.toInt();
      return (
        fails: (j['fails'] as num?)?.toInt() ?? 0,
        until: ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms),
        lockedAt: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      );
    } catch (_) {
      // Exists but unreadable/corrupt: assume the worst - locked for the
      // maximum window counted from when the file was last touched.
      try {
        final touched = file.lastModifiedSync();
        return (
          fails: freeAttempts,
          until: touched.add(maxLock),
          lockedAt: touched,
        );
      } catch (_) {
        return (fails: 0, until: null, lockedAt: null);
      }
    }
  }

  void _write(int fails, DateTime? until) {
    try {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsStringSync(jsonEncode({
        'fails': fails,
        'lockedUntilMs': until?.millisecondsSinceEpoch,
        'lockedAtMs': until == null ? null : now().millisecondsSinceEpoch,
      }));
    } catch (_) {} // ponytail: unwritable folder = no persistence; the in-process monotonic lock still holds
  }

  /// Time left on the lock, or null when a password may be tried.
  Duration? remaining() {
    Duration best = Duration.zero;

    final r = _read();
    final until = r.until;
    if (until != null) {
      final t = now();
      var left = until.difference(t);
      final at = r.lockedAt;
      // Clock moved back to before the lock began: keep the whole window.
      if (at != null && t.isBefore(at)) left = until.difference(at);
      if (left > maxLock) left = maxLock; // clock moved back a long way
      if (left > best) best = left;
    }

    final end = _memLockEnd;
    if (end != null) {
      final left = end - elapsed();
      if (left > best) best = left;
    }
    return best > Duration.zero ? best : null;
  }

  void recordFailure() {
    final fails = (_read().fails > _memFails ? _read().fails : _memFails) + 1;
    _memFails = fails;
    DateTime? until;
    if (fails >= freeAttempts) {
      final minutes = 1 << (fails - freeAttempts).clamp(0, 10);
      final d = Duration(minutes: minutes) > maxLock
          ? maxLock
          : Duration(minutes: minutes);
      until = now().add(d);
      _memLockEnd = elapsed() + d;
    }
    _write(fails, until);
  }

  void reset() {
    _memFails = 0;
    _memLockEnd = null;
    if (File(path).existsSync()) _write(0, null);
  }

  static String describe(Duration d) => d.inSeconds >= 60
      ? '${(d.inSeconds / 60).ceil()} min'
      : '${d.inSeconds.clamp(1, 59)} s';
}
