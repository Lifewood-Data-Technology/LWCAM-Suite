import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/project.dart';
import 'package:lwcam/services/password_hasher.dart';
import 'package:lwcam/services/user_directory_service.dart';
import 'package:lwcam/services/users_store_service.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart' show ServerException;

/// A PG server error with just a SQLSTATE (the real class has no public
/// constructor).
class _FakeServerError implements ServerException {
  _FakeServerError(this.code);
  @override
  final String? code;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Test double for the PG write whitelist — [UserDirectoryService]'s real
/// implementation needs a live connection, so this overrides its public
/// surface instead of touching the network.
class FakeUserDirectoryService implements UserDirectoryService {
  bool reachable = true;

  /// What the database function answers (false = old password not accepted).
  bool accept = true;
  Object? changePasswordError;
  final List<({String user, String old, String hash})> calls = [];
  final List<String> changedPasswords = [];
  final List<String> recordedLogins = [];
  final List<String> markedProjects = [];

  @override
  Future<bool> isReachable() async => reachable;

  /// Runs inside the PG call, so a test can observe what is held while it is
  /// in flight (the real call costs up to a 5s connect timeout).
  void Function()? onChangePassword;

  @override
  Future<bool> changePassword({
    required String username,
    required String oldPassword,
    required String bcryptHash,
  }) async {
    onChangePassword?.call();
    if (!reachable) {
      throw StateError('Connect to the database to change your password.');
    }
    if (changePasswordError != null) throw changePasswordError!;
    calls.add((user: username, old: oldPassword, hash: bcryptHash));
    if (!accept) return false;
    changedPasswords.add(username);
    return true;
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
    Future<UsersStoreService> forced() async {
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
      return svc;
    }

    test('a database without the function or the right to call it answers '
        'needsDbUpdate, not an error that locks the user out', () async {
      final svc = await forced();
      for (final code in ['42883', '42501']) {
        directory.changePasswordError = _FakeServerError(code);
        expect(await svc.changeOwnPassword('alice', 'Temp1234', 'BrandNew99'),
            PasswordChangeResult.needsDbUpdate,
            reason: code);
      }
      directory.changePasswordError = _FakeServerError('23505');
      await expectLater(
          svc.changeOwnPassword('alice', 'Temp1234', 'BrandNew99'), throwsA(anything));
    });

    test('calls the database function with the old password and a bcrypt hash of the new one', () async {
      final svc = await forced();
      final result = await svc.changeOwnPassword('alice', 'Temp1234', 'BrandNew99');

      expect(result, PasswordChangeResult.changed);
      expect(directory.calls.single.user, 'alice');
      expect(directory.calls.single.old, 'Temp1234');
      expect(directory.calls.single.hash, isNot('BrandNew99'));
      expect(PasswordHasher.verify('BrandNew99', directory.calls.single.hash), isTrue);
      expect((await svc.authenticate('alice', 'BrandNew99')).status, AuthStatus.ok);
      expect((await svc.authenticate('alice', 'Temp1234')).status, AuthStatus.wrongPassword);

      // Survives a reload from disk - the local mirror was updated too.
      final fresh = makeService();
      await fresh.load();
      expect((await fresh.authenticate('alice', 'BrandNew99')).status, AuthStatus.ok);
    });

    test('the database refusing (false) leaves the local snapshot unchanged', () async {
      final svc = await forced();
      directory.accept = false;
      final result = await svc.changeOwnPassword('alice', 'WrongOld1', 'BrandNew99');

      expect(result, PasswordChangeResult.wrongCurrent);
      expect(directory.calls, hasLength(1));
      expect((await svc.authenticate('alice', 'Temp1234')).status, AuthStatus.mustChangePassword);
      expect((await svc.authenticate('alice', 'BrandNew99')).status, AuthStatus.wrongPassword);
      final fresh = makeService();
      await fresh.load();
      expect((await fresh.authenticate('alice', 'Temp1234')).status, AuthStatus.mustChangePassword);
    });

    test('offline: refused, nothing queued or written, no plaintext on disk', () async {
      final svc = await forced();
      final before = await File(p.join(storeDir.path, UsersStoreService.usersFileName)).readAsString();
      directory.reachable = false;
      final result = await svc.changeOwnPassword('alice', 'Temp1234', 'BrandNew99');

      expect(result, PasswordChangeResult.offline);
      expect(directory.changedPasswords, isEmpty);
      expect((await svc.authenticate('alice', 'Temp1234')).status, AuthStatus.mustChangePassword);
      expect((await svc.authenticate('alice', 'BrandNew99')).status, AuthStatus.wrongPassword);

      final files = storeDir.listSync().whereType<File>().map((f) => p.basename(f.path)).toList();
      expect(files, [UsersStoreService.usersFileName]);
      final after = await File(p.join(storeDir.path, UsersStoreService.usersFileName)).readAsString();
      expect(after, before);
      expect(after, isNot(contains('BrandNew99')));
      expect(after, isNot(contains('Temp1234')));
    });

    test('a database error other than unreachable propagates and changes nothing', () async {
      final svc = await forced();
      directory.changePasswordError = Exception('permission denied');
      await expectLater(svc.changeOwnPassword('alice', 'Temp1234', 'BrandNew99'), throwsException);
      expect((await svc.authenticate('alice', 'Temp1234')).status, AuthStatus.mustChangePassword);
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
      await svc.changeOwnPassword('offline-created', 'x', 'BrandNew99');

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
      );

      final onDisk = await File(path).readAsString();
      expect(onDisk, contains('admin'));
    });
  });

  group('retired pending-password queue file', () {
    test('an old queue file is deleted on a pull and its hashes are never applied', () async {
      final svc = await seeded();
      final queue = File(p.join(storeDir.path, 'lwcam_pending_password_changes.json'));
      await queue.writeAsString(jsonEncode({'admin': PasswordHasher.hash('Queued1')}));

      await svc.applySnapshot(UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [makeUser('admin', 'adminpass')],
      ));

      expect(await queue.exists(), isFalse);
      expect(directory.changedPasswords, isEmpty);
      expect((await svc.authenticate('admin', 'adminpass')).status, AuthStatus.ok);
      expect((await svc.authenticate('admin', 'Queued1')).status, AuthStatus.wrongPassword);
    });

    test('a corrupt queue file is also removed, without throwing', () async {
      final queue = File(p.join(storeDir.path, 'lwcam_pending_password_changes.json'));
      await queue.writeAsString('not json');
      await UsersStoreService.writeSnapshotFile(
        UsersStore(updatedAt: DateTime.now(), updatedBy: 'x', users: [makeUser('admin', 'a')]),
        p.join(storeDir.path, UsersStoreService.usersFileName),
      );
      expect(await queue.exists(), isFalse);
    });
  });

  group('cross-process lock (Fix 6)', () {
    test('the lock file is created and released around a write', () async {
      final svc = await seeded();
      final lockFile = File(
        '${p.join(storeDir.path, UsersStoreService.usersFileName)}.lock',
      );
      await svc.changeOwnPassword('admin', 'adminpass', 'NewPass1');
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

      await svc.changeOwnPassword('admin', 'adminpass', 'NewPass1');

      expect(await lockFile.exists(), isFalse);
      expect(
        (await svc.authenticate('admin', 'NewPass1')).status,
        AuthStatus.ok,
      );
    });
  });

  // The lock's stale grace is 30s with no heartbeat; a slow PG call made while
  // holding it lets LWCam Admin delete it as stale and both processes write
  // lwcam_users.json at once - precisely what the lock exists to prevent.
  group('the shared lock is never held across a PG call', () {
    test('changeOwnPassword calls the database before taking the lock', () async {
      final svc = await seeded();
      final lockFile = File(
        '${p.join(storeDir.path, UsersStoreService.usersFileName)}.lock',
      );
      var heldDuringPgCall = false;
      directory.onChangePassword = () {
        if (lockFile.existsSync()) heldDuringPgCall = true;
      };

      await svc.changeOwnPassword('admin', 'adminpass', 'Queued1');

      expect(directory.changedPasswords, ['admin']);
      expect(heldDuringPgCall, isFalse);
      expect(await lockFile.exists(), isFalse);
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
