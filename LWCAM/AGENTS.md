# AGENTS.md — LWCAM (capture app)

Technical guide for developers and AI coding tools working in `LWCAM/`. The
workspace guide at the repository root covers build, test and installers.

## Project overview

LWCAM (package `lwcam`, window title "LWCAM (Lifewood Capture)") is a **Flutter
Windows desktop app** for a document-digitization workflow. It pulls photos from
an Android phone's DCIM folder over ADB, stages them in a local temp directory,
then copies them to a local or NAS destination with reliability safeguards
(timeouts, stall detection, file locking, audit logs). It has two capture
workflows behind a per-account metadata-keying toggle: Normal Mode (keying off,
`/gallery`) and Box Mode (keying on, Box → Folders workflow with a live phone
mirror, `/boxes`). LWCAM acts on two roles, `admin` and `capture`; it has no QC
screens. The `qc` role stays in the enum only so it round-trips: removing it would lose data, because
`lwcam_users.json` is shared with LWCam Admin and LWCAM rewrites it, while
`UserRole.fromJson` ignores a role it does not know (`user_role_qc_test.dart`
guards that round-trip). A reviewer-only account is refused at login.

SuperAdmin does not exist here; it lives in the sibling `LWCamAdmin` app. QC is
the web console in `LWCam_QC_Platform`. LWIP is its own service in `LWIP/`.

