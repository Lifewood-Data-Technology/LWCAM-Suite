// ignore_for_file: avoid_print

/// SQL statement builders for the cloud schema in
/// `LWCam Workflow & SQL update/LWCam_database_20260720.sql`. Pure Dart — no
/// postgres import — so every statement's SQL and parameters are unit-testable
/// without a connection (the CI has no live PG). `PgSyncSink` executes these.
///
/// Identity model: the cloud uses BIGINT identity PKs; LWCAM rows are created
/// offline and never know them. Every writer here therefore takes the parent
/// ids as ALREADY-RESOLVED integers (the sink resolves them per batch via the
/// resolve* SELECTs below, keyed by the natural keys carried in outbox
/// payloads) and every upsert conflicts on the entity's natural UNIQUE key:
/// users(user_id), projects(project_id), devices(device_id),
/// capture_boxes(project_id, box_name), capture_folders(box_id, folder_seq),
/// capture_images(folder_id, image_name).
///
/// Timestamps are cast with CAST(@x AS timestamptz), which resolves a string
/// carrying no offset using the SESSION time zone — and the postgres package
/// pins that to UTC on connect (its ConnectionSettings.timeZone default; see
/// pg_client.dart). A naive local string therefore reads as UTC, which put every
/// LWCAM timestamp EIGHT HOURS in the future on a +08 station until 2026-07-30.
/// So nothing here may emit a naive string: [tsOrNull] converts real instants to
/// UTC. Keyed archive dates (`capture_folders.start_date`/`end_date`) are TEXT
/// and bind verbatim — see [textOrNull].
library;

import 'dart:convert';

import '../models/app_user.dart';
import '../models/metadata_template.dart';
import '../models/project.dart';

class PgStatement {
  final String sql;
  final Map<String, Object?> parameters;
  const PgStatement(this.sql, this.parameters);
}

/// UTC ISO-8601 string for an EVENT INSTANT ([value] a moment in time: created,
/// transferred, closed …), or null when it does not parse — a keyed free-text
/// value must never poison a batch with something uncastable.
///
/// The `.toUtc()` is the whole point. LWCAM's local rows store naive local
/// strings (`"2026-07-30T11:28:37"`, no offset) and are read back for local
/// display, so they cannot be changed at the source; the conversion has to
/// happen here, at the PG boundary. Without it the session's UTC zone reads that
/// naive string as UTC and the row lands +8h in the future on a Singapore
/// station. A string that already carries `Z` or an offset parses to the right
/// instant and passes through unshifted.
///
/// NOT for keyed archive dates — those are TEXT, see [textOrNull].
String? tsOrNull(Object? value) {
  final s = value?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  return DateTime.tryParse(s)?.toUtc().toIso8601String();
}

/// Trimmed text, or null when blank. The binding for `start_date`/`end_date`:
/// an archive date is stored VERBATIM as keyed ("1914", "1914-06",
/// "1877-Mar-05") — the column is TEXT and nothing in the pipeline parses it.
String? textOrNull(Object? value) {
  final s = value?.toString().trim() ?? '';
  return s.isEmpty ? null : s;
}

// ── FK resolution (sink caches results per drained batch) ──────────────────

PgStatement resolveUserSql(String username) => PgStatement(
  'SELECT id FROM users WHERE user_id = @user_id',
  {'user_id': username},
);

/// Resolves via `project_key` — the stable client identity — never
/// `project_id`, which is a human-editable label LWCam Admin can rename
/// freely without minting a duplicate cloud row.
PgStatement resolveProjectByKeySql(String projectKey) => PgStatement(
  'SELECT id FROM projects WHERE project_key = @project_key',
  {'project_key': projectKey},
);

PgStatement resolveDeviceSql(String deviceId) => PgStatement(
  'SELECT id FROM devices WHERE device_id = @device_id',
  {'device_id': deviceId},
);

/// Self-heal: a capture device that recorded boxes before its first gated
/// login has no devices row yet — create one bound to the payload project's
/// location code. No-op when the row exists.
PgStatement insertDeviceIfMissingSql({
  required String deviceId,
  required int pgProjectId,
}) => PgStatement(
  'INSERT INTO devices (device_id, country_location_code) '
  'SELECT @device_id, p.country_location_code FROM projects p '
  'WHERE p.id = @project_id '
  'ON CONFLICT (device_id) DO NOTHING',
  {'device_id': deviceId, 'project_id': pgProjectId},
);

/// [ownerDeviceId], when given, additionally requires the box belong to
/// that device — used by station-owned entities (capture_boxes/folders/
/// images) so a conflicted station's children never resolve to a foreign
/// station's box. Omitted for the processing/rework paths, which target a
/// folder regardless of which station owns it.
PgStatement resolveBoxSql({
  required int pgProjectId,
  required String boxName,
  String? ownerDeviceId,
}) => PgStatement(
  'SELECT box_id FROM capture_boxes '
  'WHERE project_id = @project_id AND box_name = @box_name'
  '${ownerDeviceId != null ? ' AND device_id = (SELECT id FROM devices WHERE device_id = @owner_device_id)' : ''}',
  {
    'project_id': pgProjectId,
    'box_name': boxName,
    if (ownerDeviceId != null) 'owner_device_id': ownerDeviceId,
  },
);

