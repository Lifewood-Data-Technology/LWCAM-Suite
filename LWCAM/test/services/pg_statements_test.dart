import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/services/pg_statements.dart';

void main() {
  // CAST(@x AS timestamptz) resolves an offset-less string using the SESSION
  // zone, which the postgres package pins to UTC — so a naive local string used
  // to land 8h in the future on a +08 station. Nothing here may emit one.
  group('tsOrNull (event instants)', () {
    test('converts a naive local string to UTC', () {
      final local = DateTime(2026, 7, 30, 11, 28, 37);
      final out = tsOrNull(local.toIso8601String());
      expect(out, endsWith('Z'), reason: 'must be anchored, never naive');
      expect(DateTime.parse(out!).isUtc, isTrue);
      // Same instant, not the same wall clock.
      expect(DateTime.parse(out).isAtSameMomentAs(local), isTrue);
    });

    test('leaves an already-anchored string on the same instant', () {
      final z = tsOrNull('2026-07-30T11:28:37.000Z');
      expect(DateTime.parse(z!).isAtSameMomentAs(
          DateTime.utc(2026, 7, 30, 11, 28, 37)), isTrue);
      // Dart parses an explicit offset straight to UTC, so this holds too.
      final offset = tsOrNull('2026-07-30T11:28:37+08:00');
      expect(DateTime.parse(offset!).isAtSameMomentAs(
          DateTime.utc(2026, 7, 30, 3, 28, 37)), isTrue);
    });

    test('nulls out junk/empty rather than poisoning a batch', () {
      expect(tsOrNull('circa 1918'), isNull);
      expect(tsOrNull('1914-99'), isNull);
      expect(tsOrNull(''), isNull);
      expect(tsOrNull(null), isNull);
    });
  });

  group('changeOwnPasswordSql', () {
    test('calls the function with old password and new hash as bound parameters', () {
      final stmt = changeOwnPasswordSql(
        username: 'alice',
        oldPassword: 'Temp1234',
        bcryptHash: r'$2a$10$abc',
      );
      expect(stmt.sql, contains('lwcam_change_own_password(@user_id, @old_password, @new_hash)'));
      expect(stmt.sql, isNot(contains('UPDATE')));
      expect(stmt.sql, isNot(contains('Temp1234')));
      expect(stmt.parameters, {
        'user_id': 'alice',
        'old_password': 'Temp1234',
        'new_hash': r'$2a$10$abc',
      });
    });
  });

  group('boxUpsertSql', () {
    final stmt = boxUpsertSql(
      {
        'box_name': 'BOX-1',
        'status': 'TRANSFERRED',
        'created_at': '2026-07-21T08:00:00',
        'transfer_start_at': '2026-07-21T09:00:00',
        'transfer_end_at': '2026-07-21T09:05:00',
        'transferred_to': r'D:\dest',
        // Local-only columns that must never reach PG:
        'renamed_from': 'OLD',
        'template_json': '{}',
        'project_key': 'pabc',
        'last_transfer_state': 'running',
      },
      pgUserId: 11,
      pgDeviceId: 22,
      pgProjectId: 33,
    );

    test('conflicts on (project_id, box_name) and returns box_id', () {
      expect(stmt.sql, contains('ON CONFLICT (project_id, box_name)'));
      expect(stmt.sql, contains('RETURNING box_id'));
    });

    // Fix 2: a second station racing to create the same box name must not
    // silently steal/merge the first station's row — the DO UPDATE only
    // fires for the owning device, so a foreign device's upsert returns
    // zero rows instead of overwriting it.
    test('the DO UPDATE only applies when the device already owns the row', () {
      expect(
        stmt.sql,
        contains('WHERE capture_boxes.device_id = EXCLUDED.device_id'),
      );
    });

    test('carries resolved ids, never local-only columns', () {
      expect(stmt.parameters['user_id'], 11);
      expect(stmt.parameters['device_id'], 22);
      expect(stmt.parameters['project_id'], 33);
      expect(stmt.parameters.containsKey('renamed_from'), isFalse);
      expect(stmt.sql, isNot(contains('template_json')));
      expect(stmt.sql, isNot(contains('last_transfer_state')));
      expect(stmt.sql, isNot(contains('project_key')));
    });
  });

  group('folderUpsertSql', () {
    final stmt = folderUpsertSql(
      {
        'folder_name': null,
        'folder_seq': 2,
        'title': 'T',
        'start_date': '1877-Mar-05',
        'source_created_at': '2026-07-21T08:00:00',
        'source_updated_at': '2026-07-21T08:01:00',
        'is_complete': 1,
      },
      pgBoxId: 7,
      pgDeviceId: 22,
    );

    test('never writes QC/pipeline columns and COALESCEs folder_name', () {
      for (final forbidden in [
        'group_id', 'qc_status', 'client_qc_status', 'is_deskewed',
        'is_cropped', 'folder_path', 'thumbnail_path', 'is_exported', //
      ]) {
        expect(stmt.sql, isNot(contains(forbidden)));
      }
      expect(stmt.sql, isNot(contains('is_complete'))); // local-only
      expect(stmt.sql, contains("COALESCE(@folder_name, '')"));
      expect(stmt.sql, contains('ON CONFLICT (box_id, folder_seq)'));
      // Reusing a locally-freed seq revives a soft-deleted cloud row.
      expect(stmt.sql, contains('is_deleted = FALSE'));
      expect(stmt.sql, contains('RETURNING id'));
    });

    // Fix 2: same ownership guard as boxUpsertSql, one level down — stops a
    // losing station's folder upsert from clobbering the winning station's
    // folder at the same (box_id, folder_seq).
    test('the DO UPDATE only applies when the device already owns the row', () {
      expect(
        stmt.sql,
        contains('WHERE capture_folders.device_id = EXCLUDED.device_id'),
      );
    });

    // Owner decision: start_date/end_date are TEXT holding the archive date
    // VERBATIM as keyed. Nothing here may parse, cast or reshape them.
    test('binds keyed archive dates verbatim, with no timestamptz cast', () {
      expect(stmt.parameters['start_date'], '1877-Mar-05');
      expect(stmt.sql, isNot(contains('CAST(@start_date')));
      expect(stmt.sql, isNot(contains('CAST(@end_date')));
      expect(stmt.parameters['source_created_at'], isNotNull);
    });

    test('a year-month round-trips unchanged; blank becomes NULL', () {
      final ym = folderUpsertSql(
        {'folder_seq': 1, 'start_date': ' 1914-06 ', 'end_date': ''},
        pgBoxId: 7,
        pgDeviceId: 22,
      );
      expect(ym.parameters['start_date'], '1914-06');
      expect(ym.parameters['end_date'], isNull);
    });
  });

  group('resolveBoxSql (Fix 2d)', () {
    test('filters by owning device only when one is given', () {
      final unfiltered = resolveBoxSql(pgProjectId: 3, boxName: 'BOX-1');
      expect(unfiltered.sql, isNot(contains('device_id')));
      expect(unfiltered.parameters.containsKey('owner_device_id'), isFalse);

      final owned = resolveBoxSql(
        pgProjectId: 3,
        boxName: 'BOX-1',
        ownerDeviceId: 'SAX01',
      );
      expect(owned.sql, contains('AND device_id ='));
      expect(owned.parameters['owner_device_id'], 'SAX01');
    });
  });

  group('rename fixup', () {
    test('moves the old-named row only when the new name is free', () {
      final stmt = boxRenameFixupSql(
          pgProjectId: 3, renamedFrom: 'OLD', newName: 'NEW');
      expect(stmt.sql, contains('SET box_name = @new_name'));
      expect(stmt.sql, contains('AND NOT EXISTS'));
      expect(stmt.parameters['renamed_from'], 'OLD');
      expect(stmt.parameters['new_name'], 'NEW');
    });

    // The transfer renames each file after capture already recorded the device
    // name, so the cloud row has to be moved before the upsert — otherwise the
    // (folder_id, image_name) conflict target mints a second row and QC's
    // folder_path/image_name lookup finds neither file.
    test('image fixup moves the row within its folder, guarded like the box one',
        () {
      final stmt = imageRenameFixupSql(
        pgFolderId: 9,
        renamedFrom: 'IMG_20260729_112403.jpg',
        newName: 'SAX04_IMG_20260729_112403_001.jpg',
      );
      expect(stmt.sql, contains('UPDATE capture_images'));
      expect(stmt.sql, contains('SET image_name = @new_name'));
      // Scoped to the folder: the same device filename can legitimately exist
      // in another folder, and renaming that one would corrupt it.
      expect(stmt.sql, contains('folder_id = @folder_id'));
      // Idempotent — a redrained outbox row must not fail or double-apply.
      expect(stmt.sql, contains('AND NOT EXISTS'));
      expect(stmt.parameters['folder_id'], 9);
      expect(stmt.parameters['renamed_from'], 'IMG_20260729_112403.jpg');
      expect(stmt.parameters['new_name'], 'SAX04_IMG_20260729_112403_001.jpg');
    });
  });

  group('capture_images', () {
    test('upsert conflicts on (folder_id, image_name)', () {
      final stmt = imageUpsertSql(
        {'image_name': 'IMG_1.jpg', 'file_format': 'jpg'},
        pgDeviceId: 22,
        pgFolderId: 9,
      );
      expect(stmt.sql, contains('ON CONFLICT (folder_id, image_name)'));
      expect(stmt.parameters['folder_id'], 9);
    });

    test('delete is a hard DELETE (no soft-delete columns in the cloud)', () {
      final stmt = imageDeleteSql(pgFolderId: 9, imageName: 'IMG_1.jpg');
      expect(stmt.sql, startsWith('DELETE FROM capture_images'));
      expect(stmt.sql, isNot(contains('is_deleted')));
    });
  });

  group('folder delete', () {
    test('soft-deletes by (box_id, folder_seq)', () {
      final stmt = folderSoftDeleteSql(pgBoxId: 7, folderSeq: 2);
      expect(stmt.sql, contains('SET is_deleted = TRUE'));
      expect(stmt.parameters, {'box_id': 7, 'folder_seq': 2});
    });
  });

  group('box delete', () {
    test('soft-deletes by resolved box_id, never hard-deletes', () {
      final stmt = boxSoftDeleteSql(pgBoxId: 7);
      expect(stmt.sql, startsWith('UPDATE capture_boxes SET is_deleted = TRUE'));
      expect(stmt.sql, isNot(contains('DELETE FROM')));
      expect(stmt.parameters, {'box_id': 7});
    });
  });

  group('folderProcessingUpdateSql', () {
    final stmt = folderProcessingUpdateSql(
      {
        'is_created_thumbnail': true,
        'folder_path': r'\\nas\proc\F001',
        'thumbnail_path': r'\\nas\proc\F001\thumbs',
        // natural keys are for the sink's resolution, not this UPDATE:
        'project_key': 'pabc',
        'box_name': 'BOX-1',
        'folder_seq': 1,
      },
      pgFolderId: 42,
    );

    test('sets the three completion flags, both paths, and moves qc_status '
        'to PENDING by folder id', () {
      expect(stmt.sql, contains('is_deskewed = TRUE'));
      expect(stmt.sql, contains('is_cropped = TRUE'));
      expect(stmt.sql, contains('is_created_thumbnail = @is_created_thumbnail'));
      expect(stmt.sql, contains('folder_path = @folder_path'));
      expect(stmt.sql, contains('thumbnail_path = @thumbnail_path'));
      expect(stmt.sql, contains("THEN 'PENDING' ELSE qc_status END"));
      expect(stmt.sql, contains('WHERE id = @folder_id'));
      expect(stmt.parameters['folder_id'], 42);
      expect(stmt.parameters['is_created_thumbnail'], true);
      expect(stmt.parameters['folder_path'], r'\\nas\proc\F001');
    });

    test('only resets qc_status from a pre-QC state — a late report must not '
        'pull a PASSed folder back into the queue', () {
      expect(stmt.sql, isNot(contains("qc_status = 'PENDING'")));
      expect(
        stmt.sql,
        contains(
          'qc_status = CASE WHEN qc_status IS NULL '
          "OR upper(qc_status) IN ('', 'PENDING', 'REWORK') "
          "THEN 'PENDING' ELSE qc_status END",
        ),
      );
      // Same text LWIP's cloud_report.py transcribes (psycopg placeholders
      // aside) — the two writers must stay indistinguishable.
    });

    test('never touches the QC-owned columns', () {
      expect(stmt.sql, isNot(contains('group_id')));
      expect(stmt.sql, isNot(contains('client_qc_status')));
      expect(stmt.sql, isNot(contains('client_rework')));
    });
  });

  group('FK resolution — project key', () {
    test('resolves projects by project_key, not the editable project_id', () {
      final stmt = resolveProjectByKeySql('p1abc');
      expect(stmt.sql, contains('WHERE project_key = @project_key'));
      expect(stmt.parameters, {'project_key': 'p1abc'});
    });
  });

  group('fetchBoxNamesSql', () {
    test('joins on project_key and excludes soft-deleted boxes', () {
      final stmt = fetchBoxNamesSql('p1abc');
      expect(stmt.sql, contains('p.project_key = @project_key'));
      expect(stmt.sql, contains('b.is_deleted = FALSE'));
      expect(stmt.parameters, {'project_key': 'p1abc'});
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

    test('keeps capture, admin, and QC project grants separate', () {
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
          {'user_id': 'alice', 'project_key': 'capture-p', 'role_name': 'capture'},
          {'user_id': 'alice', 'project_key': 'admin-p', 'role_name': 'admin'},
          {'user_id': 'alice', 'project_key': 'qc-p', 'role_name': 'qc'},
        ],
        appSettings: const [],
        now: now,
      );
      final alice = store.findUser('alice')!;
      expect(alice.projectKeysFor(UserRole.capture), {'capture-p'});
      expect(alice.projectKeysFor(UserRole.admin), {'admin-p'});
      // qc became a role this app models when the QC platform merged in, so its
      // grants land beside the others instead of in the unknown-role bucket.
      expect(alice.projectKeysFor(UserRole.qc), {'qc-p'});
      expect(alice.extraRoleProjectKeys['qc'], isNull);
    });

    test('a qc account is now a first-class account here, and a role this app '
        'still does not model survives the snapshot round-trip — the pull '
        'rewrites the shared snapshot LWCam Admin pushes from, so losing one '
        'would revoke that account on the next admin save', () {
      final store = buildUsersStoreFromPgRows(
        users: [
          {
            'user_id': 'reviewer',
            'password': 'h',
            'active': true,
            'must_change_password': false,
            'roles': 'qc,rework',
            'device_id': null,
            'created_at': null,
            'last_login_at': null,
            'created_by': null,
          },
        ],
        projects: const [],
        userProjects: const [],
        appSettings: const [],
        now: now,
      );
      final reviewer = store.findUser('reviewer')!;
      // qc is modelled but not ACTED on here: the role survives the pull and
      // the snapshot write (see user_role_qc_test.dart) while granting this
      // app nothing - there is no canQc and no screen behind it since Phase 8.
      expect(reviewer.roles, contains(UserRole.qc));
      expect(reviewer.canNormalMode, isFalse);
      expect(reviewer.isAdmin, isFalse);
      expect(AppUser.fromJson(reviewer.toJson()).roles, contains(UserRole.qc));
      // 'rework' belongs to the sibling LWRework app and is still unknown here,
      // so it keeps taking the preservation path.
      expect(reviewer.extraRoles, {'rework'});
      expect(AppUser.fromJson(reviewer.toJson()).extraRoles, {'rework'});
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

  // rework_logs is the QC -> capture channel and is APPEND-ONLY: QC appends an
  // OPEN row per rejected image, LWCAM appends a CLOSED row once the recaptured
  // image has transferred. "Still open" therefore means the LATEST row for that
  // image is OPEN — a naive `WHERE rework_status = 'OPEN'` would resurrect every
  // historical request forever.
  group('rework_logs', () {
    test('the worklist query takes the latest row per image, then filters OPEN',
        () {
      final stmt = selectOpenReworkSql('Jamie');
      expect(stmt.sql, contains('DISTINCT ON (r.image_id)'));
      // Newest-first ordering inside the DISTINCT ON is what makes it "latest".
      expect(stmt.sql, contains('ORDER BY r.image_id, r.created_at DESC, r.id DESC'));
      expect(stmt.sql, contains("latest.rework_status = 'OPEN'"));
      // Scoped to the assigned operator, and never to deleted folders/boxes.
      expect(stmt.sql, contains('u.user_id = @user_id'));
      expect(stmt.sql, contains('f.is_deleted = FALSE'));
      expect(stmt.sql, contains('b.is_deleted = FALSE'));
      // folder_path is required to derive the LWIP input file to overwrite.
      expect(stmt.sql, contains('f.folder_path'));
      expect(stmt.parameters['user_id'], 'Jamie');
    });

    // The operator's edit form is seeded from these, NOT from LWCAM's local row:
    // QC edits the same columns, so seeding locally would revert its work.
    test('the worklist query carries the folder metadata, in allowlist order',
        () {
      final stmt = selectOpenReworkSql('Jamie');
      for (final column in kFolderMetadataColumns) {
        expect(stmt.sql, contains('f.$column'),
            reason: '$column must be selectable for the edit form');
      }
      // ReworkService reads them positionally from index 12 on, so the order in
      // the SELECT has to be kFolderMetadataColumns' order.
      final selected = stmt.sql
          .substring(0, stmt.sql.indexOf(' FROM ('))
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.startsWith('f.'))
          .toList();
      expect(selected.sublist(selected.length - kFolderMetadataColumns.length),
          kFolderMetadataColumns.map((c) => 'f.$c').toList());
    });

    // The rework tile states which page of the folder was sent back. Nothing
    // stores a page index, so the query derives it from QC's own page key.
    test('the worklist query carries a folder-scoped page number, after the '
        'metadata columns', () {
      final stmt = selectOpenReworkSql('Jamie');
      // Scoped to ONE folder: a global count would number pages across every
      // project on the station.
      expect(stmt.sql, contains('i2.folder_id = i.folder_id'));
      // QC's canonical page order (ordered_official_images), not image_name.
      expect(
          stmt.sql,
          contains(
              '(i2.image_created_at, i2.id) <= (i.image_created_at, i.id)'));
      expect(stmt.sql,
          endsWith('ORDER BY b.box_name, f.folder_seq, i.image_created_at, i.id'));
      // ReworkService reads these two positionally at
      // 12 + kFolderMetadataColumns.length, so they must be the LAST selected
      // columns — this fails if anyone inserts a column ahead of them.
      final selected = stmt.sql
          .substring(0, stmt.sql.indexOf(' FROM ('))
          .split(',')
          .map((s) => s.trim())
          .toList();
      expect(selected.sublist(selected.length - 2),
          ['pos.page_no', 'pos.page_count']);
    });
  });

  // A metadata correction during rework must NOT go through folderUpsertSql:
  // that writes every metadata column from LWCAM's local row, which still holds
  // what was keyed at capture time, so it would revert QC's own edits to the
  // columns the operator never touched.
  group('rework folder metadata patch', () {
    test('updates only the changed columns', () {
      final stmt = folderMetadataPatchSql(
        {'title': 'Corrected title', 'archival_ref_no': 'ARN-9'},
        pgFolderId: 7,
      );
      expect(stmt.sql, contains('UPDATE capture_folders SET'));
      expect(stmt.sql, contains('title = @title'));
      expect(stmt.sql, contains('archival_ref_no = @archival_ref_no'));
      expect(stmt.sql, contains('WHERE id = @folder_id'));
      // Everything the operator did not touch stays untouched.
      expect(stmt.sql, isNot(contains('cover_tag')));
      expect(stmt.sql, isNot(contains('volume')));
      expect(stmt.parameters['title'], 'Corrected title');
      expect(stmt.parameters['folder_id'], 7);
    });

    test('binds the two date columns as plain text, verbatim', () {
      final stmt = folderMetadataPatchSql(
        {'start_date': '1877-Mar-05', 'end_date': null},
        pgFolderId: 1,
      );
      expect(stmt.sql, contains('start_date = @start_date'));
      expect(stmt.sql, contains('end_date = @end_date'));
      expect(stmt.sql, isNot(contains('timestamptz')));
      expect(stmt.parameters['start_date'], '1877-Mar-05');
      expect(stmt.parameters['end_date'], isNull);
    });

    test('refuses a column outside the allowlist rather than interpolating it',
        () {
      expect(
        () => folderMetadataPatchSql(
            {'qc_status': 'PASS'}, pgFolderId: 1),
        throwsArgumentError,
      );
      expect(
        () => folderMetadataPatchSql(
            {'title = x; DROP TABLE users': 'x'}, pgFolderId: 1),
        throwsArgumentError,
      );
      expect(() => folderMetadataPatchSql(const {}, pgFolderId: 1),
          throwsArgumentError);
    });

    test('every editable template field maps to an allowlisted column', () {
      for (final column in kFolderMetadataColumnByFieldId.values) {
        expect(kFolderMetadataColumns, contains(column));
      }
    });

    // A metadata-only fix changes no file, so LWIP's fingerprint is unchanged
    // and it will never reprocess the folder — without this the folder would sit
    // in REWORK forever.
    test('the metadata-only reset restores qc_status AND the flags QC reject '
        'zeroed', () {
      // QC's reject_task sets is_deskewed/is_cropped/is_created_thumbnail
      // false; a metadata-only fix has no reprocess to set them back, so this
      // statement must — the files are in fact processed.
      final stmt = folderQcStatusPendingSql(pgFolderId: 12, isCreatedThumbnail: false);
      expect(stmt.sql, contains("qc_status = 'PENDING'"));
      expect(stmt.sql, contains('is_deskewed = TRUE'));
      expect(stmt.sql, contains('is_cropped = TRUE'));
      expect(stmt.sql, contains('is_created_thumbnail = @is_created_thumbnail'));
      expect(stmt.sql, contains('WHERE id = @folder_id'));
      // Never the QC-owned or path columns.
      expect(stmt.sql, isNot(contains('folder_path')));
      expect(stmt.sql, isNot(contains('thumbnail_path')));
      expect(stmt.sql, isNot(contains('client_')));
      expect(stmt.parameters, {'folder_id': 12, 'is_created_thumbnail': false});
    });
  });

  group('rework_logs closure', () {

    test('closure is an INSERT of a CLOSED row, never an UPDATE', () {
      final stmt = insertReworkClosedSql(
        {
          'rework_comments': 'Recaptured in LWCAM',
          'closed_at': '2026-07-30T10:00:00',
        },
        pgImageId: 42,
        pgFolderId: 7,
        pgUserId: 3,
      );
      expect(stmt.sql, contains('INSERT INTO rework_logs'));
      expect(stmt.sql, contains("'CLOSED'"));
      expect(stmt.sql, isNot(contains('UPDATE')));
      expect(stmt.parameters['image_id'], 42);
      expect(stmt.parameters['folder_id'], 7);
      expect(stmt.parameters['assigned_uid'], 3);
      expect(stmt.parameters['rework_type'], 'Recapture');
      expect(stmt.parameters['created_at'], startsWith('2026-07-30'));
    });

    test('closure defaults its comment and type when the payload omits them', () {
      final stmt = insertReworkClosedSql(
        const {},
        pgImageId: 1,
        pgFolderId: 1,
        pgUserId: 1,
      );
      expect(stmt.parameters['rework_comments'], isNotEmpty);
      expect(stmt.parameters['rework_type'], 'Recapture');
      // No closed_at -> clock_timestamp() at the server.
      expect(stmt.parameters['created_at'], isNull);
      expect(stmt.sql, contains('clock_timestamp()'));
    });

    test('image resolution is scoped to the folder', () {
      final stmt = resolveImageSql(pgFolderId: 9, imageName: 'SAX01_a_001.jpg');
      expect(stmt.sql, contains('folder_id = @folder_id'));
      expect(stmt.parameters['image_name'], 'SAX01_a_001.jpg');
    });
  });
}