Windows is the only target: the code shells out to PowerShell, reads
`USERPROFILE`, uses `sqflite_common_ffi` and `window_manager`, and expects
`adb.exe`. Only `windows/` exists. The phone is driven externally through
`adb.exe` and (Box Mode's live mirror) a bundled `scrcpy`. The installer script
`windows/runner/resources/LWCAM.iss` hand-lists the plugin DLLs and the
`scrcpy-win64` folder: keep it in sync when you add or remove a plugin that has
a Windows implementation.

## Commands

```bash
flutter pub get                          # install dependencies
flutter run -d windows                   # run the app
flutter build windows --release          # release build
flutter analyze                          # static analysis
flutter test                             # all tests (counts: docs/TESTING.md)
flutter test test/services/transfer_destination_service_test.dart   # one file
flutter test --plain-name "builds same-month work week and day folders"  # one test
```

Runtime: `adb.exe` must be next to the built exe, in the project root, at
`C:\Android\platform-tools\adb.exe`, or on PATH (order in
`gallery_page.dart:_resolveAdbPath`). Box Mode also needs `scrcpy` (see the
root `AGENTS.md`, "a dev build has no bundled runtimes").

Lints: `avoid_print`, `deprecated_member_use` and
`no_leading_underscores_for_local_identifiers` are ignored in
`analysis_options.yaml`. `print` logging with emoji prefixes is the established
style.

## Architecture

State management, routing and DI all use **GetX**. Routes: `/` (LoginPage),
`/home` (HomePage), `/gallery` (GalleryPage, Normal Mode), `/boxes`
(CaptureBoxListPage, Box Mode).

**Navigation is role-driven and two-step: pick a project, then the job.**
`home_page.dart` offers at most two cards: `Projects` always, `Unresolved Images`
when `isAdmin`; an account with one card skips the landing. There is no Capture
card: capture is entered through a project, so the device gate and the active
project assignment live in one place. `projects_page.dart` lists every project
granted in ANY role (`AppUser.allProjectKeys`). `project_area_page.dart` builds
cards from `AppUser.rolesForProjectKey` (`Dashboard` / `Capture`; QC review happens in the QC console, so it adds no card),
each present only where that role is granted ON that project, and BOTH layers
must agree (the global role in `users.roles` AND a `user_projects` row). One
applicable card means no list. Capture is not a page push: its card calls
`enterCaptureWithProject` (device-registry gate, then `/boxes` or `/gallery`).
Login routing follows the same rule: a capture-only account with exactly one project skips
the chooser; with ZERO projects it is blocked by the "No Project Assigned"
modal; everything else lands on Home.

Data flow: **GalleryPage or CaptureBoxListPage/BoxTransferFlow (ADB pull → temp
staging) → TransferController (copy to destination) → UploadStatsDB (local
per-device DB) → optional PostgreSQL sync (SyncService)**.
(`TransferController` copies to the local/NAS destination. It does not upload to S3.)

- `lib/main.dart` bootstraps sqflite FFI, window_manager and global error
  handling. An uncaught error writes `lwcam_log_<timestamp>.txt` to the user's
  Downloads folder and shows a PowerShell MessageBox. Closing the window shows a
  confirm dialog and runs temp-file cleanup.

- `lib/pages/gallery_page.dart` (~6300 lines) is the center of gravity and the
  highest-risk file. It resolves and drives `adb.exe` through `Process.run`: scans
  `/storage/emulated/0/DCIM/...` with `adb shell ls`, pulls files, detects the
  device model, launches the device camera, deletes files from the device. It
  keeps temp dirs (`_tempDir` gallery cache, `_transferTempDir` staging) that are
  deleted on dispose/app close. It handles the "replacement image" workflow:
  recapturing launches the camera in Pro mode (with foreground verification,
  since `am start` lies about success) and swaps the new capture over the
  original's filename on the device; every replacement is recorded in the DB
  (superseded records are marked, never deleted). It also hosts the rework
  recapture UI. A live-sync timer polls the device for new photos. Do not touch it
  for work that does not need it. Treat the ADB/transfer half as untouchable.

- Box Mode: `capture_box_list_page.dart`, `box_transfer_flow.dart`,
  `folder_metadata_form_page.dart`, `box_session_controller.dart`,
  `gallery_controller.dart`, `capture_box_models.dart`, `batch_metadata.dart`.
  Capture boxes hold keyed folders (cover tag, image tags, title, volume, dates,
  archival ref no, record type); each folder gets its own destination
  subdirectory at transfer time. Transfers run in a background per-box queue
  (`transfer_queue_service.dart`). Each box tile shows live progress and a
  PERSISTED outcome (`capture_boxes.last_transfer_state`/`last_transfer_error`,
  local-only, excluded from PG sync) that survives restart. Interrupted, partial
  or failed boxes show a per-tile Retry that re-runs `runBoxTransferFlow`
  (already-copied images skip via the DB; staging reuses the durable `box_images`
  store or re-pulls from the phone).

- **Capture integrity** (`orphan_image_store.dart`, `box_integrity.dart`). The
  per-image `capture_images` assignment is the ONLY record of box membership, so
  a lost capture-time write must never go unnoticed. `assignNewImage` retries the
  write, and on hard failure stashes the pulled bytes to a **filesystem** ledger
  (`<AppSupport>/orphan_images/<deviceId>/` + `.intent.json`; deliberately not a
  DB table, since the DB is what just failed). `healOrphanImages` re-files
  intent-known orphans at box-list load, box open and pre-transfer.
  `verifyBoxComplete` gates every `markCaptureBoxTransferred`: a mismatch leaves
  the box `partial`, never transferred. Unhealable orphans go to the admin-only
  "Unresolved Images" screen (`orphan_resolution_page.dart`). `stageBoxFiles`
  falls back to the durable `box_images` copy when the phone no longer has an
  assigned file (the one exception to "the phone is the source of truth").
  `scrcpy_service.dart` embeds the phone mirror as a native Win32 child
  ("clip-host" crop: a small black host window clips scrcpy's window via
  `SetParent`/`SetWindowPos`, because scrcpy's own `--crop` combined with window
  embedding crash-loops). `shutter_hotkey_service.dart` arms a global hotkey
  (`hotkey_manager`) that taps the phone's shutter through the mirror.

- `lib/controllers/transfer_controller.dart` (~1900 lines) is the batch transfer
  engine for both modes. `uploadAll()` takes an optional `BoxTransferContext`;
  `if (box != null)` branches are the only differences (images land in one
  destination subfolder per keyed folder, CSV/DB rows carry the folder's
  metadata). It copies queued files with up to 12 concurrent tasks in 4 MB chunks
  with per-file progress. Reliability layers: 10-minute copy timeout, 30-second
  stall detection (checked every 5 s), destination-availability polling with a
  reconnect dialog. Crash recovery is DB-based: a file's `upload_records` row is
  written only AFTER a verified copy, batches skip already-recorded base names,
  and the static `generateUniqueTargetFile` overwrites a destination file that
  exists with no DB record (an orphan from an interrupted run) instead of
  suffix-skipping it. There is deliberately NO resume-by-index checkpoint: names
  are allocated fresh from disk state each run, so a saved index can never match
  after a restart. Each batch writes into the destination a CSV of upload records
  plus transfer/summary/error/interruption logs under `logs/`, prefixed with the
  operator's device ID; artifact writes are serialized by
  `_runSerializedArtifactWrite`. Timeout constants are at the top of the file:
  `_copyOperationTimeout` (10 min), `_stallTimeout` (30 s),
  `_stallCheckIntervalMs` (5000). The custom exceptions
  (`TransferTimeoutException`, `TransferStallException`,
  `UploadInterruptionException`) are defined there too.

- `lib/services/transfer_destination_service.dart` defines the destination
  layout: `<root>/<work-week folder, e.g. "June 15-19">/<YYYYMMDD>/`. Weeks run
  Monday to Friday; weekend dates fall into the preceding work week.

- `lib/db/upload_stats_db.dart` (~3200 lines) is a singleton over sqflite FFI, the
  **only** local database: a per-device DB `lwcam_stats_<deviceId>.db`
  (`upload_records`, `daily_summary`, `replacement_records`,
  `capture_boxes`/`capture_folders`/`capture_images`, `sync_outbox`,
  `processing_ledger`) under `%USERPROFILE%\LWCAM_DBs`, plus one monthly-rotation
  file per device per month for the two high-volume local-only tables
  (`upload_records`/`daily_summary`; no outbox there). The capture tables MIRROR
  the cloud schema (`LWCam_QC_Platform/database/LWCam_database_unified_*.sql` plus
  its migrations are the authority): same column names, full-CAPS statuses
  (`'OPEN'`/`'TRANSFERRED'`), plus local-only columns (`renamed_from`,
  `last_transfer_state`, `template_json`, `project_key`, …) that never sync.
  `capture_folders` also mirrors the six image-processing columns
  (`is_deskewed`, `is_cropped`, `is_created_thumbnail`, `folder_path`,
  `thumbnail_path`, `qc_status`); LWIP writes them to PostgreSQL itself. The
  QC-owned columns (`group_id`, `client_qc_status`, `client_rework`) stay absent.
  `processing_ledger` is dead weight (nothing writes it), kept so an existing DB's
  schema version still matches. The stable schema is at **version 2**
  (`_stableSchemaVersion`) with a real `onUpgrade` → `_migrateStableSchemaV2`;
  the monthly DB is still `version: 1`, do not conflate them. Index creation is
  best-effort per statement: a DB that will not open is reported as corrupt and
  offered a destructive rebuild, so an older file missing a column an index names
  skips that index instead of failing the open. It implements "transfer
  protection": WAL checkpointing plus an OS-level file lock
  (`RandomAccessFile.lock` on `lwcam_transfer_in_progress.lock`) during a batch.

- **Sync pipeline.** Configured only from LWCam Admin's Station Setup (LWCAM has
  no Settings UI). The outbox hooks in `upload_stats_db.dart` always record;
  `NodeConfig.syncEnabled` (default ON) only gates the DRAIN. Each stable DB runs
  a one-time catch-up before its first drain (`queueCaptureRowsMissingFromCloud`,
  done-marker in `sync_meta`) that queues only the boxes/folders/images
  PostgreSQL does not hold (`PgSyncSink.fetchCaptureKeys`; soft-deleted cloud
  rows count as present). It is never a blanket resend, which would overwrite
  QC's metadata edits with the PC's older copy and revive QC-deleted folders. A
  delete made while sync was off on a row PG already had is the one thing the
  catch-up cannot recover.
  `sync_service.dart` drains the outbox every 30 s through `pg_sync_sink.dart`,
  and PULLS a fresh users/projects/app_settings snapshot at the START of every
  tick: PostgreSQL is the source of truth for those tables, and LWCAM writes them
  only through a 3-call whitelist (`updateOwnPasswordSql`/`recordLoginSql`/
  `markProjectHasDataSql` in `pg_statements.dart`). The pull's 4 SELECTs feed the
  pure `buildUsersStoreFromPgRows` (roles from `users.roles`, NOT re-derived from
  `user_projects`, or a zero-project admin loses the role), which rebuilds a
  `UsersStore` that overwrites `lwcam_users.json` wholesale
  (`UsersStoreService.applySnapshot`, wired by `sync_bootstrap.dart`). A
  `SyncConnectException` on the pull skips the rest of the tick (state=offline);
  any other pull failure keeps the local snapshot and continues into the drain
  (state=error).
  Outbox payloads carry NATURAL keys and the sink resolves the cloud's BIGINT ids
  per batch: **projects resolve by `project_key`** (the stable identity), never
  `project_id` (a label LWCam Admin can rename); users.user_id = username,
  devices.device_id = SAX##, boxes (project_id, box_name), folders (box,
  folder_seq), images (folder, image_name). There are per-batch caches, a
  box-RENAME fixup driven by the local-only `renamed_from` column (set only if
  null; a second rename across 2+ ticks can orphan a cloud row, accepted), and a
  devices-row self-heal. All SQL is in `pg_statements.dart` (pure Dart,
  unit-testable without a connection; `pg_client.dart` opens connections). Every
  tick ENDS by pulling the active project's cloud box names (by `project_key`)
  into `cloud_box_names.dart` (used by `boxNameExists`, the cross-PC uniqueness
  check; an empty cache means local-only behaviour). `kSyncEntityOrder`
  (`sync_models.dart`) holds six entities: the three capture ones plus
  `capture_folder_processing`, `capture_folder_rework` and `rework_logs`.
  LWCAM never writes `group_id`/`client_qc_status`/`client_rework`, and never
  writes a pipeline column through `folderUpsertSql`. Exactly two statements
  write a pipeline column: `folderProcessingUpdateSql` (entity
  `capture_folder_processing`; sets the processing flags and paths and moves
  `qc_status` to 'PENDING' only from NULL/''/'PENDING'/'REWORK', since a report
  can land days late, after QC has PASSed and exported; a PASS is re-queued only
  by QC's own send-back) and `folderQcStatusPendingSql` (via
  `capture_folder_rework`; a metadata-only correction changes no file, so LWIP
  would never reprocess it and nothing else would move it off 'REWORK'). LWCAM no
  longer enqueues `capture_folder_processing` itself; the case remains only to
  drain rows queued earlier. LWCAM never creates cloud schema.

