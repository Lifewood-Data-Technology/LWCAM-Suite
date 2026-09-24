import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/app_user.dart';
import 'package:lwcam_admin/services/admin_pg_statements.dart';

void main() {
  group('tsOrNull', () {
    test('parses ISO strings, coerces bare years, nulls out junk/empty', () {
      expect(tsOrNull('2026-07-21T09:00:00'), isNotNull);
      expect(tsOrNull('1914'), startsWith('1914-01-01'));
      expect(tsOrNull('circa 1918'), isNull);
      expect(tsOrNull(''), isNull);
      expect(tsOrNull(null), isNull);
    });
  });

  group('userUpsertSql', () {
    test('conflicts on user_id, carries roles + device_id, revives soft-deletes', () {
      final stmt = userUpsertSql(
        username: 'alice',
        passwordHash: r'$2a$10$hash',
        active: true,
        mustChangePassword: false,
        roles: 'admin,capture',
        deviceId: 'SAX01',
      );
      expect(stmt.sql, contains('ON CONFLICT (user_id) DO UPDATE'));
      expect(stmt.sql, contains('is_deleted = FALSE, deleted_at = NULL'));
      expect(stmt.parameters['roles'], 'admin,capture');
      expect(stmt.parameters['device_id'], 'SAX01');
    });

    test('last_login_at is never written by this upsert — LWCAM owns the stamp', () {
      final stmt = userUpsertSql(
        username: 'alice',
        passwordHash: 'h',
        active: true,
        mustChangePassword: false,
        roles: 'admin',
      );
      expect(stmt.sql, isNot(contains('last_login_at')));
      expect(stmt.parameters.containsKey('last_login_at'), isFalse);
    });

    test('password/must_change_password are INSERT-only — DO UPDATE never '
        'touches them, so a stale whole-store push cannot regress a '
        'password a capture user just changed through LWCAM', () {
      final stmt = userUpsertSql(
        username: 'alice',
        passwordHash: 'h',
        active: true,
        mustChangePassword: true,
        roles: 'capture',
        deviceId: 'SAX01',
      );
      expect(stmt.sql, isNot(contains('password = EXCLUDED.password')));
      expect(stmt.sql,
          isNot(contains('must_change_password = EXCLUDED.must_change_password')));
      // Still supplied for genuinely new rows.
      expect(stmt.sql, contains('INSERT INTO users (user_id, password'));
      expect(stmt.parameters['password'], 'h');
    });

    test('userPasswordResetSql is the explicit targeted write — always '
        'forces a change on next login', () {
      final stmt = userPasswordResetSql(username: 'alice', passwordHash: 'tempHash');
      expect(stmt.sql, contains('SET password = @password'));
      expect(stmt.sql, contains('must_change_password = TRUE'));
      expect(stmt.parameters, {'user_id': 'alice', 'password': 'tempHash'});
    });

    test('a blank device id is sent as NULL, not an empty string', () {
      final stmt = userUpsertSql(
        username: 'alice',
        passwordHash: 'h',
        active: true,
        mustChangePassword: false,
        roles: 'admin',
        deviceId: '   ',
      );
      expect(stmt.parameters['device_id'], isNull);
    });
  });

  group('userSoftDeleteSql', () {
    test('sets is_deleted + active=FALSE, targets by user_id', () {
      final stmt = userSoftDeleteSql('alice');
      expect(stmt.sql, contains('is_deleted = TRUE'));
      expect(stmt.sql, contains('active = FALSE'));
      expect(stmt.parameters, {'user_id': 'alice'});
    });
  });

  group('projectUpsertSql', () {
    test('conflicts on project_key (not project_id) and updates project_id', () {
      final stmt = projectUpsertSql(
        projectKey: 'pabc123',
        projectId: 'PRJ-1',
        projectName: 'Archive',
        countryLocationCode: 'PH-CEB',
        hasData: false,
      );
      expect(stmt.sql, contains('ON CONFLICT (project_key) DO UPDATE'));
      expect(stmt.sql, contains('project_id = EXCLUDED.project_id'));
      expect(stmt.parameters['project_key'], 'pabc123');
      expect(stmt.parameters['project_id'], 'PRJ-1');
    });

    test('carries the template as jsonb text', () {
      final stmt = projectUpsertSql(
        projectKey: 'p1',
        projectId: 'PRJ-1',
        projectName: 'A',
        countryLocationCode: 'PH-CEB',
        hasData: false,
        templateJsonText: '{"fields":[]}',
      );
      expect(stmt.sql, contains('CAST(@template AS jsonb)'));
      expect(stmt.parameters['template'], '{"fields":[]}');
    });

    test('has_data is monotonic — a stale offline snapshot can never flip '
        'it back to false (LWCAM sets it directly)', () {
      final stmt = projectUpsertSql(
        projectKey: 'p1',
        projectId: 'PRJ-1',
        projectName: 'A',
        countryLocationCode: 'PH-CEB',
        hasData: false,
      );
      expect(stmt.sql, contains('has_data = projects.has_data OR EXCLUDED.has_data'));
      expect(stmt.sql, isNot(contains('has_data = EXCLUDED.has_data,')));
    });
  });

  group('projectSoftDeleteSql', () {
    test('targets by project_key and frees the location code (a FULL unique '
        'FK target — a new project must be able to reuse it)', () {
      final stmt = projectSoftDeleteSql('p1');
      expect(stmt.sql, contains('is_deleted = TRUE'));
      expect(stmt.sql, contains("country_location_code = '~deleted~' || id"));
      expect(stmt.parameters, {'project_key': 'p1'});
    });
  });

  group('appSettingUpsertSql', () {
    test('upserts by key with an IS DISTINCT guard', () {
      final stmt = appSettingUpsertSql(key: 'metadata_keying_enabled', value: 'true');
      expect(stmt.sql, contains('ON CONFLICT (key) DO UPDATE'));
      expect(stmt.sql, contains('IS DISTINCT FROM'));
      expect(stmt.parameters, {'key': 'metadata_keying_enabled', 'value': 'true'});
    });
  });

  group('userProjects push', () {
    test('insert resolves by project_id + role_name, ON CONFLICT DO NOTHING', () {
      final stmt = userProjectInsertSql(username: 'alice', projectId: 'PRJ-1', roleName: 'capture');
      expect(stmt.sql, contains('ON CONFLICT DO NOTHING'));
    });

    test('prune with empty keepPairs clears every assignment for the user', () {
      final stmt = userProjectsPruneSql(username: 'alice', keepPairs: const []);
      expect(stmt.parameters['keep_pairs'], isEmpty);
      expect(stmt.sql, contains('ANY(@keep_pairs)'));
    });
  });

  group('pull SELECTs', () {
    test('users pull filters is_deleted and carries device_id/roles/created_by', () {
      final stmt = selectUsersSql();
      expect(stmt.sql, contains('u.is_deleted = FALSE'));
      expect(stmt.sql, contains('u.roles'));
      expect(stmt.sql, contains('u.device_id'));
      expect(stmt.sql, contains('created_by'));
    });

    test('projects pull carries project_key and template as text', () {
      final stmt = selectProjectsSql();
      expect(stmt.sql, contains('project_key'));
      expect(stmt.sql, contains('template::text'));
      expect(stmt.sql, contains('is_deleted = FALSE'));
    });

    test('user_projects pull joins to natural keys and filters both sides', () {
      final stmt = selectUserProjectsSql();
      expect(stmt.sql, contains('u.is_deleted = FALSE'));
      expect(stmt.sql, contains('p.is_deleted = FALSE'));
      expect(stmt.sql, contains('project_key'));
      expect(stmt.sql, contains('role_name'));
    });

    test('app_settings pull has no filter — it is a flat key/value table', () {
      final stmt = selectAppSettingsSql();
      expect(stmt.sql, 'SELECT key, value FROM app_settings');
    });
  });

  group('buildUsersStoreFromPgRows', () {
    final now = DateTime(2026, 7, 21, 9, 30);

    test('maps roles from the users.roles column, and projectKeys from '
        'user_projects, tolerating unknown role segments', () {
      final store = buildUsersStoreFromPgRows(
        users: [
          {
            'user_id': 'alice',
            'password': 'h',
            'active': true,
            'must_change_password': false,
            'roles': 'capture,ghost-role',
            'device_id': null,
            'created_at': null,
            'last_login_at': null,
            'created_by': null,
          },
        ],
        projects: const [],
        userProjects: [
          {'user_id': 'alice', 'project_key': 'p1', 'role_name': 'capture'},
        ],
        appSettings: const [],
        now: now,
      );
      final alice = store.findUser('alice')!;
      expect(alice.roles, {UserRole.capture});
      expect(alice.projectKeys, {'p1'});
    });

    test('keeps role-specific grants separate for a mixed-role user', () {
      final store = buildUsersStoreFromPgRows(
        users: [
          {
            'user_id': 'alice', 'password': 'h', 'active': true,
            'must_change_password': false, 'roles': 'admin,capture,qc',
            'device_id': 'SAX01', 'created_at': null, 'last_login_at': null,
            'created_by': null,
          },
        ],
        projects: const [],
        userProjects: [
          {'user_id': 'alice', 'project_key': 'admin-p', 'role_name': 'admin'},
          {'user_id': 'alice', 'project_key': 'capture-p', 'role_name': 'capture'},
          {'user_id': 'alice', 'project_key': 'qc-p', 'role_name': 'qc'},
        ],
        appSettings: const [],
        now: now,
      );
      final alice = store.findUser('alice')!;
      expect(alice.projectKeysFor(UserRole.admin), {'admin-p'});
      expect(alice.projectKeysFor(UserRole.capture), {'capture-p'});
      expect(alice.projectKeysFor(UserRole.qc), {'qc-p'});
    });

    test('a user with zero project rows still keeps their role — this is '
        'exactly why users.roles exists (user_projects alone would drop it)', () {
      final store = buildUsersStoreFromPgRows(
        users: [
          {
            'user_id': 'admin1',
            'password': 'h',
            'active': true,
            'must_change_password': false,
            'roles': 'admin',
            'device_id': null,
            'created_at': null,
            'last_login_at': null,
            'created_by': null,
          },
        ],
        projects: const [],
        userProjects: const [], // zero assignments
        appSettings: const [],
        now: now,
      );
      final admin = store.findUser('admin1')!;
      expect(admin.roles, {UserRole.admin});
      expect(admin.projectKeys, isEmpty);
    });

    test('projects map project_key/project_id/location code/template', () {
      final store = buildUsersStoreFromPgRows(
        users: const [],
        projects: [
          {
            'project_key': 'p1',
            'project_id': 'PRJ-1',
            'project_name': 'Archive',
            'country_location_code': 'PH-CEB',
            'start_date': '2026-01-01T00:00:00.000Z',
            'has_data': true,
            'template': '{"version":2,"fields":[]}',
            'created_at': null,
          },
        ],
        userProjects: const [],
        appSettings: const [],
        now: now,
      );
      final p = store.findProjectByKey('p1')!;
      expect(p.projectId, 'PRJ-1');
      expect(p.countryLocationCode, 'PH-CEB');
      expect(p.hasData, isTrue);
      expect(p.template, isNotNull);
    });

    test('template column as an already-decoded Map also parses', () {
      final store = buildUsersStoreFromPgRows(
        users: const [],
        projects: [
          {
            'project_key': 'p1',
            'project_id': 'PRJ-1',
            'project_name': 'Archive',
            'country_location_code': 'PH-CEB',
            'start_date': null,
            'has_data': false,
            'template': {'version': 2, 'fields': []},
            'created_at': null,
          },
        ],
        userProjects: const [],
        appSettings: const [],
        now: now,
      );
      expect(store.findProjectByKey('p1')!.template, isNotNull);
    });

    test('app_settings rows populate SharedAppSettings with safe fallbacks', () {
      final store = buildUsersStoreFromPgRows(
        users: const [],
        projects: const [],
        userProjects: const [],
        appSettings: [
          {'key': 'metadata_keying_enabled', 'value': 'true'},
          {'key': 'shutter_keybind', 'value': 'F5'},
          {'key': 'shutter_method', 'value': 'not-a-real-method'},
          {'key': 'shutter_tap_x_percent', 'value': '33'},
        ],
        now: now,
      );
      expect(store.settings.metadataKeyingEnabled, isTrue);
      expect(store.settings.shutterKeybind, 'F5');
      expect(store.settings.shutterMethod, 'tap'); // invalid value falls back
      expect(store.settings.shutterTapXPercent, 33);
      expect(store.settings.shutterTapYPercent, 90); // absent → default
    });

    test('an entirely empty pull builds a valid, empty store', () {
      final store = buildUsersStoreFromPgRows(
        users: const [],
        projects: const [],
        userProjects: const [],
        appSettings: const [],
        now: now,
      );
      expect(store.users, isEmpty);
      expect(store.projects, isEmpty);
      expect(store.updatedAt, now);
    });
  });

  // A role this app cannot parse must survive a pull → push round-trip. Dropping
  // it used to revoke the QC platform's accounts the moment a SuperAdmin saved
  // anything here, so each link in that chain is pinned separately.
  group('foreign roles survive a round-trip', () {
    final now = DateTime(2026, 7, 21, 9, 30);

    Map<String, Object?> userRow(String roles) => {
          'user_id': 'reviewer',
          'password': 'h',
          'active': true,
          'must_change_password': false,
          'roles': roles,
          'device_id': null,
          'created_at': null,
          'last_login_at': null,
          'created_by': null,
        };

    AppUser pulled(String roles) => buildUsersStoreFromPgRows(
          users: [userRow(roles)],
          projects: const [],
          userProjects: const [],
          appSettings: const [],
          now: now,
        ).findUser('reviewer')!;

    test('qc is a first-class role now, not a foreign one', () {
      final user = pulled('qc');
      expect(user.roles, {UserRole.qc});
      expect(user.extraRoles, isEmpty);
      expect(user.rolesColumnValue, 'qc');
    });

    test('an unmodelled role lands in extraRoles and is written back verbatim', () {
      final user = pulled('admin,exporter');
      expect(user.roles, {UserRole.admin});
      expect(user.extraRoles, {'exporter'});
      expect(user.rolesColumnValue, 'admin,exporter');
    });

    test('a user whose ONLY role is unmodelled does not come back role-less', () {
      final user = pulled('exporter');
      expect(user.roles, isEmpty);
      expect(user.extraRoles, {'exporter'});
      expect(user.rolesColumnValue, 'exporter');
    });

    test('extraRoles survives the local JSON snapshot too', () {
      final user = pulled('admin,exporter');
      final reloaded = AppUser.fromJson(user.toJson());
      expect(reloaded.rolesColumnValue, 'admin,exporter');
    });

    test('a snapshot written before extraRoles existed still recovers the role', () {
      // Older builds wrote unknown segments into `roles` and nowhere else.
      final legacy = AppUser.fromJson({
        'username': 'reviewer',
        'passwordHash': 'h',
        'roles': ['admin', 'exporter'],
      });
      expect(legacy.roles, {UserRole.admin});
      expect(legacy.extraRoles, {'exporter'});
    });

    test('the upsert refuses to blank roles, and stays a no-op when it would', () {
      final stmt = userUpsertSql(
        username: 'reviewer',
        passwordHash: 'h',
        active: true,
        mustChangePassword: false,
        roles: '',
      );
      // Backstop for any future build that still drops a role it cannot parse.
      expect(stmt.sql, contains("roles = CASE WHEN EXCLUDED.roles = '' THEN users.roles"));
      // Mirrored into the guard, so such a push cannot fire an UPDATE — which
      // would otherwise also flip is_deleted back to FALSE and revive the row.
      expect(
        stmt.sql,
        contains("users.roles IS DISTINCT FROM (CASE WHEN EXCLUDED.roles = '' "
            'THEN users.roles ELSE EXCLUDED.roles END)'),
      );
    });

    test('a real role change is still written', () {
      final stmt = userUpsertSql(
        username: 'reviewer',
        passwordHash: 'h',
        active: true,
        mustChangePassword: false,
        roles: 'admin,qc',
      );
      expect(stmt.parameters['roles'], 'admin,qc');
    });
  });
}
