// ignore_for_file: avoid_print

import 'package:postgres/postgres.dart';

import '../models/app_user.dart';
import 'pg_client.dart';
import 'pg_statements.dart' as st;
import 'sync_models.dart';
import 'sync_sink.dart';

/// PostgreSQL sink targeting the cloud schema in
/// `LWCam Workflow & SQL update/LWCam_database_20260720.sql`. One instance is
/// held for the lifetime of `SyncService`; every method reconnects lazily if
/// the held connection has dropped.
///
/// The cloud uses BIGINT identity PKs; outbox payloads carry natural keys
/// (see upload_stats_db.dart's SYNC section) and [apply] resolves them to
/// real ids per batch, parents first: project → device (self-healed
/// insert-if-missing) → box (with the rename fixup) → folder → image.
class PgSyncSink implements SyncSink {
  final String host;
  final int port;
  final String database;
  final String user;
  final String password;
  final bool useSsl;

  Connection? _conn;

  PgSyncSink({
    required this.host,
    required this.port,
    required this.database,
    required this.user,
    required this.password,
    required this.useSsl,
  });

  Future<Connection> _connect() async {
    final existing = _conn;
    if (existing != null && existing.isOpen) return existing;
    _conn = null;
    return _conn = await openPgConnection(
      host: host,
      port: port,
      database: database,
      user: user,
      password: password,
      useSsl: useSsl,
    );
  }

  /// Executes a [st.PgStatement], wrapping Dart string lists as text[] so
  /// `= ANY(@param)` works.
  Future<Result> _exec(Session session, st.PgStatement stmt) {
    final params = <String, Object?>{
      for (final e in stmt.parameters.entries)
        e.key: e.value is List<String>
            ? TypedValue(Type.textArray, e.value as List<String>)
            : e.value,
    };
    return session.execute(Sql.named(stmt.sql), parameters: params);
  }

  Future<int?> _selectId(Session session, st.PgStatement stmt) async {
    final result = await _exec(session, stmt);
    if (result.isEmpty) return null;
    return (result.first[0] as num?)?.toInt();
  }

  @override
  Future<void> probe() async {
    final conn = await _connect();
    try {
      await conn.execute('SELECT 1');
    } catch (e) {
      throw SyncConnectException(e.toString());
    }
  }

  // ── Outbox drain ──────────────────────────────────────────────────────────