PgStatement resolveFolderSql({required int pgBoxId, required int folderSeq}) =>
    PgStatement(
      'SELECT id FROM capture_folders '
      'WHERE box_id = @box_id AND folder_seq = @folder_seq',
      {'box_id': pgBoxId, 'folder_seq': folderSeq},
    );

// ── capture_boxes ───────────────────────────────────────────────────────────

/// Pre-step for a renamed box: the cloud row is keyed by (project_id,
/// box_name), so move the existing row to the new name before the upsert —
/// otherwise the upsert would mint a duplicate. Idempotent: matches nothing
/// once the rename has been applied (or when the new name already exists).
PgStatement boxRenameFixupSql({
  required int pgProjectId,
  required String renamedFrom,
  required String newName,
}) => PgStatement(
  'UPDATE capture_boxes SET box_name = @new_name '
  'WHERE project_id = @project_id AND box_name = @renamed_from '
  'AND NOT EXISTS (SELECT 1 FROM capture_boxes '
  '  WHERE project_id = @project_id AND box_name = @new_name)',
  {'project_id': pgProjectId, 'renamed_from': renamedFrom, 'new_name': newName},
);

/// [payload] is the local capture_boxes row snapshot; ids are resolved.
/// updated_at is left to the PG trigger on UPDATE (and its DEFAULT on
/// INSERT); local-only columns never appear here.
PgStatement boxUpsertSql(
  Map<String, dynamic> payload, {
  required int pgUserId,
  required int pgDeviceId,
  required int pgProjectId,
}) => PgStatement(
  'INSERT INTO capture_boxes (box_name, device_id, status, user_id, '
  'project_id, created_at, transfer_start_at, transfer_end_at, '
  'transferred_to) '
  'VALUES (@box_name, @device_id, @status, @user_id, @project_id, '
  'COALESCE(CAST(@created_at AS timestamptz), clock_timestamp()), '
  'CAST(@transfer_start_at AS timestamptz), '
  'CAST(@transfer_end_at AS timestamptz), @transferred_to) '
  'ON CONFLICT (project_id, box_name) DO UPDATE SET '
  'device_id = EXCLUDED.device_id, status = EXCLUDED.status, '
  'user_id = EXCLUDED.user_id, '
  'transfer_start_at = EXCLUDED.transfer_start_at, '
  'transfer_end_at = EXCLUDED.transfer_end_at, '
  'transferred_to = EXCLUDED.transferred_to, '
  'is_deleted = FALSE, deleted_at = NULL '
  'WHERE capture_boxes.device_id = EXCLUDED.device_id '
  'RETURNING box_id',
  {
    'box_name': payload['box_name'],
    'device_id': pgDeviceId,
    'status': payload['status'] ?? 'OPEN',
    'user_id': pgUserId,
    'project_id': pgProjectId,
    'created_at': tsOrNull(payload['created_at']),
    'transfer_start_at': tsOrNull(payload['transfer_start_at']),
    'transfer_end_at': tsOrNull(payload['transfer_end_at']),
    'transferred_to': payload['transferred_to'],
  },
);

// ── capture_folders ─────────────────────────────────────────────────────────

