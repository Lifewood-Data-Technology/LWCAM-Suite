# LWCAM (Lifewood Capture)

English | [简体中文](README.zh-CN.md)

LWCAM is a Flutter desktop app for Windows. It pulls photos from an Android
phone over ADB, stages them on the PC, and copies them to a local or network
folder. It records each capture in a local SQLite database and syncs it to the
shared PostgreSQL database.

The Dart package name is `lwcam`. Windows is the only target.

## Where it sits in the pipeline

```
LWCAM (capture)  ->  LWIP (deskew/crop)  ->  QC Platform (review, export)  ->  Upload (S3)
   ^ this app            LWCam Admin manages users, projects and stations
```

- LWCAM copies each finished folder to LWIP's input folder.
- LWCAM then writes a marker file (`lwcam_capture_marker.json`) into the folder.
  LWIP waits for this marker before it processes the folder.
- The QC Platform sends rejected pages back as `rework_logs` rows. LWCAM shows
  them as a "Needs Rework" badge on the box list.
- Terms are in [docs/GLOSSARY.md](../docs/GLOSSARY.md). The whole design is in
  [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## The two capture workflows

A per-account metadata-keying switch (set in LWCam Admin) chooses the workflow.

| Mode | Route | Behaviour |
| --- | --- | --- |
| Normal Mode (keying off) | `/gallery` | Pull from the phone. Transfer to the dated destination folder. |
| Box Mode (keying on) | `/boxes` | A capture box holds keyed folders (tags, title, volume, dates, reference number, record type). Each folder gets its own destination subfolder. Transfers run in a background queue per box. Each box tile shows live progress and a saved result that survives a restart, with a Retry button. |

A transfer writes this layout:

```
<destination root>\<work week, e.g. "June 15-19">\<YYYYMMDD>\<folder>\
```

Work weeks run Monday to Friday. A weekend date falls into the work week before it.

## Folder map

| Path | Content |
| --- | --- |
| `lib/main.dart` | Start-up, error handling, routes (`/`, `/home`, `/boxes`, `/gallery`) |
| `lib/pages/` | Screens. `gallery_page.dart` (about 6300 lines) holds the ADB code and the rework loop. |
| `lib/controllers/` | GetX controllers. `upload_controller.dart` copies files to the destination. |
| `lib/services/` | ADB, transfer queue, sync to PostgreSQL, file locks, node config, scrcpy, rework |
| `lib/db/` | Local SQLite database of captures and transfers (`upload_stats_db.dart`) |
| `lib/auth/`, `lib/models/` | Login and data classes |
| `lwcam_node_config.example.json` | Example station config |
| `windows/runner/resources/LWCAM.iss` | Inno Setup script for this app |
| `test/` | Unit tests |

## Run, build, test

You need Flutter (stable channel). To build you also need Visual Studio 2022
with the "Desktop development with C++" workload. Full setup is in
[docs/DEV-SETUP.md](../docs/DEV-SETUP.md). Test baselines are in
[docs/TESTING.md](../docs/TESTING.md).

```bash
flutter pub get
flutter run -d windows
flutter build windows --release
flutter analyze
flutter test
flutter test test/services/transfer_destination_service_test.dart   # one file
```

`flutter analyze` reports a few info-level lints and no errors.

At run time the app needs:

- `adb.exe`. The app looks next to its own `.exe`, then in
  `%ProgramFiles%\LWCam\LWCAM\adb.exe`. It does not search `PATH` or the working
  folder (`AdbDeviceService.resolveAdbPath`). The installer ships `adb.exe`.
  When you run from source, copy `adb.exe` next to the built `.exe`.
- `scrcpy` in a `scrcpy\` folder next to the `.exe`. Only Box Mode's live phone
  mirror needs it.

## Configuration

LWCAM has no Settings page. A station config file holds the settings:

```
%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json
```

LWCam Admin writes this file (Station Setup screen). LWCAM only reads it.
`lwcam_node_config.example.json` shows the keys:

| Key | Meaning |
| --- | --- |
| `pgConnectionEnabled`, `pgHost`, `pgPort`, `pgDatabase`, `pgUser`, `pgPassword`, `pgUseSsl` | PostgreSQL connection. Station Setup saves the password encrypted (`pgPasswordProtected`, Windows DPAPI). |
| `syncEnabled`, `syncIntervalSeconds` | Send captures to PostgreSQL. LWCAM always records captures locally. This switch only controls sending. |
| `destinationPath` | Image destination root (usually LWIP's input folder). |

Run LWCam Admin first on a new capture PC. If LWCAM reports an empty
destination, fix it in Station Setup. It is not a bug in LWCAM.

LWCAM writes only a few things to the shared database: capture records, the
user's own password change, the login time, and the project `has_data` flag.
LWCam Admin is the only writer of users, projects and app settings.

## Reliability rules

Read these before you change the transfer path.

- **Timeouts.** A file copy has a 10-minute limit. A copy that makes no progress
  for 30 seconds is a stall. The constants are at the top of
  `lib/controllers/upload_controller.dart`.
- **Crash recovery uses the database, not a checkpoint.** An `upload_records`
  row is written only after a verified copy. A restarted batch skips names that
  already have a row. A resume-by-index checkpoint was removed on purpose,
  because file names are allocated fresh from disk each run. Do not add one.
- **Capture integrity.** The per-image `capture_images` row is the only record
  of which box an image belongs to. If that write fails, the app stores the
  pulled bytes in a file-based "orphan ledger" (not a database table, because
  the database is what failed). `verifyBoxComplete` must pass before a box is
  marked transferred. A mismatch leaves the box `partial`.
- **Locking.** OS file locks and SQLite WAL checkpoints protect the local
  database during a batch (`lib/services/file_lock_service.dart`).

## Conventions that look like mistakes but are not

- `lib/pages/settings_page.dart` holds only `SettingsController`. There is no
  settings page. The file name stays because imports use it.
- `print()` logging with emoji prefixes is the house style. The lints
  `avoid_print`, `deprecated_member_use` and
  `no_leading_underscores_for_local_identifiers` are off in `analysis_options.yaml`.
- `lib/pages/gallery_page.dart` is very large. It is not changed for feature
  work that does not need it. Treat the ADB and transfer half as untouchable.
- `windows/runner/resources/LWCAM.iss` lists the plugin DLLs and the `scrcpy`
  folder by hand. Add a plugin without updating the `.iss` and a release build
  fails on a clean PC.
- `win32`, `ffi` and `hotkey_manager` stay in `pubspec.yaml`. The phone mirror
  and the remote shutter use them.

## Related modules

| Module | Link |
| --- | --- |
| LWCam Admin: the only editor of users, projects, app settings and the station config | [../LWCamAdmin/README.md](../LWCamAdmin/README.md) |
| LWIP: processes the folders LWCAM copies | [../LWIP/README.md](../LWIP/README.md) |
| QC Platform: reviews pages and sends rework back | [../LWCam_QC_Platform/README.md](../LWCam_QC_Platform/README.md) |
| Installers (`LWCamSetup.exe` installs LWCAM and LWCam Admin) | [../installer/README.md](../installer/README.md) |

## Read next

- [AGENTS.md](AGENTS.md): architecture, service by service, and the reasons for
  each non-obvious choice.
- [CHANGELOG.txt](CHANGELOG.txt): history of changes with reasons. Add an entry
  for every user-visible or behavioural change.
