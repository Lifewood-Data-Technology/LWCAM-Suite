import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/project.dart';
import 'package:lwcam/services/password_hasher.dart';
import 'package:lwcam/services/user_directory_service.dart';
import 'package:lwcam/services/users_store_service.dart';
import 'package:path/path.dart' as p;

/// Test double for the PG write whitelist — [UserDirectoryService]'s real
/// implementation needs a live connection, so this overrides its public
/// surface instead of touching the network.
class FakeUserDirectoryService implements UserDirectoryService {
  bool reachable = true;
  Object? changePasswordError;
  final List<String> changedPasswords = [];
  final List<String> recordedLogins = [];
  final List<String> markedProjects = [];

  @override
  Future<bool> isReachable() async => reachable;

  /// Runs inside the PG call, so a test can observe what is held while it is
  /// in flight (the real call costs up to a 5s connect timeout).
  void Function()? onChangePassword;

  @override
  Future<void> changePassword({required String username, required String bcryptHash}) async {
    onChangePassword?.call();
    if (!reachable) {
      throw StateError('Connect to the sync database to change your password.');
    }
    if (changePasswordError != null) throw changePasswordError!;
    changedPasswords.add(username);
  }

  @override
  Future<void> recordLogin(String username) async {
    if (reachable) recordedLogins.add(username);
  }

  @override
  Future<void> markProjectHasData(String projectKey) async {
    if (reachable) markedProjects.add(projectKey);
  }
}