/// Writes the LWCAM-owned columns ONLY — never group_id (QC mints it) or any
/// QC/pipeline column (client_qc_status, is_deskewed, folder_path, …): those
/// belong to downstream stages and PG fills their defaults on INSERT.
/// folder_name is NOT NULL in the cloud but locally null until transfer prep
/// — COALESCE to ''. A locally reused folder_seq revives a soft-deleted
/// cloud row (is_deleted=FALSE in DO UPDATE).
PgStatement folderUpsertSql(
  Map<String, dynamic> payload, {
  required int pgBoxId,
  required int pgDeviceId,
}) {
  const metaCols = [
    'cover_tag', 'image_tags', 'title', 'volume', 'archival_ref_no',
    'record_type', 'place', 'language', 'record_custodian',
    'capture_operator_id', 'capture_operator_name', 'digitizing_entity', //
  ];
  final assignments = [
    'folder_name = EXCLUDED.folder_name',
    'device_id = EXCLUDED.device_id',
    for (final c in metaCols) '$c = EXCLUDED.$c',
    'start_date = EXCLUDED.start_date',
    'end_date = EXCLUDED.end_date',
    'source_created_at = EXCLUDED.source_created_at',
    'source_updated_at = EXCLUDED.source_updated_at',
    'is_deleted = FALSE',
    'deleted_at = NULL',
  ].join(', ');
  return PgStatement(
    'INSERT INTO capture_folders (folder_name, box_id, device_id, folder_seq, '
    '${metaCols.join(', ')}, start_date, end_date, '
    'source_created_at, source_updated_at) '
    "VALUES (COALESCE(@folder_name, ''), @box_id, @device_id, @folder_seq, "
    '${metaCols.map((c) => '@$c').join(', ')}, '
    '@start_date, @end_date, '
    'CAST(@source_created_at AS timestamptz), '
    'CAST(@source_updated_at AS timestamptz)) '
    'ON CONFLICT (box_id, folder_seq) DO UPDATE SET $assignments '
    'WHERE capture_folders.device_id = EXCLUDED.device_id '
    'RETURNING id',
    {
      'folder_name': payload['folder_name'],
      'box_id': pgBoxId,
      'device_id': pgDeviceId,
      'folder_seq': payload['folder_seq'],
      for (final c in metaCols) c: payload[c],
      // Keyed archive dates are TEXT, bound verbatim — see textOrNull.
      'start_date': textOrNull(payload['start_date']),
      'end_date': textOrNull(payload['end_date']),
      'source_created_at': tsOrNull(payload['source_created_at']),
      'source_updated_at': tsOrNull(payload['source_updated_at']),
    },
  );
}

/// Same shape as [folderSoftDeleteSql], one level up. The sink resolves the
/// box under the deleting device's own scope first, so another device's box of
/// the same name is never touched. Reviving the name later is the upsert's
/// job (its DO UPDATE resets is_deleted).
PgStatement boxSoftDeleteSql({required int pgBoxId}) => PgStatement(
  'UPDATE capture_boxes SET is_deleted = TRUE, deleted_at = now() '
  'WHERE box_id = @box_id',
  {'box_id': pgBoxId},
);

PgStatement folderSoftDeleteSql({
  required int pgBoxId,
  required int folderSeq,
}) => PgStatement(
  'UPDATE capture_folders SET is_deleted = TRUE, deleted_at = now() '
  'WHERE box_id = @box_id AND folder_seq = @folder_seq',
  {'box_id': pgBoxId, 'folder_seq': folderSeq},
);

/// The image-processing phase's per-folder result — the ONLY statement that
/// writes any pipeline column on capture_folders. Sets the three completion
/// flags + the processed/thumbnail paths, and moves qc_status to 'PENDING'
/// only from a pre-QC state (NULL/''/'PENDING'/'REWORK'). A folder QC has
/// already moved to PASS keeps it: the outbox row (and LWIP's own report) can
/// land days after LWIP finished — LWCAM was closed at the tick, LWIP reported
/// the folder itself, QC approved and exported — and an unconditional reset
/// put a delivered folder back in the QC queue. Rework still re-enters QC
/// because QC parks a folder in 'REWORK' before any recapture. Deliberately
/// never touches the QC-owned columns group_id/client_qc_status/client_rework;
/// updated_at is handled by the capture_folders PG trigger. [pgFolderId] is
/// resolved by the sink from the payload's natural keys. Mirrored verbatim by
/// LWIP's cloud_report.py — change both.
PgStatement folderProcessingUpdateSql(
  Map<String, dynamic> payload, {
  required int pgFolderId,
}) => PgStatement(
  'UPDATE capture_folders SET '
  'is_deskewed = TRUE, is_cropped = TRUE, '
  'is_created_thumbnail = @is_created_thumbnail, '
  'folder_path = @folder_path, thumbnail_path = @thumbnail_path, '
  'qc_status = CASE WHEN qc_status IS NULL '
  "OR upper(qc_status) IN ('', 'PENDING', 'REWORK') "
  "THEN 'PENDING' ELSE qc_status END "
  'WHERE id = @folder_id',
  {
    'is_created_thumbnail': payload['is_created_thumbnail'] == true,
    'folder_path': payload['folder_path'],
    'thumbnail_path': payload['thumbnail_path'],
    'folder_id': pgFolderId,
  },
);

// ── capture_images ──────────────────────────────────────────────────────────

/// Pre-step for an image whose file was renamed at transfer time.
///
/// A capture records the DEVICE filename (IMG_1234.jpg) the moment the photo is
/// pulled, so the dashboard sees it immediately; the transfer then writes the
/// file as `<deviceId>_<stem>_<NNN>.jpg`, the suffix allocated against
/// destination disk state and therefore unknowable at capture. The cloud row is
/// keyed by (folder_id, image_name), so move it to the final name before the
/// upsert — otherwise the upsert mints a duplicate and QC's
/// folder_path/image_name lookup finds neither file.
///
/// Same shape as [boxRenameFixupSql]: idempotent, matching nothing once applied
/// (or when the new name is already present). When the capture-time upsert never
/// reached PG at all, this matches nothing and the upsert that follows simply
/// INSERTs under the final name — which is why no affected-row check is needed.
PgStatement imageRenameFixupSql({
  required int pgFolderId,
  required String renamedFrom,
  required String newName,
}) => PgStatement(
  'UPDATE capture_images SET image_name = @new_name '
  'WHERE folder_id = @folder_id AND image_name = @renamed_from '
  'AND NOT EXISTS (SELECT 1 FROM capture_images '
  '  WHERE folder_id = @folder_id AND image_name = @new_name)',
  {'folder_id': pgFolderId, 'renamed_from': renamedFrom, 'new_name': newName},
);