- **Held records and schema gate.** The database can be another PC or site, and
  can be off: capture never waits on it. Records queue in the per-device SQLite DB
  and sync with back-off. A record refused `kSyncAttemptCap` (20) times is HELD
  (kept, skipped) until the operator presses "Try again"
  (`SyncService.retryHeld`). Held and old unsent records make this PC's row red on
  the QC System status page; an off PC is grey. `kRequiredSchema` is 7
  (`sync_sink.dart`): an older database gives "The database is older than this
  program ... Run LWCamDatabaseSetup".

- **LWIP interface.** LWIP runs standalone and reports to PostgreSQL itself; LWCAM
  neither starts nor reads it. Two things stay here because LWCAM is the one PC
  that knows them. `processing_marker_service.dart`'s `writeBoxProcessingMarkers`
  (called from `BoxSessionController.markTransferred`) drops
  `lwcam_capture_marker.json`, the folder's natural-key identity, into each
  destination folder; it carries `"image_count"` (images copied in), and LWIP
  waits until the folder holds that many. And `rework_service.dart` finds the
  input file a QC recapture must overwrite under `NodeConfig.destinationPath`,
  from the `<date>\<folder>` tail of LWIP's `folder_path`.
  `NodeConfig.processingEnabled`/`processingWorkers`/`processingCropPadding`/
  `processingCloudReport`/`processingInputRoot`/`processingOutputRoot` are
  round-trip only: kept so an old `lwcam_node_config.json` still saves.

