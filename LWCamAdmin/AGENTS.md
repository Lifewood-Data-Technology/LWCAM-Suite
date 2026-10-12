# AGENTS.md — LWCam Admin (SuperAdmin app)

Technical guide for developers and AI coding tools working in `LWCamAdmin/`. The
workspace guide at the repository root covers build, test and installers.

## Project overview

LWCam Admin (package `lwcam_admin`, window title "LWCam Admin") is a **Flutter
Windows desktop app** for every SuperAdmin capability: user management
(accounts, roles, Device IDs, password resets), project management (CRUD,
metadata templates), device reassignment, shared app settings (metadata-keying
toggle, remote-shutter config, default temp password) and Station Setup. It is
the ONLY writer of `users`/`projects`/`app_settings` in the shared PostgreSQL
schema; LWCAM only pulls them. There is no capture workflow here: no ADB, no
sqflite, no gallery/box UI.

Windows is the only target: `window_manager` for the window, `postgres` (a
pure-Dart driver) for the database, no native DLLs beyond what window_manager
and screen_retriever need. The installer script
`windows/runner/resources/LWCamAdmin.iss` has its own AppId, distinct from
LWCAM's, and bundles no `adb.exe` or `scrcpy`.

## Commands

```bash
flutter pub get                          # install dependencies
flutter run -d windows                   # run the app
flutter build windows --release          # release build
flutter analyze                          # static analysis
flutter test                             # all tests (counts: docs/TESTING.md)
```

Lints: `avoid_print`, `deprecated_member_use` and
`no_leading_underscores_for_local_identifiers` are ignored in
`analysis_options.yaml`, same as LWCAM. `print` logging with emoji prefixes is
the established style.

## Architecture

State management, routing and DI use **GetX**, matching LWCAM. Routes: `/`
(LoginPage, SuperAdmin only), `/home` (HomePage: 5 tiles - User Management,
Projects, Devices, App Settings, Station Setup - plus a persistent status bar).

- `lib/main.dart` bootstraps window_manager and `AdminBootstrap.apply` (registers
  `AdminStoreService` against whatever `NodeConfig` is on disk) BEFORE `runApp`,
  so the login page's factory-hash fallback and Station Setup both work with zero
  PostgreSQL connectivity on a brand-new PC. The `apply` call is deliberately not
  awaited: its fresh-start path registers the service synchronously, and the
  initial reconcile behind it can spend about 5 s on a connect timeout. It also
  registers `SyncStatusController` (the 30 s reconcile timer; it looks the store
  service up per tick, so it survives Station Setup re-registering it).

- `lib/auth/super_admin.dart` holds the built-in recovery account: only its bcrypt
  hash is compiled in, so the login works even when PostgreSQL is unreachable and
  the local snapshot is missing. This is the ONE account the app accepts; the
  accounts in User Management only ever log into LWCAM.
  `lib/auth/admin_auth_controller.dart` verifies, in order: PostgreSQL's
  `app_settings.superadmin_password_hash` override (after a best-effort bounded
  `trySync()`, so a hash changed from another PC applies promptly) → the local
  snapshot's copy of that override → the factory hash. `lib/auth/login_lock.dart`
  is a wrong-password speed bump (5 free attempts, then a doubling lock up to 15
  minutes, state in `lwcam_admin_login_lock.json`). It is NOT a security boundary;
  its class comment says what it covers.

- `lib/services/admin_store_service.dart` (`AdminStoreService`) is the one place
  this app reads and writes users, projects and app settings. It is
  PostgreSQL-first with a local-JSON offline fallback (`lwcam_users.json`, same
  file and default directory LWCAM's sync pull uses, `%USERPROFILE%\LWCAM_DBs`,
  overridable through `NodeConfig.usersStorePath`). Every mutation goes through
  `_mutate`: reconcile first (`trySync()`: pull before transform, so an online
  edit never lands on a stale local copy), apply the transform (all validation
  throws happen here, before anything is written: `_validateProjectName`,
  `_validateDeviceIdUnique`, `_validateLocationCode`, mirroring PostgreSQL's
  UNIQUE constraints), then push+pull (online) or queue offline (`dirty=true` plus
  a tombstone in `deletedUsernames`/`deletedProjectKeys` for a delete; a `.lock`
  create-exclusive file guards against a second admin editing concurrently). A
  push failure mid-mutation degrades to the offline branch rather than losing the
  edit. `trySync()` is also called by `init()` and by `SyncStatusController`.
  `NodeConfig.pgConnectionEnabled` (Station Setup's "PostgreSQL connection"
  toggle, default true) is read at construction (`AdminBootstrap` rebuilds the
  service on every save). When false, `trySync()` skips `gateway.probe()` and goes
  straight to the offline branch. `HomePage`'s status bar checks it before
  `online.value`, so a disabled station reads as informational.

- `lib/services/admin_pg_gateway.dart` (`AdminGateway`/`AdminPgGateway`) is the
  seam between `AdminStoreService` and PostgreSQL (`test/services/fake_admin_gateway.dart`
  is the test double). `probe()` distinguishes `unreachable` from `schemaOutdated`
  (a `ServerException` on a schema column/table probe means the database has not
  been upgraded; treated as offline, never as a write target). `pushSnapshot`
  runs one transaction: seed roles → **tombstone soft-deletes FIRST** (an offline
  delete-then-recreate of one username must not push the new account and then
  soft-delete it) → project upserts (skipping code-less projects) → user upserts
  → targeted password resets (`pendingPasswordResets`) → a second created_by-fill
  pass → user_projects insert+prune → app_settings upserts. `_exec` wraps
  `List<String>` parameters as `text[]`. `pullStore` runs the 4 SELECTs and hands
  the rows to the pure `buildUsersStoreFromPgRows` in `admin_pg_statements.dart`.