PgStatement imageUpsertSql(
  Map<String, dynamic> payload, {
  required int pgDeviceId,
  required int pgFolderId,
}) => PgStatement(
  'INSERT INTO capture_images (image_name, device_id, folder_id, '
  'file_format, image_created_at) '
  'VALUES (@image_name, @device_id, @folder_id, @file_format, '
  'COALESCE(CAST(@image_created_at AS timestamptz), clock_timestamp())) '
  'ON CONFLICT (folder_id, image_name) DO UPDATE SET '
  'file_format = EXCLUDED.file_format, image_updated_at = now()',
  {
    'image_name': payload['image_name'],
    'device_id': pgDeviceId,
    'folder_id': pgFolderId,
    'file_format': payload['file_format'] ?? 'jpg',
    'image_created_at': tsOrNull(payload['image_created_at']),
  },
);

/// Hard DELETE — capture_images has no soft-delete columns in the cloud.
PgStatement imageDeleteSql({
  required int pgFolderId,
  required String imageName,
}) => PgStatement(
  'DELETE FROM capture_images '
  'WHERE folder_id = @folder_id AND image_name = @image_name',
  {'folder_id': pgFolderId, 'image_name': imageName},
);

// ── rework_logs (QC → capture: recapture requests) ──────────────────────────

/// Resolves a cloud image id from its folder + name — the rework closure needs
/// it because rework_logs.image_id is a real FK, not a natural key.
PgStatement resolveImageSql({
  required int pgFolderId,
  required String imageName,
}) => PgStatement(
  'SELECT id FROM capture_images '
  'WHERE folder_id = @folder_id AND image_name = @image_name',
  {'folder_id': pgFolderId, 'image_name': imageName},
);

/// The folder metadata columns an operator may correct during rework — the
/// allowlist [folderMetadataPatchSql] validates against, so a column name can
/// never reach the SQL text from a payload key.
///
/// Same set folderUpsertSql writes (which spells them out separately because it
/// needs its own INSERT/EXCLUDED ordering); the two must stay in step.
const List<String> kFolderMetadataColumns = [
  'cover_tag', 'image_tags', 'title', 'volume', 'archival_ref_no',
  'record_type', 'place', 'language', 'record_custodian',
  'capture_operator_id', 'capture_operator_name', 'digitizing_entity',
  'start_date', 'end_date', //
];

/// MetadataTemplate field id → capture_folders column, for the 8 fields with
/// real CaptureFolder storage (see metadata_template.dart's field ids). The
/// other 6 are fixed/mapped template values with no per-folder storage, so an
/// operator cannot edit them and a rework patch never carries them.
const Map<String, String> kFolderMetadataColumnByFieldId = {
  'coverTag': 'cover_tag',
  'imageTags': 'image_tags',
  'title': 'title',
  'volume': 'volume',
  'startDate': 'start_date',
  'endDate': 'end_date',
  'archivalRefNo': 'archival_ref_no',
  'recordType': 'record_type',
};

/// Corrects the folder metadata an operator fixed during rework, writing ONLY
/// the columns in [changed].
///
/// Deliberately not folderUpsertSql: that one writes every metadata column from
/// LWCAM's local row, which would revert QC's own edits to the columns the
/// operator did not touch. [changed] is computed as "local value vs the cloud
/// value read when the box was opened", which is also what makes outbox
/// coalescing safe — a newer payload is always a superset of an undrained older
/// one, so no field is lost.
///
/// Throws on a column outside [kFolderMetadataColumns] rather than
/// interpolating it.
PgStatement folderMetadataPatchSql(
  Map<String, Object?> changed, {
  required int pgFolderId,
}) {
  final unknown = changed.keys.where(
    (c) => !kFolderMetadataColumns.contains(c),
  );
  if (unknown.isNotEmpty) {
    throw ArgumentError('Not a folder metadata column: ${unknown.join(', ')}');
  }
  if (changed.isEmpty) {
    throw ArgumentError('folderMetadataPatchSql needs at least one column');
  }
  final assignments = changed.keys.map((c) => '$c = @$c');
  return PgStatement(
    'UPDATE capture_folders SET ${assignments.join(', ')} WHERE id = @folder_id',
    {
      // Every column is TEXT, start_date/end_date included — verbatim.
      for (final c in changed.keys) c: textOrNull(changed[c]),
      'folder_id': pgFolderId,
    },
  );
}