- **Rework loop (QC send-back → recapture → reprocess)**, hosted inside the capture
  page. QC appends an OPEN `rework_logs` row per rejected image.
  `rework_service.dart` reads the worklist (`selectOpenReworkSql`, short-lived PG
  connections) and `open_rework_cache.dart` caches it, so box tiles show a "Needs
  Rework" badge and sort to the top (`CaptureBoxEntry.reworkCount`; refreshed off
  the render path, since an unreachable PG must never stall the box list). The
  recapture UI is in `gallery_page.dart`. Two outbox entities carry the results:
  `rework_logs` (an append-only CLOSED row once the recaptured image transfers, so
  the closure survives an offline recapture) and `capture_folder_rework` (a
  metadata-only correction, via `folderMetadataPatchSql` + `folderQcStatusPendingSql`).
  `pendingReworkClosureKeys` filters just-submitted closures out of the badge
  count. Archive dates (`start_date`/`end_date`) are TEXT in PG holding the value
  VERBATIM as keyed (`"1914"`, `"1914-06"`, `"1877-Mar-05"`): nothing parses,
  casts or reshapes them; bind and display them as strings (`textOrNull` in
  `pg_statements.dart` trims and nulls a blank).

- **Local DB corruption recovery** (`UploadStatsDB.inspectDeviceDatabase` /
  `rebuildFromCaptureSnapshot`, offered from `capture_box_list_page.dart` on
  entering Box Mode). `inspectDeviceDatabase` returns `missing`/`healthy`/
  `corrupt`/`unavailable`. Only genuine SQLite corruption signals
  (`isSqliteCorruptionError`) count as `corrupt`: inspecting OPENS the DB, which
  runs schema DDL and takes a write lock, so a concurrent transfer or an AV scan
  is `unavailable` ("try later"), never grounds to rebuild.
  `rebuildFromCaptureSnapshot` builds a replacement beside the live file from a PG
  snapshot, validates it (row counts, joins, `integrity_check`), carries over the
  local-only tables the cloud cannot restore (`sync_outbox` above all, the
  un-pushed delta; plus `replacement_records` and the legacy tables), then
  promotes it by rename, keeping the original as `<path>.corrupt-<micros>`.
  `_recoveringDeviceIds` makes `_cachedOpen` refuse to reopen the device
  mid-rename (otherwise SQLite creates an empty DB at the freed path), and the
  caller pauses `SyncService`, whose 30 s tick reopens every device DB.

