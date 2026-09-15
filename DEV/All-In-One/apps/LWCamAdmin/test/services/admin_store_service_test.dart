import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/app_user.dart';
import 'package:lwcam_admin/services/admin_pg_gateway.dart';
import 'package:lwcam_admin/services/admin_store_service.dart';

import 'fake_admin_gateway.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  late Directory dir;
  late FakeAdminGateway gateway;

  Future<AdminStoreService> makeService() async {
    dir = await _tempDir('admin_store_');
    gateway = FakeAdminGateway();
    return AdminStoreService(gateway: gateway, getStoreDirPath: () => dir.path);
  }

  group('init', () {
    test('first run with no local file creates an empty store, then reconciles', () async {
      final svc = await makeService();
      gateway.pullResult = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [
          AppUser(username: 'admin', passwordHash: 'h', roles: const {UserRole.admin}),
        ],
      );
      await svc.init();
      expect(svc.online.value, isTrue);
      expect(svc.store.value!.users.single.username, 'admin');
      expect(await File('${dir.path}/${AdminStoreService.fileName}').exists(), isTrue);
    });

    test('an existing local file is read before reconciling', () async {
      final first = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await first.init(); // creates the empty file, offline
      final file = File('${dir.path}/${AdminStoreService.fileName}');
      expect(await file.exists(), isTrue);
    });
  });

  group('trySync', () {
    test('unreachable ⇒ online=false, store unchanged', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      expect(svc.online.value, isFalse);
      expect(gateway.pullCallCount, 0);
    });

    test('schemaOutdated ⇒ online=false, schemaOutdated=true, no push/pull attempted', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.schemaOutdated);
      await svc.init();
      expect(svc.online.value, isFalse);
      expect(svc.schemaOutdated.value, isTrue);
      expect(gateway.pullCallCount, 0);
    });

    test('reachable + not dirty ⇒ pulls and writes clean', () async {
      final svc = await makeService();
      gateway.pullResult = UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull');
      await svc.init();
      expect(svc.online.value, isTrue);
      expect(svc.dirty.value, isFalse);
      expect(gateway.pullCallCount, 1);
    });

    test('pgConnectionEnabled=false skips the network entirely — never even '
        'probes, straight to the offline branch', () async {
      dir = await _tempDir('admin_store_');
      gateway = FakeAdminGateway();
      final svc = AdminStoreService(
        gateway: gateway,
        getStoreDirPath: () => dir.path,
        pgConnectionEnabled: false,
      );
      await svc.init();
      expect(svc.online.value, isFalse);
      expect(svc.schemaOutdated.value, isFalse);
      expect(gateway.probeCallCount, 0);
      expect(gateway.pullCallCount, 0);

      // Edits still work — same offline queueing as a real unreachable PG.
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'SuperAdmin');
      expect(svc.dirty.value, isTrue);
      expect(gateway.probeCallCount, 0); // still never touched
    });

    test('a push failure keeps the store dirty and skips the pull entirely '
        '(never treats stale PG data as canonical over undelivered edits)', () async {
      final svc = await makeService();
      // First bring it online+dirty via an offline mutation, then flip
      // reachable with a failing push.
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setMetadataKeyingEnabled(enabled: true, by: 'admin');
      expect(svc.dirty.value, isTrue);

      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.reachable);
      gateway.pushError = Exception('boom');
      final ok = await svc.trySync();
      expect(ok, isFalse);
      expect(svc.dirty.value, isTrue); // never cleared
      expect(gateway.pullCallCount, 0); // pull never attempted
    });
  });

  group('offline mutations', () {
    test('an edit made offline is allowed, marks dirty, and survives in the '
        'written JSON', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();

      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'SuperAdmin');
      await svc.createUser(username: 'alice', roles: {UserRole.capture}, deviceId: 'SAX01', by: 'SuperAdmin');

      expect(svc.dirty.value, isTrue);
      expect(svc.store.value!.findUser('alice'), isNotNull);

      final onDisk = await File('${dir.path}/${AdminStoreService.fileName}').readAsString();
      expect(onDisk, contains('alice'));
      expect(onDisk, contains('"dirty":true'));
    });

    test('a delete made offline records a tombstone', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'SuperAdmin');
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      await svc.deleteUser(username: 'alice', by: 'SuperAdmin');

      expect(svc.store.value!.findUser('alice'), isNull);
      expect(svc.store.value!.deletedUsernames, contains('alice'));
    });

    test('recreating a deleted username drops the queued tombstone — the '
        'push must never soft-delete the recreated account', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'SuperAdmin');
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      await svc.deleteUser(username: 'alice', by: 'SuperAdmin');
      expect(svc.store.value!.deletedUsernames, contains('alice'));

      await svc.createUser(username: 'Alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      expect(svc.store.value!.findUser('alice'), isNotNull);
      expect(svc.store.value!.deletedUsernames, isEmpty); // case-insensitive drop
      // The revive path relies on the targeted password reset, since the
      // upsert's DO UPDATE never touches password columns.
      expect(svc.store.value!.pendingPasswordResets.map((u) => u.toLowerCase()),
          contains('alice'));
    });

    test('resetPassword queues a pending targeted write, and the push '
        'carries it', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'SuperAdmin');
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      await svc.resetPassword(username: 'alice', by: 'SuperAdmin');
      expect(svc.store.value!.pendingPasswordResets, contains('alice'));

      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.reachable);
      gateway.pullResult = UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull');
      final ok = await svc.trySync();
      expect(ok, isTrue);
      expect(gateway.pushedSnapshots.single.pendingPasswordResets, contains('alice'));
      // Cleared by the pull that follows the successful push.
      expect(svc.store.value!.pendingPasswordResets, isEmpty);
    });

    test('reconnecting pushes the dirty snapshot (incl. tombstones) then '
        'clears dirty on the pulled result', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'SuperAdmin');
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      await svc.createUser(username: 'bob', roles: {UserRole.admin}, by: 'SuperAdmin');
      await svc.deleteUser(username: 'bob', by: 'SuperAdmin');
      expect(svc.dirty.value, isTrue);
      expect(svc.store.value!.deletedUsernames, contains('bob'));

      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.reachable);
      gateway.pullResult = UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull', users: [
        AppUser(username: 'alice', passwordHash: 'h', roles: const {UserRole.admin}),
      ]);
      final ok = await svc.trySync();
      expect(ok, isTrue);
      expect(svc.dirty.value, isFalse);
      expect(gateway.pushedSnapshots, hasLength(1));
      expect(gateway.pushedSnapshots.single.users.any((u) => u.username == 'alice'), isTrue);
      expect(gateway.pushedSnapshots.single.deletedUsernames, contains('bob'));
    });
  });

  group('online mutations', () {
    test('pulls before applying the transform (stale-clobber guard)', () async {
      final svc = await makeService();
      await svc.init(); // online, empty store pulled
      gateway.pullResult = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        settings: const SharedAppSettings(defaultTempPasswordHash: 'existingHash'),
      );
      // createUser requires a default temp password to already exist in PG —
      // proving _mutate re-synced before applying the transform.
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      expect(gateway.pushedSnapshots.single.users.single.username, 'alice');
    });

    test('a successful online mutation pushes then pulls, ending clean', () async {
      final svc = await makeService();
      gateway.pullResult =
          UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull', settings: const SharedAppSettings(defaultTempPasswordHash: 'h'));
      await svc.init();
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      expect(svc.dirty.value, isFalse);
      expect(gateway.pullCallCount, greaterThanOrEqualTo(2)); // init + post-push
    });

    test('a push failure mid-mutation degrades to the offline branch (dirty, '
        'change still applied locally)', () async {
      final svc = await makeService();
      gateway.pullResult =
          UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull', settings: const SharedAppSettings(defaultTempPasswordHash: 'h'));
      await svc.init();
      gateway.pushError = Exception('network dropped mid-push');
      await svc.createUser(username: 'alice', roles: {UserRole.admin}, by: 'SuperAdmin');
      expect(svc.dirty.value, isTrue);
      expect(svc.online.value, isFalse);
      expect(svc.store.value!.findUser('alice'), isNotNull);
    });
  });

  group('validation', () {
    // Run offline so each applied transform's result is what's kept — an
    // online mutation's outcome is whatever the (static, in these tests)
    // fake pull returns, which would mask the very state these checks need
    // to see across two calls.
    test('device id must be unique across users', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'a');
      await svc.createUser(username: 'alice', roles: {UserRole.capture}, deviceId: 'SAX01', by: 'a');
      expect(
        () => svc.createUser(username: 'bob', roles: {UserRole.capture}, deviceId: 'SAX01', by: 'a'),
        throwsStateError,
      );
    });

    // The Device ID is interpolated into `lwcam_stats_<id>.db` and into every
    // captured image's file name with no sanitising, so the format rule is a
    // data-loss guard, not cosmetics. It is no longer locked to SAX##.
    test('device id is stored upper case, whatever case was typed', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'a');
      await svc.createUser(
          username: 'alice', roles: {UserRole.capture}, deviceId: ' mytp01 ', by: 'a');
      expect(svc.store.value!.users.single.deviceId, 'MYTP01');
    });

    test('a site-shaped device id is accepted, SAX## is no longer required', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'a');
      await svc.createUser(
          username: 'alice', roles: {UserRole.capture}, deviceId: 'MYTP01', by: 'a');
      await svc.createUser(
          username: 'bob', roles: {UserRole.capture}, deviceId: 'SAX01', by: 'a');
      expect(svc.store.value!.users.map((u) => u.deviceId), containsAll(['MYTP01', 'SAX01']));
    });

    test('a device id that would break the database file name is rejected', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'a');
      // Each of these lands in `lwcam_stats_<id>.db`: a separator escapes the
      // folder, a colon is an NTFS stream, a space and a dot are just wrong.
      for (final bad in [r'MY\TP', 'MY/TP', 'MY:TP', 'MY TP', 'MY.TP', 'M', '_MYTP']) {
        expect(
          () => svc.createUser(
              username: 'u$bad', roles: {UserRole.capture}, deviceId: bad, by: 'a'),
          throwsStateError,
          reason: '"$bad" must not reach a file name',
        );
      }
    });

    // A legacy id reaches the store through a PG pull, which does not validate.
    // Re-checking the FORMAT of an id the admin never touched made those
    // accounts uneditable outright - roles, projects, even deactivating them.
    test('an unchanged legacy device id does not block editing the account',
        () async {
      final svc = await makeService();
      gateway.pullResult = UsersStore(
        updatedAt: DateTime.now(),
        updatedBy: 'pg-pull',
        users: [
          AppUser(
            username: 'alice',
            passwordHash: 'h',
            roles: const {UserRole.capture},
            deviceId: 'OLD STYLE ID',
            roleProjectKeys: const {
              UserRole.capture: {'k1'},
            },
          ),
        ],
      );
      await svc.init();
      // No deviceId passed: the stored one is carried over untouched.
      await svc.setRoles(
        username: 'alice',
        roles: {UserRole.capture},
        by: 'admin',
      );
      expect(svc.store.value!.findUser('alice')!.deviceId, 'OLD STYLE ID');
    });

    test('a capture account still cannot end up with no device id at all',
        () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.setDefaultTempPassword(plaintext: 'Temp1234', by: 'a');
      await svc.createUser(username: 'bob', roles: {UserRole.admin}, by: 'a');
      expect(
        () => svc.setRoles(
            username: 'bob', roles: {UserRole.capture}, by: 'a'),
        throwsStateError,
      );
    });

    test('project name must be unique', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      await svc.createProject(
          name: 'Archive', projectId: 'PRJ-1', countryLocationCode: 'PH-CEB',
          startDate: DateTime(2026, 1, 1), by: 'a');
      expect(
        () => svc.createProject(
            name: 'Archive', projectId: 'PRJ-2', countryLocationCode: 'PH-MNL',
            startDate: DateTime(2026, 1, 1), by: 'a'),
        throwsStateError,
      );
    });

    test('a "|" in the Project ID is rejected — it is the user_projects '
        'pair-encoding separator', () async {
      final svc = await makeService();
      gateway.nextProbe = const GatewayProbeResult(GatewayStatus.unreachable);
      await svc.init();
      expect(
        () => svc.createProject(
            name: 'Archive', projectId: 'PRJ|1', countryLocationCode: 'PH-CEB',
            startDate: DateTime(2026, 1, 1), by: 'a'),
        throwsStateError,
      );
    });

    test('reserved SuperAdmin username is rejected', () async {
      final svc = await makeService();
      gateway.pullResult =
          UsersStore(updatedAt: DateTime.now(), updatedBy: 'pg-pull', settings: const SharedAppSettings(defaultTempPasswordHash: 'h'));
      await svc.init();
      expect(
        () => svc.createUser(username: 'SuperAdmin', roles: {UserRole.admin}, by: 'a'),
        throwsStateError,
      );
    });
  });
}