/// Puts a folder back in the QC queue after a metadata-only rework fix.
///
/// The SECOND writer of pipeline columns, alongside folderProcessingUpdateSql
/// (which AGENTS.md still describes as the sole one — read this with it). It has
/// to exist: a metadata-only correction changes no file, so the folder's input
/// fingerprint is identical, LWIP will never reprocess it, and nothing else
/// would ever move it off 'REWORK'. Used only from the rework submit path.
///
/// The processing flags are restored alongside qc_status because QC's reject
/// ZEROES them (its design doc §6 — reject_task sets all three false), and only
/// a reprocess would set them back. A metadata-only fix has no reprocess, so
/// without this the flags stayed false forever on a folder whose files are, in
/// fact, processed — observed live 2026-07-31 on a separation child that went
/// reject -> metadata fix -> approve and ended PASS with is_deskewed=false.
/// Restoring them is factually correct: the fix changed metadata, not files.
///
/// [isCreatedThumbnail] is null when this PC could not read LWIP's manifest
/// (LWIP is on another PC and its path is not reachable here): the column is
/// then left UNTOUCHED rather than overwritten with a guessed false.
PgStatement folderQcStatusPendingSql({
  required int pgFolderId,
  bool? isCreatedThumbnail,
}) => PgStatement(
  "UPDATE capture_folders SET qc_status = 'PENDING', "
  'is_deskewed = TRUE, is_cropped = TRUE'
  '${isCreatedThumbnail == null ? '' : ', is_created_thumbnail = @is_created_thumbnail'} '
  'WHERE id = @folder_id',
  {
    'folder_id': pgFolderId,
    if (isCreatedThumbnail != null) 'is_created_thumbnail': isCreatedThumbnail,
  },
);

/// The operator's OPEN recapture requests.
///
/// rework_logs is APPEND-ONLY: QC appends an OPEN row per rejected image, and
/// LWCAM appends a CLOSED row once the recaptured image has been transferred.
/// "Still open" therefore means *the latest row for that image is OPEN* — hence
/// DISTINCT ON rather than a plain `WHERE rework_status = 'OPEN'`, which would
/// resurrect every historical request forever.
///
/// Scoped to the rows assigned to [username] (rework_logs.assigned_uid is the
/// box's capture operator). folder_path is included so the caller can derive the
/// LWIP input file to overwrite.
///
/// The folder's metadata columns ([kFolderMetadataColumns]) trail the fixed
/// columns so the operator's edit form can be seeded from the CLOUD row. That
/// matters: QC edits these same columns, and seeding from LWCAM's local row —
/// which still holds what was keyed at capture time — would silently revert
/// every QC correction on the folder. Repeating them per image is redundant but
/// saves a second round trip; the UI takes the first item of each folder.
PgStatement selectOpenReworkSql(String username) => PgStatement(
  'SELECT latest.id, p.project_key, p.project_id, b.box_name, '
  'f.folder_seq, f.folder_name, f.folder_path, f.qc_status, '
  'i.image_name, latest.rework_comments, latest.rework_type, '
  'latest.created_at, '
  '${kFolderMetadataColumns.map((c) => 'f.$c').join(', ')}, '
  // Page position of this image within its folder, appended AFTER the metadata
  // columns so ReworkService's positional read stays anchored on
  // kFolderMetadataColumns.length. (image_created_at, id) is QC's canonical
  // page order everywhere (ordered_official_images), and a QC commit rewrites
  // image_created_at to bake a reorder into it.
  'pos.page_no, pos.page_count '
  'FROM ('
  '  SELECT DISTINCT ON (r.image_id) r.* '
  '  FROM rework_logs r '
  '  JOIN users u ON u.id = r.assigned_uid '
  '  WHERE r.image_id IS NOT NULL AND u.user_id = @user_id '
  '  ORDER BY r.image_id, r.created_at DESC, r.id DESC'
  ') latest '
  'JOIN capture_images i ON i.id = latest.image_id '
  'JOIN capture_folders f ON f.id = latest.folder_id '
  'JOIN capture_boxes b ON b.box_id = f.box_id '
  'JOIN projects p ON p.id = b.project_id '
  // LATERAL, not two correlated subqueries (one folder scan instead of two)
  // and not ROW_NUMBER() OVER (PARTITION BY folder_id): Postgres cannot push
  // the image predicate through a window, so that form would scan every row of
  // capture_images. Each probe here is an index scan of one folder
  // (uq_capture_images_folder_image is led by folder_id).
  'LEFT JOIN LATERAL ('
  '  SELECT COUNT(*) AS page_count, '
  '         COUNT(*) FILTER ('
  '           WHERE (i2.image_created_at, i2.id) <= (i.image_created_at, i.id)'
  '         ) AS page_no '
  '  FROM capture_images i2 WHERE i2.folder_id = i.folder_id'
  ') pos ON TRUE '
  "WHERE latest.rework_status = 'OPEN' "
  'AND f.is_deleted = FALSE AND b.is_deleted = FALSE '
  'ORDER BY b.box_name, f.folder_seq, i.image_created_at, i.id',
  {'user_id': username},
);