void main() {
  late Directory storeDir;
  late FakeUserDirectoryService directory;

  UsersStoreService makeService() => UsersStoreService(
        getStorePath: () => p.join(storeDir.path, UsersStoreService.usersFileName),
        directory: directory,
      );

  setUp(() async {
    storeDir = await Directory.systemTemp.createTemp('users_snapshot_');
    directory = FakeUserDirectoryService();
  });

  tearDown(() async {
    if (await storeDir.exists()) await storeDir.delete(recursive: true);
  });

  /// Writes a snapshot file directly — user/project creation is LWCam
  /// Admin's job (PG first, then this JSON snapshot); LWCAM only reads it
  /// plus the tiny PG write whitelist this file tests (authenticate,
  /// changeOwnPassword, recordLogin, markProjectHasData).
  Future<void> seedStore(UsersStore store) async {
    final file = File(p.join(storeDir.path, UsersStoreService.usersFileName));
    await file.writeAsString(jsonEncode(store.toJson()), flush: true);
  }

  AppUser makeUser(String username, String password, {Set<UserRole> roles = const {UserRole.admin}}) {
    return AppUser(
      username: username,
      passwordHash: PasswordHasher.hash(password),
      roles: roles,
      active: true,
      mustChangePassword: false,
    );
  }

  Future<UsersStoreService> seeded() async {
    await seedStore(UsersStore(
      updatedAt: DateTime.now(),
      updatedBy: 'test',
      users: [makeUser('admin', 'adminpass')],
    ));
    final svc = makeService();
    await svc.load();
    return svc;
  }

  group('load / sources', () {
    test('reads an existing snapshot file', () async {
      await seedStore(UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'test',
        users: [makeUser('admin', 'adminpass')],
      ));
      final svc = makeService();
      final res = await svc.load();
      expect(res.source, UsersStoreSource.snapshot);
      expect(res.store!.users.single.username, 'admin');
    });

    test('no file yet → none', () async {
      final svc = makeService();
      final res = await svc.load();
      expect(res.source, UsersStoreSource.none);
      expect(res.store, isNull);
    });

    test('torn (empty) file → none', () async {
      await seeded();
      await File(p.join(storeDir.path, UsersStoreService.usersFileName)).writeAsString('');
      final svc = makeService();
      final res = await svc.load();
      expect(res.source, UsersStoreSource.none);
    });
  });

  group('authenticate', () {
    test('noStore when nothing loaded', () async {
      final svc = makeService();
      expect((await svc.authenticate('admin', 'x')).status, AuthStatus.noStore);
    });

    test('ok / wrongPassword / unknownUser', () async {
      final svc = await seeded();
      expect((await svc.authenticate('admin', 'adminpass')).status, AuthStatus.ok);
      expect((await svc.authenticate('admin', 'nope')).status, AuthStatus.wrongPassword);
      expect((await svc.authenticate('ghost', 'x')).status, AuthStatus.unknownUser);
    });

    test('inactive users are rejected', () async {
      await seedStore(UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'test',
        users: [
          makeUser('admin', 'adminpass'),
          AppUser(
            username: 'cap',
            passwordHash: PasswordHasher.hash('Temp1234'),
            roles: const {UserRole.capture},
            deviceId: 'SAX02',
            active: false,
          ),
        ],
      ));
      final svc = makeService();
      await svc.load();
      expect((await svc.authenticate('cap', 'Temp1234')).status, AuthStatus.inactive);
    });

    test('mustChangePassword is surfaced for a forced-change account', () async {
      await seedStore(UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'test',
        users: [
          AppUser(
            username: 'alice',
            passwordHash: PasswordHasher.hash('Temp1234'),
            roles: const {UserRole.capture},
            deviceId: 'SAX01',
            active: true,
            mustChangePassword: true,
          ),
        ],
      ));
      final svc = makeService();
      await svc.load();
      final out = await svc.authenticate('alice', 'Temp1234');
      expect(out.status, AuthStatus.mustChangePassword);
    });
  });

  group('changeOwnPassword', () {
    test('PG-first: writes through the directory before touching the local copy', () async {
      await seedStore(UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'test',
        users: [
          AppUser(
            username: 'alice',
            passwordHash: PasswordHasher.hash('Temp1234'),
            roles: const {UserRole.capture},
            deviceId: 'SAX01',
            active: true,
            mustChangePassword: true,
          ),
        ],
      ));
      final svc = makeService();
      await svc.load();
      final queuedOffline = await svc.changeOwnPassword('alice', 'BrandNew99');

      expect(queuedOffline, isFalse);
      expect(directory.changedPasswords, ['alice']);
      expect((await svc.authenticate('alice', 'BrandNew99')).status, AuthStatus.ok);
      expect((await svc.authenticate('alice', 'Temp1234')).status, AuthStatus.wrongPassword);

      // Survives a reload from disk — the local mirror was updated too.
      final fresh = makeService();
      await fresh.load();
      expect((await fresh.authenticate('alice', 'BrandNew99')).status, AuthStatus.ok);
    });

    test('when PG is unreachable, the change is queued locally instead of '
        'blocking — some sites are permanently offline', () async {
      final svc = await seeded();
      directory.reachable = false;
      final queuedOffline = await svc.changeOwnPassword('admin', 'BrandNew99');

      expect(queuedOffline, isTrue);
      expect(directory.changedPasswords, isEmpty);
      // Logs in with the new password THIS session, immediately.
      expect((await svc.authenticate('admin', 'BrandNew99')).status, AuthStatus.ok);

      // And survives a reload from disk — the local mirror was updated too.
      final fresh = makeService();
      await fresh.load();
      expect((await fresh.authenticate('admin', 'BrandNew99')).status, AuthStatus.ok);
    });

    test('ANY PG failure queues (a connection dying mid-execute is just '
        'connectivity in a costume) — the operator is never blocked', () async {
      final svc = await seeded();
      directory.changePasswordError = Exception('connection reset mid-execute');
      final queuedOffline = await svc.changeOwnPassword('admin', 'NewPass1');
      expect(queuedOffline, isTrue);
      expect((await svc.authenticate('admin', 'NewPass1')).status, AuthStatus.ok);

      // The retry delivers once the failure clears — idempotent even if the
      // original write actually committed before its response was lost.
      directory.changePasswordError = null;
      await svc.flushPendingPasswordChanges();
      expect(directory.changedPasswords, ['admin']);
    });
  });

  group('pending password changes (offline queue)', () {
    test('flushPendingPasswordChanges retries against PG and clears the '
        'queue on success', () async {
      final svc = await seeded();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'BrandNew99');
      expect(directory.changedPasswords, isEmpty);

      directory.reachable = true;
      await svc.flushPendingPasswordChanges();
      expect(directory.changedPasswords, ['admin']);

      // A second flush is a no-op — nothing left queued.
      await svc.flushPendingPasswordChanges();
      expect(directory.changedPasswords, ['admin']);
    });

    test('flushPendingPasswordChanges is a no-op (never throws) with '
        'nothing queued or no store loaded', () async {
      final svc = makeService();
      await svc.flushPendingPasswordChanges(); // no store loaded yet
      final seededSvc = await seeded();
      await seededSvc.flushPendingPasswordChanges(); // nothing pending
      expect(directory.changedPasswords, isEmpty);
    });

    test('applySnapshot never reverts a still-pending offline password '
        'change — a pull must not silently undo it', () async {
      final svc = await seeded();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'BrandNew99');

      // A sync pull lands with PG's (stale) copy of the user, still on the
      // old hash — applying it must not overwrite the newer local change.
      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('admin', 'adminpass')], // stale: old password
      );
      await svc.applySnapshot(pulled);

      expect((await svc.authenticate('admin', 'BrandNew99')).status, AuthStatus.ok);
      expect((await svc.authenticate('admin', 'adminpass')).status, AuthStatus.wrongPassword);
    });

    test('applySnapshot flushes a pending change once reachable and clears '
        'the queue', () async {
      final svc = await seeded();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'BrandNew99');

      directory.reachable = true;
      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('admin', 'adminpass')],
      );
      await svc.applySnapshot(pulled);

      expect(directory.changedPasswords, ['admin']);
      expect((await svc.authenticate('admin', 'BrandNew99')).status, AuthStatus.ok);

      // Queue is clear — a later pull with the (now-correct) hash no longer
      // needs to splice anything.
      final finalPull = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('admin', 'BrandNew99')],
      );
      await svc.applySnapshot(finalPull);
      expect(directory.changedPasswords, ['admin']); // not called again
    });

    test('writeSnapshotFile (the pre-login static variant) also reconciles '
        'a pending change from a prior session', () async {
      final path = p.join(storeDir.path, UsersStoreService.usersFileName);
      await UsersStoreService.writeSnapshotFile(
        UsersStore(updatedAt: DateTime.now(), updatedBy: 'test', users: [makeUser('admin', 'adminpass')]),
        path,
      );
      final svc = makeService();
      await svc.load();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'BrandNew99');

      // Simulate the pre-login startup tick: a stale pull writes straight
      // through the static path (no live instance around this time).
      directory.reachable = true;
      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('admin', 'adminpass')],
      );
      await UsersStoreService.writeSnapshotFile(pulled, path, directory: directory);
      expect(directory.changedPasswords, ['admin']);

      final reloaded = makeService();
      final res = await reloaded.load();
      expect((await reloaded.authenticate('admin', 'BrandNew99')).status, AuthStatus.ok);
      expect(res.source, UsersStoreSource.snapshot);
    });
  });

  group('recordLogin', () {
    test('delegates to the directory and never throws even when unreachable', () async {
      final svc = makeService();
      directory.reachable = false;
      await svc.recordLogin('admin'); // must not throw
      expect(directory.recordedLogins, isEmpty);

      directory.reachable = true;
      await svc.recordLogin('admin');
      expect(directory.recordedLogins, ['admin']);
    });
  });

  group('markProjectHasData', () {
    test('delegates to the directory and never throws even when unreachable', () async {
      final svc = makeService();
      directory.reachable = false;
      await svc.markProjectHasData(projectKey: 'p1'); // must not throw
      expect(directory.markedProjects, isEmpty);

      directory.reachable = true;
      await svc.markProjectHasData(projectKey: 'p1');
      expect(directory.markedProjects, ['p1']);
    });
  });

  group('shared-file protection (LWCam Admin offline edits)', () {
    /// Simulates LWCam Admin's offline-edit state in the SHARED file:
    /// dirty=true plus a queued tombstone — keys LWCAM has no model for.
    Future<void> seedDirtyAdminStore() async {
      final store = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'SuperAdmin',
        users: [makeUser('offline-created', 'Temp1234')],
      );
      final json = store.toJson();
      json['dirty'] = true;
      json['deletedUsernames'] = ['ghost'];
      final file = File(p.join(storeDir.path, UsersStoreService.usersFileName));
      await file.writeAsString(jsonEncode(json), flush: true);
    }

    test('applySnapshot refuses to overwrite a dirty file — a pull must '
        'never destroy LWCam Admin\'s unpushed edits/tombstones', () async {
      await seedDirtyAdminStore();
      final svc = makeService();
      await svc.load();

      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('someone-else', 'x')],
      );
      await svc.applySnapshot(pulled);

      // The admin's copy stays both on disk and as the live store.
      expect(svc.lastLoaded!.findUser('offline-created'), isNotNull);
      expect(svc.lastLoaded!.findUser('someone-else'), isNull);
      final onDisk = await File(
              p.join(storeDir.path, UsersStoreService.usersFileName))
          .readAsString();
      expect(onDisk, contains('"dirty":true'));
      expect(onDisk, contains('ghost'));
    });

    test('the static writeSnapshotFile applies the same guard', () async {
      await seedDirtyAdminStore();
      final path = p.join(storeDir.path, UsersStoreService.usersFileName);
      await UsersStoreService.writeSnapshotFile(
        UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull'),
        path,
        directory: directory,
      );
      final onDisk = await File(path).readAsString();
      expect(onDisk, contains('"dirty":true'));
      expect(onDisk, contains('offline-created'));
    });

    test('LWCAM\'s own local rewrite (changeOwnPassword mirror) round-trips '
        'the admin-only keys instead of stripping them', () async {
      await seedDirtyAdminStore();
      final svc = makeService();
      await svc.load();
      directory.reachable = false;
      await svc.changeOwnPassword('offline-created', 'BrandNew99');

      final onDisk = await File(
              p.join(storeDir.path, UsersStoreService.usersFileName))
          .readAsString();
      expect(onDisk, contains('"dirty":true')); // preserved opaquely
      expect(onDisk, contains('ghost'));
      expect((await svc.authenticate('offline-created', 'BrandNew99')).status,
          AuthStatus.ok);
    });

    test('a clean (non-dirty) file is overwritten normally by the pull', () async {
      final svc = await seeded();
      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('fresh', 'x')],
      );
      await svc.applySnapshot(pulled);
      expect(svc.lastLoaded!.findUser('fresh'), isNotNull);
      expect(svc.lastLoaded!.findUser('admin'), isNull);
    });
  });

  group('projects getter', () {
    test('exposes the catalog from the last successful load', () async {
      final project = Project(
        key: 'p1',
        projectId: 'PRJ-1',
        name: 'A',
        countryLocationCode: 'LOC-PRJ-1',
        startDate: DateTime(2026, 1, 1),
      );
      await seedStore(UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'test',
        users: [makeUser('admin', 'adminpass')],
        projects: [project],
      ));
      final svc = makeService();
      await svc.load();
      expect(svc.projects.map((p) => p.projectId), contains('PRJ-1'));
    });
  });

  group('empty-pull guard (Fix 3)', () {
    test('applySnapshot keeps the existing snapshot when the pulled store '
        'has zero users — an empty cloud users table must not wipe local '
        'accounts', () async {
      final svc = await seeded();
      final emptyPull = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: const [],
      );
      await svc.applySnapshot(emptyPull);

      expect(svc.lastLoaded!.findUser('admin'), isNotNull);
      final onDisk = await File(
        p.join(storeDir.path, UsersStoreService.usersFileName),
      ).readAsString();
      expect(onDisk, contains('admin'));
    });

    test('an empty pull applies normally when there is no existing snapshot '
        '(fresh station — nothing to protect)', () async {
      final svc = makeService();
      final emptyPull = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: const [],
      );
      await svc.applySnapshot(emptyPull);

      expect(svc.lastSource, UsersStoreSource.snapshot);
      expect(svc.lastLoaded!.users, isEmpty);
    });

    test('writeSnapshotFile (static variant) keeps an existing on-disk '
        'snapshot when the pulled store is empty', () async {
      final path = p.join(storeDir.path, UsersStoreService.usersFileName);
      await UsersStoreService.writeSnapshotFile(
        UsersStore(
          updatedAt: DateTime.now(),
          updatedBy: 'seed',
          users: [makeUser('admin', 'adminpass')],
        ),
        path,
      );
      final emptyPull = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: const [],
      );
      await UsersStoreService.writeSnapshotFile(
        emptyPull,
        path,
        directory: directory,
      );

      final onDisk = await File(path).readAsString();
      expect(onDisk, contains('admin'));
    });
  });

  group('pending hash cleared on success (Fix 5)', () {
    test('a successful direct change clears any earlier queued hash so it '
        'cannot later replay over the newer password', () async {
      final svc = await seeded();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'StaleQueued1');
      expect(directory.changedPasswords, isEmpty); // queued, not sent

      directory.reachable = true;
      await svc.changeOwnPassword('admin', 'FreshDirect2');
      expect(directory.changedPasswords, ['admin']); // exactly one direct write

      // The stale queued hash must be gone — a flush must not resend it.
      await svc.flushPendingPasswordChanges();
      expect(directory.changedPasswords, ['admin']);
      expect(
        (await svc.authenticate('admin', 'FreshDirect2')).status,
        AuthStatus.ok,
      );
    });
  });

  group('cross-process lock (Fix 6)', () {
    test('the lock file is created and released around a write', () async {
      final svc = await seeded();
      final lockFile = File(
        '${p.join(storeDir.path, UsersStoreService.usersFileName)}.lock',
      );
      await svc.changeOwnPassword('admin', 'NewPass1');
      expect(await lockFile.exists(), isFalse);
    });

    test('a stale lock past the grace period is cleared instead of wedging '
        'the write forever', () async {
      final svc = await seeded();
      final lockFile = File(
        '${p.join(storeDir.path, UsersStoreService.usersFileName)}.lock',
      );
      await lockFile.writeAsString('999999@stale');
      await lockFile.setLastModified(
        DateTime.now().subtract(const Duration(seconds: 40)),
      );

      await svc.changeOwnPassword('admin', 'NewPass1');

      expect(await lockFile.exists(), isFalse);
      expect(
        (await svc.authenticate('admin', 'NewPass1')).status,
        AuthStatus.ok,
      );
    });
  });

  // Each queued entry costs up to a 5s PG connect timeout, and the lock's
  // stale grace is 30s with no heartbeat. Retrying ~7 of them under the lock
  // pushed the hold past the grace period, at which point LWCam Admin deletes
  // it as stale and both processes write lwcam_users.json at once — precisely
  // what the lock exists to prevent.
  group('the shared lock is never held across a PG call (Fix 7)', () {
    late File lockFile;

    setUp(() {
      lockFile = File(
        '${p.join(storeDir.path, UsersStoreService.usersFileName)}.lock',
      );
    });

    test('flushPendingPasswordChanges retries outside the lock', () async {
      final svc = await seeded();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'Queued1'); // queues offline

      var heldDuringPgCall = false;
      directory
        ..reachable = true
        ..onChangePassword = () {
          if (lockFile.existsSync()) heldDuringPgCall = true;
        };

      await svc.flushPendingPasswordChanges();

      expect(directory.changedPasswords, contains('admin'));
      expect(
        heldDuringPgCall,
        isFalse,
        reason: 'the PG retry must run before the lock is taken',
      );
      expect(await lockFile.exists(), isFalse);
    });

    test('applySnapshot reconciles outside the lock too', () async {
      final svc = await seeded();
      directory.reachable = false;
      await svc.changeOwnPassword('admin', 'Queued1');

      var heldDuringPgCall = false;
      directory
        ..reachable = true
        ..onChangePassword = () {
          if (lockFile.existsSync()) heldDuringPgCall = true;
        };

      await svc.applySnapshot(
        UsersStore(
          updatedAt: DateTime.now(),
          updatedBy: 'pg-pull',
          users: [makeUser('admin', 'stale-hash')],
        ),
      );

      expect(directory.changedPasswords, contains('admin'));
      expect(heldDuringPgCall, isFalse);
      // And the queued hash still wins over the stale pulled one.
      expect(
        (await svc.authenticate('admin', 'Queued1')).status,
        AuthStatus.ok,
      );
    });
  });

  group('applySnapshot', () {
    test('overwrites the local file and swaps in the pulled store', () async {
      final svc = makeService();
      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('alice', 'x')],
      );
      await svc.applySnapshot(pulled);
      expect(svc.lastLoaded!.users.single.username, 'alice');
      expect(svc.lastSource, UsersStoreSource.snapshot);

      final reloaded = makeService();
      await reloaded.load();
      expect(reloaded.lastLoaded!.users.single.username, 'alice');
    });
  });

  group('writeSnapshotFile', () {
    test('the static pre-login variant writes a file a later load() reads back', () async {
      final path = p.join(storeDir.path, UsersStoreService.usersFileName);
      final pulled = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('bob', 'x')],
      );
      await UsersStoreService.writeSnapshotFile(pulled, path);

      final svc = makeService();
      final res = await svc.load();
      expect(res.source, UsersStoreSource.snapshot);
      expect(res.store!.users.single.username, 'bob');
    });
  });
}