  @override
  Future<void> apply(List<OutboxRecord> batch) async {
    if (batch.isEmpty) return;
    final conn = await _connect();

    await conn.runTx((session) async {
      // Per-batch id caches, keyed by natural key.
      final userIds = <String, int>{};
      final projectIds = <String, int>{};
      final deviceIds = <String, int>{};
      // '<pgProjectId>|<box_name lower>|<ownerDeviceId>'. The owner segment is
      // part of the key because boxIdOrNull's lookup is device-FILTERED for
      // station-owned entities and unfiltered for the processing/rework paths
      // — those two genuinely have different answers and must not share an
      // entry. Writers that omit an owner use the empty scope.
      final boxIds = <String, int>{};
      final folderIds = <String, int>{}; // '<pgBoxId>|<folder_seq>'

      Future<int> projectId(Map<String, dynamic> payload) async {
        final key = (payload['project_key'] as String?)?.trim() ?? '';
        if (key.isEmpty) {
          throw StateError(
            'row has no project_key (legacy/code-less project) — cannot sync',
          );
        }
        final cached = projectIds[key];
        if (cached != null) return cached;
        final id = await _selectId(session, st.resolveProjectByKeySql(key));
        if (id == null) {
          throw StateError('project "$key" not in PG yet (pull pending?)');
        }
        return projectIds[key] = id;
      }

      Future<int> userId(Map<String, dynamic> payload) async {
        final key = (payload['user_id'] as String?)?.trim() ?? '';
        if (key.isEmpty) throw StateError('box row has no user_id');
        final cached = userIds[key];
        if (cached != null) return cached;
        final id = await _selectId(session, st.resolveUserSql(key));
        if (id == null) {
          throw StateError('user "$key" not in PG yet (snapshot pending?)');
        }
        return userIds[key] = id;
      }

      Future<int> deviceId(
        Map<String, dynamic> payload,
        int pgProjectId,
      ) async {
        final key = (payload['device_id'] as String?)?.trim() ?? '';
        if (key.isEmpty) throw StateError('row has no device_id');
        final cached = deviceIds[key];
        if (cached != null) return cached;
        var id = await _selectId(session, st.resolveDeviceSql(key));
        if (id == null) {
          // Self-heal: boxes captured before the device's first gated login.
          await _exec(
            session,
            st.insertDeviceIfMissingSql(
              deviceId: key,
              pgProjectId: pgProjectId,
            ),
          );
          id = await _selectId(session, st.resolveDeviceSql(key));
        }
        if (id == null)
          throw StateError('device "$key" could not be registered');
        return deviceIds[key] = id;
      }

      /// Resolves the parent box for folder/image rows: current name first,
      /// then renamed_from (covers a rename racing ahead of the box upsert).
      /// Returns null when neither exists (caller decides throw vs skip).
      ///
      /// [ownerDeviceId], when given, requires the resolved box belong to
      /// that device — for the station-owned entities (capture_boxes/
      /// folders/images), so a station that lost the box-name conflict
      /// resolves to nothing here instead of adopting a foreign station's
      /// box. Omitted for the processing/rework paths.
      Future<int?> boxIdOrNull(
        Map<String, dynamic> payload,
        int pgProjectId, {
        String? ownerDeviceId,
      }) async {
        for (final name in [
          payload['box_name'] as String?,
          payload['renamed_from'] as String?,
        ]) {
          if (name == null || name.trim().isEmpty) continue;
          final cacheKey =
              '$pgProjectId|${name.trim().toLowerCase()}|${ownerDeviceId ?? ''}';
          final cached = boxIds[cacheKey];
          if (cached != null) return cached;
          final id = await _selectId(
            session,
            st.resolveBoxSql(
              pgProjectId: pgProjectId,
              boxName: name,
              ownerDeviceId: ownerDeviceId,
            ),
          );
          if (id != null) return boxIds[cacheKey] = id;
        }
        return null;
      }

      for (final record in batch) {
        final payload = record.payload;

        // Caps a resolver's StateError at 20 attempts — the same cap the
        // empty-RETURNING branches below already enforce — so an
        // unresolvable project/user/device (a code-less legacy project, a
        // deleted user) can't wedge a station's outbox forever. Rethrows
        // while retries remain (normal backoff applies); past the cap,
        // drops with a loud print and returns null for the caller to `break`.
        Future<T?> capped<T>(String label, Future<T> Function() resolve) async {
          try {
            return await resolve();
          } on StateError catch (e) {
            if (record.attempts < 20) rethrow;
            print('⚠️ Dropping $label after ${record.attempts} attempts — $e');
            return null;
          }
        }

        switch (record.entity) {
          case 'capture_boxes':
            if (payload == null) break;
            if (record.op == 'delete') {
              final pgProject = await capped(
                'box delete',
                () => projectId(payload),
              );
              if (pgProject == null) break;
              final owner = (payload['device_id'] as String?)?.trim();
              final pgBox = await boxIdOrNull(
                payload,
                pgProject,
                ownerDeviceId: owner,
              );
              // Never reached PG, or belongs to another device ⇒ nothing
              // to soft-delete.
              if (pgBox == null) break;
              await _exec(session, st.boxSoftDeleteSql(pgBoxId: pgBox));
              boxIds.removeWhere((_, id) => id == pgBox);
              break;
            }
            if (record.op != 'upsert') break;
            final pgProject = await capped(
              'box upsert',
              () => projectId(payload),
            );
            if (pgProject == null) break;
            final renamedFrom = (payload['renamed_from'] as String?)?.trim();
            if (renamedFrom != null && renamedFrom.isNotEmpty) {
              await _exec(
                session,
                st.boxRenameFixupSql(
                  pgProjectId: pgProject,
                  renamedFrom: renamedFrom,
                  newName: (payload['box_name'] as String?) ?? '',
                ),
              );
              final renamedOwner =
                  (payload['device_id'] as String?)?.trim() ?? '';
              boxIds.remove(
                '$pgProject|${renamedFrom.toLowerCase()}|$renamedOwner',
              );
            }
            final pgUser = await capped('box upsert', () => userId(payload));
            if (pgUser == null) break;
            final pgDevice = await capped(
              'box upsert',
              () => deviceId(payload, pgProject),
            );
            if (pgDevice == null) break;
            final result = await _exec(
              session,
              st.boxUpsertSql(
                payload,
                pgUserId: pgUser,
                pgDeviceId: pgDevice,
                pgProjectId: pgProject,
              ),
            );
            final name = (payload['box_name'] as String?)?.trim().toLowerCase();
            if (result.isNotEmpty && name != null) {
              // Same 3-part shape boxIdOrNull reads, under this box's own
              // owner scope — the folder/image records later in the batch
              // resolve with `ownerDeviceId: payload['device_id']`, so seeding
              // it here saves them a resolveBoxSql round-trip each.
              final owner = (payload['device_id'] as String?)?.trim() ?? '';
              boxIds['$pgProject|$name|$owner'] = (result.first[0] as num)
                  .toInt();
              break;
            }
            // Empty RETURNING with a name present means the ownership WHERE
            // on boxUpsertSql's DO UPDATE rejected it — the box name belongs
            // to another device. Retry on the normal backoff (covers a
            // stale/renamed row), then skip-ack so it can't wedge forever.
            if (name != null) {
              if (record.attempts < 20) {
                throw StateError(
                  'box "${payload['box_name']}" belongs to another device — '
                  'rename required (attempt ${record.attempts})',
                );
              }
              print(
                '⚠️ Dropping box upsert after ${record.attempts} attempts — '
                'box "${payload['box_name']}" belongs to another device: '
                'project_key=${payload['project_key']}',
              );
            }
            break;

          case 'capture_folders':
            if (payload == null) break;
            final pgProject = await capped(
              'folder upsert',
              () => projectId(payload),
            );
            if (pgProject == null) break;
            final ownerDeviceId = (payload['device_id'] as String?)?.trim();
            final pgBox = await boxIdOrNull(
              payload,
              pgProject,
              ownerDeviceId: ownerDeviceId,
            );
            if (record.op == 'delete') {
              // Parent never reached PG (or belongs to another device) ⇒
              // nothing to soft-delete.
              if (pgBox == null) break;
              await _exec(
                session,
                st.folderSoftDeleteSql(
                  pgBoxId: pgBox,
                  folderSeq: (payload['folder_seq'] as num).toInt(),
                ),
              );
              break;
            }
            if (pgBox == null) {
              // Either the parent box hasn't synced yet, or it belongs to
              // another device (Fix 2's ownership guard) — either way retry
              // on the normal backoff, then skip-ack.
              if (record.attempts < 20) {
                throw StateError(
                  'box "${payload['box_name']}" not owned by this device in '
                  'PG yet for folder upsert (attempt ${record.attempts})',
                );
              }
              print(
                '⚠️ Dropping folder upsert after ${record.attempts} '
                'attempts — owning box never appeared in PG: '
                'box="${payload['box_name']}" folder_seq=${payload['folder_seq']}',
              );
              break;
            }
            final pgFolderDevice = await capped(
              'folder upsert',
              () => deviceId(payload, pgProject),
            );
            if (pgFolderDevice == null) break;
            final result = await _exec(
              session,
              st.folderUpsertSql(
                payload,
                pgBoxId: pgBox,
                pgDeviceId: pgFolderDevice,
              ),
            );
            if (result.isNotEmpty) {
              folderIds['$pgBox|${payload['folder_seq']}'] =
                  (result.first[0] as num).toInt();
              break;
            }
            // Empty RETURNING: the folder's ownership WHERE rejected this
            // device (a foreign device somehow holds this box_id/folder_seq
            // — e.g. after a box-id reuse). Same skip-ack discipline.
            if (record.attempts < 20) {
              throw StateError(
                'folder box_id=$pgBox folder_seq=${payload['folder_seq']} '
                'belongs to another device (attempt ${record.attempts})',
              );
            }
            print(
              '⚠️ Dropping folder upsert after ${record.attempts} attempts '
              '— folder belongs to another device: box_id=$pgBox '
              'folder_seq=${payload['folder_seq']}',
            );
            break;

          case 'capture_images':
            if (payload == null) break;
            final pgProject = await capped(
              'image upsert',
              () => projectId(payload),
            );
            if (pgProject == null) break;
            final pgBox = await boxIdOrNull(
              payload,
              pgProject,
              ownerDeviceId: (payload['device_id'] as String?)?.trim(),
            );
            final seq = (payload['folder_seq'] as num?)?.toInt();
            int? pgFolder;
            if (pgBox != null && seq != null) {
              pgFolder =
                  folderIds['$pgBox|$seq'] ??
                  await _selectId(
                    session,
                    st.resolveFolderSql(pgBoxId: pgBox, folderSeq: seq),
                  );
              if (pgFolder != null) folderIds['$pgBox|$seq'] = pgFolder;
            }
            if (record.op == 'delete') {
              if (pgFolder == null) break; // parent never synced — no row
              await _exec(
                session,
                st.imageDeleteSql(
                  pgFolderId: pgFolder,
                  imageName: (payload['image_name'] as String?) ?? '',
                ),
              );
              break;
            }
            if (pgFolder == null) {
              throw StateError(
                'folder seq $seq of box "${payload['box_name']}" not in PG yet '
                'for image upsert',
              );
            }
            // The transfer renames the file after capture recorded the device
            // name, so move the existing row before upserting — otherwise the
            // (folder_id, image_name) conflict target mints a second row.
            // NOT payload['renamed_from'] — that one is the parent BOX's
            // previous name, used by boxIdOrNull above.
            final imageRenamedFrom = (payload['image_renamed_from'] as String?)
                ?.trim();
            if (imageRenamedFrom != null && imageRenamedFrom.isNotEmpty) {
              await _exec(
                session,
                st.imageRenameFixupSql(
                  pgFolderId: pgFolder,
                  renamedFrom: imageRenamedFrom,
                  newName: (payload['image_name'] as String?) ?? '',
                ),
              );
            }
            final pgImageDevice = await capped(
              'image upsert',
              () => deviceId(payload, pgProject),
            );
            if (pgImageDevice == null) break;
            await _exec(
              session,
              st.imageUpsertSql(
                payload,
                pgDeviceId: pgImageDevice,
                pgFolderId: pgFolder,
              ),
            );
            break;

          case 'capture_folder_processing':
            if (payload == null) break;
            final pgProject = await capped(
              'processing update',
              () => projectId(payload),
            );
            if (pgProject == null) break;
            final pgBox = await boxIdOrNull(payload, pgProject);
            final seq = (payload['folder_seq'] as num?)?.toInt();
            int? pgFolder;
            if (pgBox != null && seq != null) {
              pgFolder =
                  folderIds['$pgBox|$seq'] ??
                  await _selectId(
                    session,
                    st.resolveFolderSql(pgBoxId: pgBox, folderSeq: seq),
                  );
              if (pgFolder != null) folderIds['$pgBox|$seq'] = pgFolder;
            }
            if (pgFolder == null) {
              // Same-PC: the folder upsert is earlier in this ordered batch,
              // so this rarely fires. Split-PC: the capture station's folder
              // may not have synced yet — retry on the normal backoff. After
              // ~20 attempts (hours) give up and ack, so one decommissioned
              // capture PC can't wedge a processing station's reports forever.
              if (record.attempts < 20) {
                throw StateError(
                  'folder seq $seq of box "${payload['box_name']}" not in PG '
                  'yet for processing update (attempt ${record.attempts})',
                );
              }
              print(
                '⚠️ Dropping processing update after ${record.attempts} '
                'attempts — folder never appeared in PG: '
                'project_key=${payload['project_key']} '
                'box="${payload['box_name']}" folder_seq=$seq',
              );
              break;
            }
            await _exec(
              session,
              st.folderProcessingUpdateSql(payload, pgFolderId: pgFolder),
            );
            break;

          case 'capture_folder_rework':
            // A rework submit's folder side: the metadata columns the operator
            // corrected, and — only when the fix was metadata-only — a
            // qc_status reset that puts the folder back in the QC queue. With a
            // recapture, LWIP's reprocess does that instead.
            if (payload == null) break;
            final pgProject = await capped(
              'rework folder update',
              () => projectId(payload),
            );
            if (pgProject == null) break;
            final pgBox = await boxIdOrNull(payload, pgProject);
            final seq = (payload['folder_seq'] as num?)?.toInt();
            int? pgFolder;
            if (pgBox != null && seq != null) {
              pgFolder =
                  folderIds['$pgBox|$seq'] ??
                  await _selectId(
                    session,
                    st.resolveFolderSql(pgBoxId: pgBox, folderSeq: seq),
                  );
              if (pgFolder != null) folderIds['$pgBox|$seq'] = pgFolder;
            }
            if (pgFolder == null) {
              // Same skip-ack discipline as the closure below: retry on the
              // normal backoff, then give up rather than wedge the queue. The
              // folder simply keeps its old metadata and stays in REWORK.
              if (record.attempts < 20) {
                throw StateError(
                  'rework folder not in PG yet: box "${payload['box_name']}" '
                  'folder_seq=$seq (attempt ${record.attempts})',
                );
              }
              print(
                '⚠️ Dropping rework folder update after ${record.attempts} '
                'attempts — folder never appeared in PG: '
                'box="${payload['box_name']}" folder_seq=$seq',
              );
              break;
            }
            final metadata =
                (payload['metadata'] as Map?)?.cast<String, Object?>() ??
                const <String, Object?>{};
            if (metadata.isNotEmpty) {
              await _exec(
                session,
                st.folderMetadataPatchSql(metadata, pgFolderId: pgFolder),
              );
            }
            if (payload['reset_qc_status'] == true) {
              await _exec(
                session,
                st.folderQcStatusPendingSql(
                  pgFolderId: pgFolder,
                  isCreatedThumbnail: payload['is_created_thumbnail'] == true,
                ),
              );
            }
            break;

          case 'rework_logs':
            // Retires a QC recapture request by APPENDING a CLOSED row (the
            // table is append-only; latest row per image wins). Enqueued only
            // after the recaptured image transferred, so the folder cannot
            // reappear on the worklist before QC re-reviews it.
            if (payload == null) break;
            final pgProject = await capped(
              'rework closure',
              () => projectId(payload),
            );
            if (pgProject == null) break;
            final pgBox = await boxIdOrNull(payload, pgProject);
            final seq = (payload['folder_seq'] as num?)?.toInt();
            final imageName = (payload['image_name'] as String?)?.trim() ?? '';
            int? pgFolder;
            if (pgBox != null && seq != null) {
              pgFolder =
                  folderIds['$pgBox|$seq'] ??
                  await _selectId(
                    session,
                    st.resolveFolderSql(pgBoxId: pgBox, folderSeq: seq),
                  );
              if (pgFolder != null) folderIds['$pgBox|$seq'] = pgFolder;
            }
            final pgImage = (pgFolder == null || imageName.isEmpty)
                ? null
                : await _selectId(
                    session,
                    st.resolveImageSql(
                      pgFolderId: pgFolder,
                      imageName: imageName,
                    ),
                  );
            if (pgFolder == null || pgImage == null) {
              // The image is normally already in PG (QC rejected it, so it
              // exists there), but a separation/rename can move it. Retry on
              // the normal backoff, then skip-ack so one stale closure can't
              // wedge the queue — the worklist item simply stays visible.
              if (record.attempts < 20) {
                throw StateError(
                  'rework target not in PG yet: box "${payload['box_name']}" '
                  'folder_seq=$seq image="$imageName" '
                  '(attempt ${record.attempts})',
                );
              }
              print(
                '⚠️ Dropping rework closure after ${record.attempts} '
                'attempts — target never appeared in PG: '
                'box="${payload['box_name']}" folder_seq=$seq '
                'image="$imageName"',
              );
              break;
            }
            final pgReworkUser = await capped(
              'rework closure',
              () => userId(payload),
            );
            if (pgReworkUser == null) break;
            await _exec(
              session,
              st.insertReworkClosedSql(
                payload,
                pgImageId: pgImage,
                pgFolderId: pgFolder,
                pgUserId: pgReworkUser,
              ),
            );
            break;

          default:
            // Unknown entity — defensively skip (acked, never retried).
            break;
        }
      }
    });
  }

