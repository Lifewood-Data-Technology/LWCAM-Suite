import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/auth/login_lock.dart';

void main() {
  late Directory dir;
  late DateTime clock;
  late Duration mono; // the monotonic clock, advanced with the wall clock
  late String path;
  LoginLock make() =>
      LoginLock(path, now: () => clock, elapsed: () => mono);
  void advance(Duration d) {
    clock = clock.add(d);
    mono += d;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('lock_test');
    path = '${dir.path}/${LoginLock.fileName}';
    clock = DateTime(2026, 1, 1, 12);
    mono = Duration.zero;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('four wrong passwords do not lock; the fifth locks for 1 minute', () {
    final l = make();
    for (var i = 0; i < 4; i++) {
      l.recordFailure();
    }
    expect(l.remaining(), isNull);
    l.recordFailure();
    expect(l.remaining(), const Duration(minutes: 1));
    advance(const Duration(seconds: 61));
    expect(l.remaining(), isNull);
  });

  test('each further wrong attempt doubles the lock, capped at 15 minutes', () {
    final l = make();
    for (var i = 0; i < 5; i++) {
      l.recordFailure();
    }
    final seen = <int>[];
    for (var i = 0; i < 6; i++) {
      advance(const Duration(minutes: 20));
      l.recordFailure();
      seen.add(l.remaining()!.inMinutes);
    }
    expect(seen, [2, 4, 8, 15, 15, 15]);
  });

  test('lock and counter survive a new instance (app restart)', () {
    final a = make();
    for (var i = 0; i < 5; i++) {
      a.recordFailure();
    }
    expect(make().remaining(), const Duration(minutes: 1));
    advance(const Duration(minutes: 2));
    make().recordFailure(); // 6th wrong: 2 min, counter was persisted
    expect(make().remaining(), const Duration(minutes: 2));
  });

  test('a correct login resets the counter and the lock', () {
    final l = make();
    for (var i = 0; i < 5; i++) {
      l.recordFailure();
    }
    l.reset();
    expect(make().remaining(), isNull);
    for (var i = 0; i < 4; i++) {
      l.recordFailure();
    }
    expect(l.remaining(), isNull); // back to 5 free attempts
  });

  void lockNow(LoginLock l) {
    for (var i = 0; i < 5; i++) {
      l.recordFailure();
    }
  }

  test('deleting the lock file does not unlock the running process', () {
    final l = make();
    lockNow(l);
    File(path).deleteSync();
    expect(l.remaining(), const Duration(minutes: 1));
    advance(const Duration(seconds: 61));
    expect(l.remaining(), isNull);
  });

  test('a corrupt lock file counts as locked for the maximum window', () {
    lockNow(make());
    File(path).writeAsStringSync('{ not json');
    expect(make().remaining(), LoginLock.maxLock);
  });

  test('the wall clock moved forward does not shorten the in-process lock', () {
    final l = make();
    lockNow(l);
    clock = clock.add(const Duration(hours: 5)); // monotonic clock unchanged
    expect(l.remaining(), const Duration(minutes: 1));
  });

  test('the wall clock moved backwards keeps the lock (capped at 15 min)', () {
    final l = make();
    lockNow(l);
    clock = clock.subtract(const Duration(hours: 3));
    expect(l.remaining(), isNotNull);
    // A fresh process (no monotonic memory) sees only the file: still locked,
    // and not for hours.
    final fresh = make().remaining();
    expect(fresh, isNotNull);
    expect(fresh! <= LoginLock.maxLock, isTrue);
  });

  test('describe', () {
    expect(LoginLock.describe(const Duration(seconds: 30)), '30 s');
    expect(LoginLock.describe(const Duration(minutes: 1)), '1 min');
    expect(LoginLock.describe(const Duration(seconds: 61)), '2 min');
  });
}
