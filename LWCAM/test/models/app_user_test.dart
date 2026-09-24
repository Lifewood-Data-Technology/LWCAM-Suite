import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/project.dart';

void main() {
  group('UserRole', () {
    test('json round-trip and unknown tolerance', () {
      expect(UserRole.fromJson('admin'), UserRole.admin);
      expect(UserRole.fromJson('capture'), UserRole.capture);
      // 'rework' is LWRework's role, not one of LWCAM's — a foreign role
      // string on disk parses to null just like any other unknown value.
      expect(UserRole.fromJson('rework'), isNull);
      expect(UserRole.fromJson('superuser'), isNull);
      expect(UserRole.fromJson(null), isNull);
    });
  });

  group('AppUser role logic', () {
    test('admin alone grants NO capture (admins do not capture)', () {
      const u = AppUser(username: 'a', passwordHash: 'h', roles: {UserRole.admin});
      expect(u.isAdmin, isTrue);
      expect(u.canNormalMode, isFalse);
      expect(u.requiresDeviceId, isFalse);
    });

    test('capture requires a Device ID', () {
      const cap = AppUser(username: 'c', passwordHash: 'h', roles: {UserRole.capture});
      expect(cap.canNormalMode, isTrue);
      expect(cap.requiresDeviceId, isTrue);
    });

    test('admin + capture can both administer and capture', () {
      const u = AppUser(
        username: 'ac',
        passwordHash: 'h',
        roles: {UserRole.admin, UserRole.capture},
        deviceId: 'SAX07',
      );
      expect(u.isAdmin, isTrue);
      expect(u.canNormalMode, isTrue);
      expect(u.requiresDeviceId, isTrue);
      expect(u.deviceId, 'SAX07');
    });
  });

  group('AppUser JSON round-trip', () {
    test('preserves fields and ignores unknown roles', () {
      final u = AppUser(
        username: 'alice',
        passwordHash: r'$2b$10$abc',
        roles: {UserRole.capture},
        deviceId: 'SAX09',
        active: false,
        mustChangePassword: true,
        createdAt: DateTime(2026, 7, 9),
        createdBy: 'admin',
        lastLoginAt: DateTime(2026, 7, 9, 12),
        lastLoginDeviceId: 'SAX03',
        changeLog: const [],
      );
      final json = u.toJson();
      // Simulate unknown roles on disk: a future role, and 'rework' (a
      // foreign, LWRework-only role that could linger from a shared-store
      // era) — both must be dropped, not just a made-up value.
      (json['roles'] as List).addAll(<String>['ghost', 'rework']);

      final back = AppUser.fromJson(json);
      expect(back.username, 'alice');
      expect(back.passwordHash, r'$2b$10$abc');
      expect(back.roles, {UserRole.capture}); // 'ghost'/'rework' dropped
      expect(back.deviceId, 'SAX09');
      expect(back.active, isFalse);
      expect(back.mustChangePassword, isTrue);
      expect(back.lastLoginDeviceId, 'SAX03');
    });

    test('malformed user json degrades gracefully, never throws', () {
      final back = AppUser.fromJson(<String, Object?>{'username': 'x'});
      expect(back.username, 'x');
      expect(back.passwordHash, '');
      expect(back.roles, isEmpty);
      expect(back.active, isTrue);
    });
  });

  group('changeLog cap', () {
    test('withLogEntry trims to the most recent kUserChangeLogCap', () {
      var u = const AppUser(username: 'a', passwordHash: 'h', roles: {UserRole.admin});
      for (var i = 0; i < kUserChangeLogCap + 5; i++) {
        u = u.withLogEntry('action_$i', 'admin', at: DateTime(2026, 1, 1).add(Duration(minutes: i)));
      }
      expect(u.changeLog.length, kUserChangeLogCap);
      // Oldest entries dropped; the last one is the newest action.
      expect(u.changeLog.last.action, 'action_${kUserChangeLogCap + 4}');
      expect(u.changeLog.first.action, 'action_5');
    });
  });

  group('UsersStore', () {
    test('findUser is case-insensitive', () {
      const store = UsersStore(users: [
        AppUser(username: 'Alice', passwordHash: 'h', roles: {UserRole.capture}),
      ]);
      expect(store.findUser('alice')?.username, 'Alice');
      expect(store.findUser('  ALICE '.trim())?.username, 'Alice');
      expect(store.findUser('bob'), isNull);
    });

    test('store JSON round-trip preserves settings and users', () {
      final store = UsersStore(
        updatedAt: DateTime(2026, 7, 9),
        updatedBy: 'admin',
        settings: const SharedAppSettings(
          metadataKeyingEnabled: true,
          defaultTempPasswordHash: r'$2b$10$t',
          superAdminPasswordHash: r'$2b$10$s',
        ),
        users: const [AppUser(username: 'a', passwordHash: 'h', roles: {UserRole.admin})],
      );
      final back = UsersStore.fromJson(store.toJson());
      expect(back.schemaVersion, UsersStore.currentSchemaVersion);
      expect(back.settings.metadataKeyingEnabled, isTrue);
      expect(back.settings.defaultTempPasswordHash, r'$2b$10$t');
      expect(back.settings.superAdminPasswordHash, r'$2b$10$s');
      expect(back.users.single.username, 'a');
      expect(back.updatedBy, 'admin');
    });

    test('empty/absent settings default to keying disabled', () {
      final back = UsersStore.fromJson(<String, Object?>{'users': []});
      expect(back.settings.metadataKeyingEnabled, isFalse);
      expect(back.settings.superAdminPasswordHash, isNull);
      expect(back.users, isEmpty);
    });

    test('projects round-trip through JSON and default to empty', () {
      final store = UsersStore(projects: [
        Project(key: 'p1', projectId: 'PRJ-1', name: 'Alpha', startDate: DateTime(2026, 1, 1)),
        Project(key: 'p2', projectId: 'PRJ-2', name: 'Beta', startDate: DateTime(2026, 2, 1)),
      ]);
      final back = UsersStore.fromJson(store.toJson());
      expect(back.projects, hasLength(2));
      expect(back.projects.map((p) => p.projectId), containsAll(['PRJ-1', 'PRJ-2']));

      // Legacy JSON predating the Projects feature parses fine.
      final legacy = UsersStore.fromJson(<String, Object?>{'users': []});
      expect(legacy.projects, isEmpty);
    });

    test('findProjectByKey and findProjectById are exact/case-insensitive respectively', () {
      final store = UsersStore(projects: [
        Project(key: 'p1', projectId: 'PRJ-1', name: 'Alpha', startDate: DateTime(2026, 1, 1)),
      ]);
      expect(store.findProjectByKey('p1')?.name, 'Alpha');
      expect(store.findProjectByKey('nope'), isNull);
      expect(store.findProjectById('prj-1')?.name, 'Alpha');
      expect(store.findProjectById('  PRJ-1  '.trim())?.name, 'Alpha');
      expect(store.findProjectById('PRJ-2'), isNull);
    });
  });

  group('AppUser projectKeys', () {
    test('round-trips through JSON and defaults to empty on legacy records', () {
      const u = AppUser(
        username: 'a',
        passwordHash: 'h',
        roles: {UserRole.capture},
        deviceId: 'SAX01',
        projectKeys: {'p1', 'p2'},
      );
      final back = AppUser.fromJson(u.toJson());
      expect(back.projectKeys, {'p1', 'p2'});

      // Legacy JSON predating the field parses fine, defaulting to empty.
      final legacy = AppUser.fromJson(<String, Object?>{'username': 'x'});
      expect(legacy.projectKeys, isEmpty);
    });

    test('copyWith replaces projectKeys (including to empty)', () {
      const u = AppUser(
        username: 'a',
        passwordHash: 'h',
        roles: {UserRole.capture},
        projectKeys: {'p1'},
      );
      final cleared = u.copyWith(projectKeys: {});
      expect(cleared.projectKeys, isEmpty);
      final replaced = u.copyWith(projectKeys: {'p2', 'p3'});
      expect(replaced.projectKeys, {'p2', 'p3'});
    });
  });
}
