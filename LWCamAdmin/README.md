# LWCam Admin

English | [简体中文](README.zh-CN.md)

LWCam Admin is a Flutter desktop app for Windows. It holds every SuperAdmin task
of the LWCam suite: user accounts (roles, Device IDs, password resets),
projects (create, edit, metadata templates), device reassignment, shared app
settings, and the per-PC station setup.

It is the only writer of `users`, `projects` and `app_settings` in the shared
PostgreSQL database. It is also the only editor of `lwcam_node_config.json`,
the station config that LWCAM reads. It has no capture workflow, no ADB, and no
local capture database.

The Dart package name is `lwcam_admin`. Windows is the only target.

## Where it sits in the pipeline

```
LWCAM (capture)  ->  LWIP  ->  QC Platform  ->  Upload
      ^                 all read users and projects from one PostgreSQL database
      +-- LWCam Admin writes them (and the capture PC's station config)
```

- The accounts created here sign in to LWCAM, the QC console, and the LWIP and
  Upload consoles. They never sign in to LWCam Admin.
- The database is created and upgraded by `LWCamDatabaseSetup.exe`. This app
  only connects to it. Station Setup has a Test connection button.
- Run this app first on every new capture PC.

## Screens

| Screen | Purpose |
| --- | --- |
| Login | SuperAdmin only (see "Login" below) |
| User Management | Accounts, roles, project access, password reset to the default. The temporary-password field can be set, never read. |
| Projects | Create and edit projects, location code, metadata template editor |
| Devices | Reassign a Device ID |
| App Settings | Metadata-keying switch, remote-shutter settings, default temporary password |
| Station Setup | This PC's PostgreSQL connection and login, the capture station's sync switch, the image destination folder, a folder access test |

A status bar on the home screen shows whether the database is reachable and
whether edits are waiting to be pushed.

## Folder map

| Path | Content |
| --- | --- |
| `lib/main.dart` | Start-up. Registers the store service before `runApp`, so login and Station Setup work with no database. |
| `lib/auth/` | SuperAdmin login, the compiled-in factory hash, the wrong-password lock |
| `lib/services/` | `admin_store_service.dart` (all reads and writes), `admin_pg_gateway.dart`, `admin_pg_statements.dart` (pure SQL builders), node config, DPAPI |
| `lib/controllers/` | GetX controllers for each screen and the sync status |
| `lib/pages/` | The screens above |
| `lib/theme/` | Brand theme. A copy of LWCAM's. Keep the two identical. |
| `windows/runner/resources/LWCamAdmin.iss` | Inno Setup script (own AppId) |
| `test/` | Unit tests. `test/services/fake_admin_gateway.dart` replaces the database. |

## Run, build, test

You need Flutter (stable channel) and, to build, Visual Studio 2022 with the
"Desktop development with C++" workload. Details: [docs/DEV-SETUP.md](../docs/DEV-SETUP.md).
Baselines: [docs/TESTING.md](../docs/TESTING.md).

```bash
flutter pub get
flutter run -d windows
flutter build windows --release
flutter analyze
flutter test
```

`flutter analyze` is clean.

## Login

Only the account `SuperAdmin` can sign in. The app checks the password against
these, in order:

1. `app_settings.superadmin_password_hash` in PostgreSQL (the override)
2. the local snapshot's copy of that override
3. the bcrypt hash compiled into `lib/auth/super_admin.dart` (the factory hash)

So login works offline, on a new PC, and with no database. The factory password
is not in the repository. Ask the project lead for it.

Five wrong passwords in a row lock the login for 1 minute. Each further wrong
password doubles the lock, up to 15 minutes. This is a speed bump, not a
security boundary (`lib/auth/login_lock.dart`).

## Configuration

Station Setup edits `%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json`. It holds:

- this app's PostgreSQL connection (host, port, database, user, SSL);
- the database login for LWCAM and LWCam Admin. The password is saved encrypted
  with Windows DPAPI for the current Windows user (`pgPasswordProtected`). It
  cannot be read on another account or PC. Enter it again there.
- LWCAM's capture sync switch and the image destination folder;
- `usersStorePath`, the folder of the offline snapshot `lwcam_users.json`.

`LWCAM/lwcam_node_config.example.json` shows the keys. The config file is read
and saved as a whole, so keys this app does not know are kept.

## Design rules

- Every change goes through `_mutate` in `lib/services/admin_store_service.dart`.
  It pulls first, applies and validates, then pushes online or queues offline
  with tombstones. A failed push falls back to the offline queue and loses
  nothing. Read this method before you change the file.
- All SQL is in `lib/services/admin_pg_statements.dart` as pure Dart builders
  with no `postgres` import, so tests need no connection.
- Upserts conflict on `projects(project_key)`, never on `project_id`. `project_id`
  is an editable label. Conflicting on it would create a duplicate row on every
  rename.
- The user upsert never overwrites `last_login_at`, `password` and
  `must_change_password`. LWCAM owns them. A stale snapshot must not undo a
  password a capture user just changed. Admin password resets use
  `userPasswordResetSql`.
- `projectSoftDeleteSql` rewrites `country_location_code` to `~deleted~<id>`.
  The column is unique and the `devices` table references it. The rewrite frees
  the original code, so a new project can use it again.
- `buildUsersStoreFromPgRows` reads global roles from `users.roles`, not from
  `user_projects`. Otherwise an admin with no project loses the role on the
  next pull.

## Conventions that look like mistakes but are not

- `lib/theme/` is a byte-identical copy of LWCAM's. The three Flutter apps are
  copies, not a shared library, on purpose. They ship and version on their own.
- `windows/runner/resources/LWCamAdmin.iss` has its own AppId, so the app
  installs beside LWCAM. It lists plugin DLLs by hand. Add a plugin without
  updating it and a release build fails on a clean PC.
- `print()` logging with emoji prefixes is the house style. Three lints are off
  in `analysis_options.yaml` (see LWCAM's README).

## Read next

- [AGENTS.md](AGENTS.md): architecture, the PostgreSQL gateway, and the offline
  queue model.
- [CHANGELOG.txt](CHANGELOG.txt): dated change history.
- [../LWCAM/README.md](../LWCAM/README.md): the capture app that reads what this app writes.