/// Appends the CLOSED row that retires a recapture request.
///
/// Append-only (never an UPDATE) so the request history survives, and written by
/// LWCAM only after the recaptured image has actually been transferred — that
/// ordering is what stops the item reappearing on the worklist before QC has
/// re-reviewed it.
PgStatement insertReworkClosedSql(
  Map<String, dynamic> payload, {
  required int pgImageId,
  required int pgFolderId,
  required int pgUserId,
}) => PgStatement(
  'INSERT INTO rework_logs (image_id, assigned_uid, folder_id, created_at, '
  'rework_comments, rework_status, rework_type) '
  'VALUES (@image_id, @assigned_uid, @folder_id, '
  'COALESCE(CAST(@created_at AS timestamptz), clock_timestamp()), '
  "@rework_comments, 'CLOSED', @rework_type)",
  {
    'image_id': pgImageId,
    'assigned_uid': pgUserId,
    'folder_id': pgFolderId,
    'created_at': tsOrNull(payload['closed_at']),
    'rework_comments':
        (payload['rework_comments'] as String?) ?? 'Recaptured in LWCAM',
    'rework_type': (payload['rework_type'] as String?) ?? 'Recapture',
  },
);

// ── Pull: rebuild the local snapshot from PG ────────────────────────────────
//
// PostgreSQL is the source of truth for users/projects/app_settings; LWCam
// Admin owns every write to them (see its admin_pg_statements.dart). LWCAM
// only pulls — these 4 SELECTs run once at the START of every sync tick,
// their rows rebuild a fresh [UsersStore], and the result overwrites the
// local snapshot wholesale (see PgSyncSink.pullStore / UsersStoreService).

PgStatement selectUsersSql() => const PgStatement(
  'SELECT u.user_id, u.password, u.active, u.must_change_password, '
  'u.roles, u.device_id, u.created_at, u.last_login_at, '
  'c.user_id AS created_by '
  'FROM users u LEFT JOIN users c ON c.id = u.created_by '
  'WHERE u.is_deleted = FALSE',
  {},
);

PgStatement selectProjectsSql() => const PgStatement(
  'SELECT project_key, project_id, project_name, country_location_code, '
  "start_date, has_data, template::text, created_at "
  'FROM projects WHERE is_deleted = FALSE',
  {},
);

PgStatement selectUserProjectsSql() => const PgStatement(
  'SELECT u.user_id, p.project_key, r.role_name FROM user_projects up '
  'JOIN users u ON u.id = up.user_id '
  'JOIN projects p ON p.id = up.project_id '
  'JOIN roles r ON r.id = up.role_id '
  'WHERE u.is_deleted = FALSE AND p.is_deleted = FALSE',
  {},
);

PgStatement selectAppSettingsSql() =>
    const PgStatement('SELECT key, value FROM app_settings', {});