- `lib/services/admin_pg_statements.dart` has pure Dart SQL builders (no `postgres`
  import; unit-testable without a connection). This app owns `users`,
  `projects`, `user_projects`, `roles` and `app_settings`; it never touches
  `capture_boxes`/`capture_folders`/`capture_images` (LWCAM's `pg_statements.dart`
  owns those). Every upsert conflicts on the natural key: `users(user_id)`,
  **`projects(project_key)`, NOT `project_id`** (a human-editable label that must
  survive renames without minting a duplicate row). Each `DO UPDATE` is guarded
  with `IS DISTINCT FROM`, so an unchanged reconcile writes nothing.
  LWCAM-owned columns are left OUT of the user upsert's `DO UPDATE`:
  `last_login_at` and `password`/`must_change_password`, so a whole-store push
  with a stale snapshot never regresses a password a capture user just changed.
  Admin-intended password writes (reset, or createUser reviving a deleted
  username) use the targeted `userPasswordResetSql`, driven by the store's
  `pendingPasswordResets` queue (cleared by the pull after a successful push).
  `projects.has_data` is monotonic in the upsert (`OR`, never back to false).
  `projectSoftDeleteSql` rewrites `country_location_code` to `~deleted~id`, since
  that column is a full unique FK target (devices reference it) and the real code
  must be freed; `project_id`, `project_name` and `users.device_id` are partial
  unique indexes (live rows only). `buildUsersStoreFromPgRows` reads global roles
  from `users.roles` (comma-joined), NOT re-derived from `user_projects`.

- `lib/models/`: `app_user.dart` (`AppUser`/`UsersStore`/`SharedAppSettings`; no
  password-view field; `UsersStore` carries `dirty`/`deletedUsernames`/
  `deletedProjectKeys` for the offline queue, which LWCAM's parser round-trips as
  unknown keys), `project.dart`, `metadata_template.dart`, `node_config.dart`
  (mirrors LWCAM's shape, including the `usersStorePath` both apps read).

- `lib/services/device_registry.dart` is adapted from LWCAM's copy minus
  `registerOrCheck` (a capture-time gate; this app only reassigns, in the Devices
  page). It gates on `pgConnectionEnabled` + host, NOT `syncEnabled` (LWCAM's
  capture-outbox flag), or Devices would be dead on an admin-only PC.

- `lib/services/admin_bootstrap.dart` and `lib/controllers/station_setup_controller.dart`:
  `AdminBootstrap.apply` (re)builds and registers `AdminStoreService` from a
  `NodeConfig`, so Station Setup can apply a changed PG connection without a
  restart. Station Setup is the ONLY editor of the capture PC's station config:
  besides this app's own PG connection, its "LWCAM capture station" section owns
  LWCAM's capture-outbox `syncEnabled` toggle and the image destination root
  (`NodeConfig.destinationPath`). It does not configure, start or stop LWIP, and
  has no LWIP folder fields (LWCAM's rework finds a folder's originals under the
  image destination); `processingEnabled`/`processingWorkers`/
  `processingCropPadding`/`processingCloudReport`/`processingInputRoot`/
  `processingOutputRoot` stay in `NodeConfig` round-trip only so an older
  `lwcam_node_config.json` still loads. Save does not provision the database
  (`LWCamDatabaseSetup` does, on the database PC): it tests the PostgreSQL
  connection and reports "Database not reachable" if a complete connection does
  not answer. Both apps read the identical `lwcam_node_config.json` (default
  `%USERPROFILE%\LWCAM_DBs`). That is the fresh-PC bootstrap: run a portable
  LWCam Admin build once on a new capture PC, fill in Station Setup, and LWCAM
  picks up the same file at its next launch.

- `lib/services/admin_login.dart` reads the database logins saved in the node
  config. The password is saved DPAPI-encrypted (`pgPasswordProtected`, base64
  DPAPI, CurrentUser scope, entropy ASCII `LWCam`; `adminPgPasswordProtected` for
  this app's own login) and clears the plain `pgPassword`. `lib/services/dpapi.dart`
  has the same logic as LWCAM's copy: keep the two identical (LWCAM reads the
  blobs this app writes). When a blob cannot be decrypted (saved by another
  Windows user or PC), the home page and Station Setup show
  `adminLoginUnreadableMessage`. Station Setup reloads `lwcam_node_config.json`
  from disk right before every read-modify-save, round-trips every unknown key,
  and writes a temp file then replaces it (never delete-then-rename), so it cannot
  write back a stale copy of a file LWCAM also touches. The capture PC uses the
  shared database login (see `installer/README.md`).

- `lib/controllers/sync_status_controller.dart` is a 30 s probe timer producing
  the online/dirty/lastPush/lastPull state the status bar shows; it reconciles
  (`trySync()`) whenever `dirty && reachable`, so a queued offline edit pushes as
  soon as connectivity returns.

- `lib/pages/`: `login_page.dart`, `home_page.dart`, `user_management_page.dart`
  (the temp-password tile is SET-only, never displays an existing password),
  `projects_page.dart` (CRUD + location code + template button),
  `template_editor_page.dart`, `devices_page.dart`, `app_settings_page.dart`,
  `station_setup_page.dart` (NodeConfig editor for this machine + Test Connection).

## Notes

- `CHANGELOG.txt` records what changed and why (see `CONTRIBUTING.md`).
- `lib/theme/` (`app_colors.dart`, `app_theme.dart`, `theme_controller.dart`) is a
  copy of LWCAM's, the shared Lifewood brand theme. Keep the two in step by hand.
