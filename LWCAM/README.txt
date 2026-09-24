================================================================================
 LWCAM (Lifewood Capture)
================================================================================

Flutter Windows desktop app for document-digitization capture. It pulls scanned
images from an Android device's DCIM folder over ADB, stages them locally, then
copies them to a local or NAS destination with timeout, stall detection, file
locking and audit logging. Captured work is recorded in a per-device SQLite
database and synced to a shared PostgreSQL schema.

Package `lwcam`. Windows is the only target.

Chinese version of this file: README_CN.txt


DOCUMENTATION
--------------------------------------------------------------------------------

  AGENTS.md          START HERE. Full architecture, service by service, plus
                     the design history and the reasons behind every
                     non-obvious choice. It is the best document in the repo.
  CHANGELOG.txt      Dated change history with rationale. Add an entry for
                     every user-visible or behavioural change you make.
  LWIP\README.txt    The bundled Python deskew/crop/thumbnail watcher this app
                     supervises. Chinese version: LWIP\README_CN.txt.
  LWCam Workflow & SQL update\
                     Capture-side database schema SQL and the ERD.


COMMANDS
--------------------------------------------------------------------------------

    flutter pub get                          install dependencies
    flutter run -d windows                   run the app
    flutter build windows --release          release build
    flutter analyze                          static analysis
    flutter test                             all tests
    flutter test test/services/transfer_destination_service_test.dart

Built against Flutter 3.44.4 stable (Dart 3.12.2). `flutter build windows`
needs Visual Studio 2022 with the "Desktop development with C++" workload.

Current state: `flutter analyze` reports 6 info-level lints and no errors.


RUNTIME REQUIREMENTS
--------------------------------------------------------------------------------

  adb.exe    Resolved, in order, from: next to the exe, the project root,
             C:\Android\platform-tools\adb.exe, then PATH.

  scrcpy     Windows build, next to the exe. Only needed for Box Mode's live
             phone mirror.

  A configured station. LWCAM has NO Settings page. The PostgreSQL connection,
  the image destination root and the LWIP toggle all come from
  %USERPROFILE%\LWCAM_DBs\lwcam_node_config.json, which the sibling LWCam Admin
  app writes from its Station Setup screen. Run LWCam Admin first. If the app
  reports an empty destination, that is Station Setup's job, not a bug here.


THE TWO CAPTURE WORKFLOWS
--------------------------------------------------------------------------------

Both live behind a per-account metadata-keying toggle set in LWCam Admin.

  Normal Mode (/gallery, keying off)
      The legacy flow. Pull from the phone, transfer to the dated destination.

  Box Mode (/boxes, keying on)
      Capture boxes hold keyed folders (cover tag, image tags, title, volume,
      dates, archival reference number, record type). Each folder gets its own
      destination subdirectory at transfer time. Transfers run in a background
      per-box queue; each box tile shows live progress and a PERSISTED outcome
      that survives a restart, with a per-tile Retry for interrupted, partial
      or failed boxes.

Destination layout produced by a transfer:

    <root>\<work week, e.g. "June 15-19">\<YYYYMMDD>\<folder>\

Work weeks run Monday to Friday; weekend dates fall into the preceding work
week. This is the only unit-tested code inherited unchanged from the pre-fork
app (test/services/transfer_destination_service_test.dart).


RELIABILITY MACHINERY
--------------------------------------------------------------------------------

Understand this before touching the transfer path.

  Timeouts       10-minute hard limit per file copy; 30-second stall detection
                 checked every 5 seconds; destination-availability polling with
                 a reconnect dialog. The constants are at the top of
                 lib/controllers/upload_contoller.dart.

  Crash recovery Database-based, not checkpoint-based. An `upload_records` row
                 is written only AFTER a verified copy, and a restarted batch
                 skips already-recorded base names. A resume-by-index
                 checkpoint was deliberately REMOVED on 2026-07-20 — names are
                 allocated fresh from disk state each run, so a saved index can
                 never match after a restart. Do not reintroduce one.

  Capture        The per-image `capture_images` assignment is the ONLY record
  integrity      of box membership, so a lost capture-time write must never go
                 unnoticed. A failed write stashes the pulled bytes to a
                 FILESYSTEM orphan ledger — deliberately not a database table,
                 since the database is what just failed — and `verifyBoxComplete`
                 gates every transfer-complete marking. A mismatch leaves the
                 box 'partial', never transferred.

  Locking        OS-level file locks and WAL checkpointing guard the SQLite
                 database during a batch (lib/services/file_lock_service.dart,
                 111 lines, self-documenting).


CONVENTIONS THAT ARE NOT ACCIDENTS
--------------------------------------------------------------------------------

  * lib/controllers/upload_contoller.dart is misspelled and the misspelling is
    load-bearing — imports depend on it.

  * lib/pages/settings_page.dart holds only `SettingsController`. There is no
    settings page; the filename survives for the same reason.

  * print() logging with emoji prefixes is the house style. `avoid_print`,
    `deprecated_member_use` and `no_leading_underscores_for_local_identifiers`
    are deliberately ignored in analysis_options.yaml.

  * lib/pages/gallery_page.dart is ~5900 lines and hosts the ADB plumbing, the
    replacement-image workflow and the QC rework loop. Project convention is
    that it is never modified for feature work that does not require it. Treat
    the ADB/transfer half as untouchable.

  * windows/runner/resources/LWCAM.iss hand-lists the plugin DLLs and the
    scrcpy folder to bundle. There is no automation. Adding a plugin without
    updating the .iss produces a release build that fails at runtime on a
    clean machine.

  * win32, ffi and hotkey_manager stay in pubspec.yaml even though little
    currently uses them — the phone mirror and remote shutter plumbing depends
    on them.


RELATED APPLICATIONS
--------------------------------------------------------------------------------

  LWCam Admin        The only writer of users, projects and app settings, and
                     the only editor of the station config. LWCAM pulls all of
                     it and never writes it, apart from three whitelisted
                     calls: own-password change, login timestamp, and the
                     project `has_data` flag.

  LWCam QC Platform  The web QC console. Rejections come back to LWCAM as
                     `rework_logs` rows and surface as a "Needs Rework" badge
                     on the box list.

  LWRework           A separate rework-only fork, not part of this handover.
                     Note that LWCAM ALSO has a rework loop, added 2026-07-30 —
                     a different design that lives inside gallery_page.dart,
                     not the standalone Rework Mode that lives in LWRework.