/// Rebuilds a [UsersStore] from the 4 pull SELECTs' decoded rows (each a
/// `Map<String, Object?>` — e.g. via the postgres package's
/// `Result.toColumnMap()`). Pure and unit-testable without a connection.
/// `updatedAt` is stamped as the pull time (there is no meaningful "last PG
/// write" timestamp to carry, and this is exactly what the login page shows
/// as "last synced").
UsersStore buildUsersStoreFromPgRows({
  required List<Map<String, Object?>> users,
  required List<Map<String, Object?>> projects,
  required List<Map<String, Object?>> userProjects,
  required List<Map<String, Object?>> appSettings,
  required DateTime now,
}) {
  // Roles are global (users.roles), while project grants are role-specific.
  // Keeping the pairs here prevents a QC/Admin project becoming a Capture
  // project for a mixed-role account.
  final projectKeysByUser = <String, Set<String>>{};
  final roleProjectKeysByUser = <String, Map<UserRole, Set<String>>>{};
  final extraRoleProjectKeysByUser = <String, Map<String, Set<String>>>{};
  for (final row in userProjects) {
    final username = row['user_id']?.toString() ?? '';
    final projectKey = row['project_key']?.toString() ?? '';
    final roleName = row['role_name']?.toString() ?? '';
    final role = UserRole.fromJson(roleName);
    if (username.isEmpty || projectKey.isEmpty || roleName.isEmpty) continue;
    if (role == null) {
      (extraRoleProjectKeysByUser[username] ??= {})[roleName] ??= <String>{};
      extraRoleProjectKeysByUser[username]![roleName]!.add(projectKey);
      continue;
    }
    (projectKeysByUser[username] ??= {}).add(projectKey);
    (roleProjectKeysByUser[username] ??= {})[role] ??= <String>{};
    roleProjectKeysByUser[username]![role]!.add(projectKey);
  }

  final appUsers = [
    for (final row in users)
      AppUser(
        username: row['user_id']?.toString() ?? '',
        passwordHash: row['password']?.toString() ?? '',
        roles: _rolesFromColumn(row['roles']),
        extraRoles: _extraRolesFromColumn(row['roles']),
        deviceId: _nullIfEmpty(row['device_id']?.toString()),
        active: row['active'] as bool? ?? true,
        mustChangePassword: row['must_change_password'] as bool? ?? false,
        createdAt: _asDateTime(row['created_at']),
        createdBy: row['created_by']?.toString(),
        lastLoginAt: _asDateTime(row['last_login_at']),
        projectKeys: projectKeysByUser[row['user_id']?.toString()] ?? const {},
        roleProjectKeys:
            roleProjectKeysByUser[row['user_id']?.toString()] ?? const {},
        extraRoleProjectKeys:
            extraRoleProjectKeysByUser[row['user_id']?.toString()] ?? const {},
      ),
  ];

  final projectModels = [
    for (final row in projects)
      Project(
        key: row['project_key']?.toString() ?? '',
        projectId: row['project_id']?.toString() ?? '',
        name: row['project_name']?.toString() ?? '',
        countryLocationCode: row['country_location_code']?.toString(),
        startDate:
            _asDateTime(row['start_date']) ??
            DateTime.fromMillisecondsSinceEpoch(0),
        hasData: row['has_data'] as bool? ?? false,
        createdAt: _asDateTime(row['created_at']),
        template: _templateFromColumn(row['template']),
      ),
  ];

  final settingsByKey = {
    for (final row in appSettings)
      row['key']?.toString() ?? '': row['value']?.toString(),
  };
  final settings = SharedAppSettings(
    metadataKeyingEnabled: settingsByKey['metadata_keying_enabled'] == 'true',
    defaultTempPasswordHash: settingsByKey['default_temp_password_hash'],
    superAdminPasswordHash: settingsByKey['superadmin_password_hash'],
    shutterKeybind: kShutterKeybinds.contains(settingsByKey['shutter_keybind'])
        ? settingsByKey['shutter_keybind']!
        : 'Space',
    shutterMethod: kShutterMethods.contains(settingsByKey['shutter_method'])
        ? settingsByKey['shutter_method']!
        : 'tap',
    shutterTapXPercent:
        double.tryParse(settingsByKey['shutter_tap_x_percent'] ?? '') ?? 50,
    shutterTapYPercent:
        double.tryParse(settingsByKey['shutter_tap_y_percent'] ?? '') ?? 90,
  );

  return UsersStore(
    updatedAt: now,
    updatedBy: 'pg-pull',
    settings: settings,
    users: appUsers,
    projects: projectModels,
  );
}

/// `users.roles` is a comma-joined string ('admin', 'capture', or
/// 'admin,capture'); an empty/unknown segment is dropped, not fatal.
Set<UserRole> _rolesFromColumn(Object? value) {
  final s = value?.toString() ?? '';
  if (s.trim().isEmpty) return const {};
  return s.split(',').map(UserRole.fromJson).whereType<UserRole>().toSet();
}

/// Segments of `users.roles` this app has no [UserRole] for — `qc` and any other
/// module's role. Kept on the [AppUser] so the snapshot rewrite that follows
/// every pull carries them through; LWCam Admin pushes from that same file.
Set<String> _extraRolesFromColumn(Object? value) {
  final s = value?.toString() ?? '';
  if (s.trim().isEmpty) return const {};
  return s
      .split(',')
      .map((segment) => segment.trim())
      .where(
        (segment) => segment.isNotEmpty && UserRole.fromJson(segment) == null,
      )
      .toSet();
}

String? _nullIfEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

DateTime? _asDateTime(Object? value) {
  if (value is DateTime) return value;
  return DateTime.tryParse(value?.toString() ?? '');
}

/// `projects.template` (jsonb) may arrive as an already-decoded [Map] or as
/// its raw JSON [String], depending on the driver path — handle both.
MetadataTemplate? _templateFromColumn(Object? value) {
  if (value == null) return null;
  if (value is Map) {
    return MetadataTemplate.fromJson(value.cast<String, Object?>());
  }
  final s = value.toString().trim();
  if (s.isEmpty) return null;
  try {
    final decoded = jsonDecode(s);
    return decoded is Map
        ? MetadataTemplate.fromJson(decoded.cast<String, Object?>())
        : null;
  } catch (_) {
    return null;
  }
}