- **Device registry + lock** (`device_registry.dart`). The cloud `devices` table
  binds each capture device (SAX##) to one project through
  `country_location_code` (an FK to projects, so the lock is structural).
  `AuthController.enterCaptureWithProject` registers or refreshes the device row
  and BLOCKS entry into a project the device is not bound to. It and `goToCapture`
  are both async and return `false` when blocked: always await them (unawaited,
  login reports success and writes the session before the block resolves,
  stranding a capture-only operator on the login page). Only SuperAdmin can move a
  device, in LWCam Admin's Devices screen. Sync off, PG unreachable or a
  code-less project means the gate silently allows. Projects carry a required
  unique free-text `countryLocationCode` (up to 32 chars, keyed in LWCam Admin).

- `lib/auth/auth_controller.dart`: login is **always username + password**.
  Password login gates on `canNormalMode`/`isAdmin`, routes to `/boxes` when
  metadata keying is on for the account else `/gallery`, and auto-routes
  single-role accounts. An account with neither role sees a generic "no access to
  LWCAM" refusal and its half-authenticated state is cleared. A forced
  first-login or reset password change (`AuthStatus.mustChangePassword`) tries
  PostgreSQL first through `UserDirectoryService` but never blocks offline: an
  unreachable PG queues the new hash locally, applies it to the local snapshot so
  login works this session, and retries on every sync tick and every later login
  attempt. The device ID becomes the operator ID stamped on all records, logs and
  DB rows.

- `lib/models/app_user.dart`: `projectKeysFor(role)` is the per-role grant (never
  flatten it: `user_projects` is role-specific, so a flat lookup hands a capture
  operator the admin/QC set); `rolesForProjectKey` and `allProjectKeys` build on
  it. `AppUser` has no password-view field: an admin can only reset a password to
  the shared default. `SharedAppSettings.superAdminPasswordHash` still round-trips
  through JSON (LWCam Admin sets it; LWCAM has no reader).

- `lib/pages/settings_page.dart`: there is NO Settings page in LWCAM. The file
  name stays because half a dozen imports use it; it holds only the slim
  `SettingsController`: `destinationPath` (from `NodeConfig.destinationPath` at
  startup, refreshed on every login; uploads refuse to start while empty) and
  `includeUploaded` (session-only gallery filter). LWCAM never writes
  `lwcam_node_config.json`; Station Setup owns it, and LWCAM picks changes up at
  launch and login (`SyncBootstrap`/`reloadDestination`). The theme toggle lives
  in `lib/widgets/session_app_bar_actions.dart` beside Logout.

- `lib/services/file_lock_service.dart` creates `.lock` sidecars for
  Excel/CSV/DB/JSON sources during transfer; locks are released in `finally`.

- `lib/services/users_store_service.dart` reads the local READ-ONLY snapshot
  `lwcam_users.json` (written wholesale by the sync pull, or seeded by Station
  Setup on a fresh PC). PostgreSQL is the source of truth; LWCAM writes back
  through 3 PG-direct calls (`changeOwnPassword`/`recordLogin`/
  `markProjectHasData`, via `user_directory_service.dart`), never the local file.
  `UsersStoreSource` is `{snapshot, none}`; `none` means a fresh PC before its
  first pull ("run LWCam Admin station setup"). The one exception:
  `changeOwnPassword` queues a still-undelivered hash in
  `lwcam_pending_password_changes.json` (username → bcrypt hash) on ANY PG failure
  (retry is idempotent) and applies it locally at once; every pull re-splices any
  pending hash onto the freshly pulled store, so a stale pull never reverts an
  offline password change before it reaches PostgreSQL.
  `flushPendingPasswordChanges()` is the same retry, also called at the start of
  each login. All pending-file and snapshot read-modify-writes run behind an
  internal mutex (`_serialized`). Two shared-file rules with LWCam Admin (same
  `lwcam_users.json` on a standard station): a pull NEVER overwrites a file the
  Admin app marked `dirty`, and `UsersStore` round-trips the Admin-only JSON keys
  (`dirty`, `deletedUsernames`, `deletedProjectKeys`, `pendingPasswordResets`,
  and future ones) through `adminExtras`, so LWCAM's writes never strip them.
  Pass the CANONICAL username (the store record's, not the typed one) to
  `changeOwnPassword`/`recordLogin`: PG matches `user_id` exactly while local
  lookup is case-insensitive.

- `lib/services/path_utils.dart`: Windows path sanitization and the FNV-1a-based
  box key helper.

- `lib/services/dpapi.dart` reads the capture DB password from
  `pgPasswordProtected` in `lwcam_node_config.json` (base64 DPAPI, CurrentUser
  scope, entropy ASCII `LWCam`), else the old plain `pgPassword`. It is a copy of
  LWCamAdmin's: keep the two identical. The config file is reloaded from disk
  before every read-modify-save, unknown keys round-trip, and saving is
  write-temp-then-replace. Upgrade order for a capture PC: install the new
  LWCamSetup first, then enter the login in Station Setup.

## Notes

- `CHANGELOG.txt` records what changed and why. Add an entry for every
  user-visible or behavioral change (see `CONTRIBUTING.md`).
- `assets/logo.png` is a bundled asset declared in `pubspec.yaml`.
- Kept identical to the sibling apps on purpose, with no reason to rename: on-device
  paths (`/sdcard/life_transfer_camera_ui.xml`, `.lifetrans_bak` suffix),
  temp-dir prefixes (`dcim_cache_gallery_`, `box_transfer_stage`) and
  SharedPreferences key names.