  // ── Users-store pull ───────────────────────────────────────────────────────

  @override
  Future<UsersStore> pullStore() async {
    final conn = await _connect();
    final users = await _exec(conn, st.selectUsersSql());
    final projects = await _exec(conn, st.selectProjectsSql());
    final userProjects = await _exec(conn, st.selectUserProjectsSql());
    final appSettings = await _exec(conn, st.selectAppSettingsSql());
    return st.buildUsersStoreFromPgRows(
      users: [for (final r in users) r.toColumnMap()],
      projects: [for (final r in projects) r.toColumnMap()],
      userProjects: [for (final r in userProjects) r.toColumnMap()],
      appSettings: [for (final r in appSettings) r.toColumnMap()],
      now: DateTime.now(),
    );
  }

  @override
  Future<CaptureSnapshotCounts> pullCaptureSnapshot(
    String deviceId, {
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  }) async {
    final conn = await _connect();
    const pageSize = 5000;
    return conn.runTx(
      (session) async {
        Future<Result> page(String sql, int afterId) => session.execute(
          Sql.named(sql),
          parameters: {
            'device_id': deviceId,
            'after_id': afterId,
            'page_size': pageSize,
          },
        );

        var boxCount = 0;
        var folderCount = 0;
        var imageCount = 0;
        var after = 0;
        while (true) {
          final result = await page('''
        SELECT b.box_id, b.box_name, b.status, u.user_id AS user_key,
               p.project_id AS project_id, p.project_key,
               p.template::text AS template_json,
               b.created_at::text AS created_at,
               b.transfer_end_at::text AS transfer_end_at,
               b.transferred_to
        FROM capture_boxes b
        JOIN devices d ON d.id = b.device_id
        LEFT JOIN users u ON u.id = b.user_id
        LEFT JOIN projects p ON p.id = b.project_id
        WHERE d.device_id = @device_id
          AND b.is_deleted = FALSE AND b.box_id > @after_id
        ORDER BY b.box_id LIMIT @page_size
      ''', after);
          if (result.isEmpty) break;
          final rows = [
            for (final raw in result)
              CaptureSnapshotBox(
                id: _snapshotInt(raw.toColumnMap()['box_id']),
                boxName: _snapshotString(raw.toColumnMap()['box_name']),
                status: _snapshotString(raw.toColumnMap()['status']),
                userId: _snapshotNullableString(raw.toColumnMap()['user_key']),
                projectId: _snapshotNullableString(
                  raw.toColumnMap()['project_id'],
                ),
                projectKey: _snapshotNullableString(
                  raw.toColumnMap()['project_key'],
                ),
                templateJson: _snapshotNullableString(
                  raw.toColumnMap()['template_json'],
                ),
                createdAt: _snapshotNullableString(
                  raw.toColumnMap()['created_at'],
                ),
                transferEndAt: _snapshotNullableString(
                  raw.toColumnMap()['transfer_end_at'],
                ),
                transferredTo: _snapshotNullableString(
                  raw.toColumnMap()['transferred_to'],
                ),
              ),
          ];
          await onBoxes(rows);
          boxCount += rows.length;
          after = rows.last.id;
          if (result.length < pageSize) break;
        }

        after = 0;
        while (true) {
          final result = await page('''
        SELECT f.id, f.box_id, f.folder_seq, f.folder_name,
               f.cover_tag, f.image_tags, f.title, f.volume,
               f.start_date, f.end_date,
               f.archival_ref_no, f.record_type, f.place, f.language,
               f.record_custodian, f.capture_operator_id,
               f.capture_operator_name, f.digitizing_entity,
               f.source_created_at::text AS source_created_at,
               f.source_updated_at::text AS source_updated_at,
               f.is_deskewed, f.is_cropped, f.is_created_thumbnail,
               f.folder_path, f.thumbnail_path, f.qc_status
        FROM capture_folders f
        JOIN capture_boxes b ON b.box_id = f.box_id
        JOIN devices d ON d.id = b.device_id
        WHERE d.device_id = @device_id
          AND f.is_deleted = FALSE AND b.is_deleted = FALSE
          AND f.id > @after_id
        ORDER BY f.id LIMIT @page_size
      ''', after);
          if (result.isEmpty) break;
          final rows = <CaptureSnapshotFolder>[];
          for (final raw in result) {
            final row = raw.toColumnMap();
            rows.add(
              CaptureSnapshotFolder(
                id: _snapshotInt(row['id']),
                boxId: _snapshotInt(row['box_id']),
                folderSeq: _snapshotInt(row['folder_seq']),
                folderName: _snapshotNullableString(row['folder_name']),
                metadata: {
                  for (final key in const [
                    'cover_tag',
                    'image_tags',
                    'title',
                    'volume',
                    'start_date',
                    'end_date',
                    'archival_ref_no',
                    'record_type',
                    'place',
                    'language',
                    'record_custodian',
                    'capture_operator_id',
                    'capture_operator_name',
                    'digitizing_entity',
                  ])
                    key: row[key],
                },
                sourceCreatedAt: _snapshotNullableString(
                  row['source_created_at'],
                ),
                sourceUpdatedAt: _snapshotNullableString(
                  row['source_updated_at'],
                ),
                isDeskewed: row['is_deskewed'] == true,
                isCropped: row['is_cropped'] == true,
                isCreatedThumbnail: row['is_created_thumbnail'] == true,
                folderPath: _snapshotNullableString(row['folder_path']),
                thumbnailPath: _snapshotNullableString(row['thumbnail_path']),
                qcStatus: _snapshotNullableString(row['qc_status']),
              ),
            );
          }
          await onFolders(rows);
          folderCount += rows.length;
          after = rows.last.id;
          if (result.length < pageSize) break;
        }

        after = 0;
        while (true) {
          final result = await page('''
        SELECT i.id, i.folder_id, i.image_name, d.device_id,
               i.file_format, i.image_created_at::text AS image_created_at,
               i.image_updated_at::text AS image_updated_at
        FROM capture_images i
        JOIN capture_folders f ON f.id = i.folder_id
        JOIN capture_boxes b ON b.box_id = f.box_id
        JOIN devices d ON d.id = b.device_id
        WHERE d.device_id = @device_id
          AND f.is_deleted = FALSE AND b.is_deleted = FALSE
          AND i.id > @after_id
        ORDER BY i.id LIMIT @page_size
      ''', after);
          if (result.isEmpty) break;
          final rows = <CaptureSnapshotImage>[];
          for (final raw in result) {
            final row = raw.toColumnMap();
            rows.add(
              CaptureSnapshotImage(
                id: _snapshotInt(row['id']),
                folderId: _snapshotInt(row['folder_id']),
                imageName: _snapshotString(row['image_name']),
                deviceId: _snapshotString(row['device_id']),
                fileFormat: _snapshotString(row['file_format']),
                imageCreatedAt: _snapshotNullableString(
                  row['image_created_at'],
                ),
                imageUpdatedAt: _snapshotNullableString(
                  row['image_updated_at'],
                ),
              ),
            );
          }
          await onImages(rows);
          imageCount += rows.length;
          after = rows.last.id;
          if (result.length < pageSize) break;
        }

        return CaptureSnapshotCounts(
          boxes: boxCount,
          folders: folderCount,
          images: imageCount,
        );
      },
      settings: TransactionSettings(
        isolationLevel: IsolationLevel.repeatableRead,
        accessMode: AccessMode.readOnly,
      ),
    );
  }

  // ── Box-name uniqueness pull ──────────────────────────────────────────────

  @override
  Future<Set<String>> fetchBoxNames(String projectKey) async {
    final conn = await _connect();
    final result = await _exec(conn, st.fetchBoxNamesSql(projectKey));
    return {for (final row in result) row[0] as String};
  }

  @override
  Future<void> close() async {
    final conn = _conn;
    _conn = null;
    if (conn != null) {
      try {
        await conn.close();
      } catch (_) {
        // Already gone — nothing to clean up.
      }
    }
  }
}

int _snapshotInt(Object? value) => (value as num?)?.toInt() ?? 0;
String _snapshotString(Object? value) => value?.toString() ?? '';
String? _snapshotNullableString(Object? value) {
  final valueString = value?.toString();
  return valueString == null || valueString.isEmpty ? null : valueString;
}