// ── LWCAM's PG write whitelist ──────────────────────────────────────────────
//
// PostgreSQL is the source of truth for users/projects; LWCAM only PULLS
// them (see the pull pipeline). These three writes are the sole exceptions
// — capture-side events that must land in PG directly, never routed through
// the NAS/local-JSON write path LWCam Admin owns.

/// A forced first-login/reset password change. `lwcam_capture` has no UPDATE
/// on `users.password`; it calls the database function (migration 006), which
/// checks the OLD password itself and returns true only if the row changed.
PgStatement changeOwnPasswordSql({
  required String username,
  required String oldPassword,
  required String bcryptHash,
}) => PgStatement(
  'SELECT lwcam_change_own_password(@user_id, @old_password, @new_hash) AS ok',
  {'user_id': username, 'old_password': oldPassword, 'new_hash': bcryptHash},
);

/// Best-effort last-login stamp — never blocks login on failure.
PgStatement recordLoginSql(String username) => PgStatement(
  'UPDATE users SET last_login_at = now() WHERE user_id = @user_id',
  {'user_id': username},
);

/// Best-effort advisory stamp: a box was created under this project. Never
/// clears the flag — `has_data` only ever goes false→true here.
PgStatement markProjectHasDataSql(String projectKey) => PgStatement(
  'UPDATE projects SET has_data = TRUE '
  'WHERE project_key = @project_key AND has_data = FALSE',
  {'project_key': projectKey},
);

// ── Box-name uniqueness pull ────────────────────────────────────────────────

PgStatement fetchBoxNamesSql(String projectKey) => PgStatement(
  'SELECT b.box_name FROM capture_boxes b '
  'JOIN projects p ON p.id = b.project_id '
  'WHERE p.project_key = @project_key AND b.is_deleted = FALSE',
  {'project_key': projectKey},
);

// ── One-time catch-up (UploadStatsDB.queueCaptureRowsMissingFromCloud) ─────

/// Every box, folder and image PG holds for [deviceId], one row per image (a
/// box or folder with none still yields one row). Soft-deleted rows are
/// INCLUDED on purpose: a row QC or LWCam Admin deleted must count as present,
/// or the catch-up would send it again and revive it.
PgStatement fetchCaptureKeysSql(String deviceId) => PgStatement(
  'SELECT p.project_key, b.box_name, f.folder_seq, i.image_name '
  'FROM capture_boxes b '
  'JOIN devices d ON d.id = b.device_id '
  'LEFT JOIN projects p ON p.id = b.project_id '
  'LEFT JOIN capture_folders f ON f.box_id = b.box_id '
  'LEFT JOIN capture_images i ON i.folder_id = f.id '
  'WHERE d.device_id = @device_id',
  {'device_id': deviceId},
);

// ── Schema level + service heartbeat (migration 007) ────────────────────────

/// The database's schema level: the highest numeric prefix in
/// `schema_migrations` (0 when empty; a missing table raises 42P01, which the
/// sink also reads as level 0).
PgStatement schemaLevelSql() => const PgStatement(
  "SELECT coalesce(max(substring(version from '^[0-9]+')::int), 0) "
  'FROM schema_migrations',
  {},
);

/// Upserts this PC's `capture` heartbeat. `last_ok` keeps the old value when
/// the new one is null (a failing beat never erases the last success);
/// `last_error*` take the new value as-is, so a healthy beat CLEARS a
/// recovered error - the status page must not stay red for a fixed problem
/// (same rule as the Python parts).
PgStatement heartbeatUpsertSql({
  required String host,
  required String version,
  required DateTime startedAt,
  required Map<String, Object?> backlog,
  DateTime? lastOk,
  String? lastError,
  DateTime? lastErrorAt,
}) => PgStatement(
  'INSERT INTO service_heartbeat '
  '(part, host, version, started_at, last_seen, last_ok, last_error, '
  'last_error_at, backlog) '
  "VALUES ('capture', @host, @version, CAST(@started_at AS timestamptz), now(), "
  'CAST(@last_ok AS timestamptz), @last_error, '
  'CAST(@last_error_at AS timestamptz), CAST(@backlog AS jsonb)) '
  'ON CONFLICT (part, host) DO UPDATE SET version = EXCLUDED.version, '
  'started_at = EXCLUDED.started_at, last_seen = now(), '
  'last_ok = COALESCE(EXCLUDED.last_ok, service_heartbeat.last_ok), '
  'last_error = EXCLUDED.last_error, '
  'last_error_at = EXCLUDED.last_error_at, '
  'backlog = EXCLUDED.backlog',
  {
    'host': host,
    'version': version,
    'started_at': tsOrNull(startedAt.toIso8601String()),
    'last_ok': lastOk == null ? null : tsOrNull(lastOk.toIso8601String()),
    'last_error': lastError,
    'last_error_at': lastErrorAt == null
        ? null
        : tsOrNull(lastErrorAt.toIso8601String()),
    'backlog': jsonEncode(backlog),
  },
);
