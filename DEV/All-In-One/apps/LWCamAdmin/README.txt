================================================================================
 LWCam Admin
================================================================================

Flutter Windows desktop app holding every SuperAdmin capability for the LWCAM
suite: user management (accounts, roles, Device IDs, password resets), project
management (CRUD, metadata templates), device reassignment, shared app settings
and per-PC station setup.

It is the ONLY writer of `users`, `projects` and `app_settings` in the
PostgreSQL schema shared with LWCAM, and the ONLY editor of
lwcam_node_config.json, the station config that LWCAM, LWIP and the QC backend
all read. Run this app first on any new machine.

Package `lwcam_admin`. Windows is the only target. No capture workflow, no ADB,
no sqflite, no phone.

Chinese version of this file: README_CN.txt


DOCUMENTATION
--------------------------------------------------------------------------------

  AGENTS.md       START HERE. Full architecture, the PostgreSQL gateway, the
                  offline-queue mutation model, and why this app exists.
  CHANGELOG.txt   Dated change history from 2026-07-21, the day this app was
                  split out of LWCAM. Nothing predates that.


COMMANDS
--------------------------------------------------------------------------------

    flutter pub get                          install dependencies
    flutter run -d windows                   run the app
    flutter build windows --release          release build
    flutter analyze                          static analysis
    flutter test                             all tests

Built against Flutter 3.44.4 stable (Dart 3.12.2). `flutter build windows`
needs Visual Studio 2022 with the "Desktop development with C++" workload.

Current state: `flutter analyze` reports no issues.


LOGIN
--------------------------------------------------------------------------------

SuperAdmin only. There is no multi-user login here — the accounts this app
creates log into LWCAM, never into this app.

Login is verified against, in order:

  1. PostgreSQL `app_settings.superadmin_password_hash` (the override)
  2. the local snapshot's copy of that same override
  3. the bcrypt hash compiled into lib/auth/super_admin.dart (the factory hash)

So login works offline, on a fresh PC, with an unreachable database and with no
store configured. The factory hash was generated once and is not derivable from
anything in this repository.

  >>> Ask Lifewood for the factory SuperAdmin password. It is deliberately not
      written down in this handover.


WHAT THIS APP OWNS
--------------------------------------------------------------------------------

  PostgreSQL      users, projects, user_projects, roles, app_settings.
                  Sole writer. LWCAM only pulls these.

  Station config  lwcam_node_config.json, default location
                  %USERPROFILE%\LWCAM_DBs. Station Setup is the only editor of
                  it for the whole suite: this app's PostgreSQL connection,
                  LWCAM's capture-outbox sync toggle, the image destination
                  root, and the LWIP image-processing toggle plus its folder
                  overrides. There are no hand-edited config files anywhere in
                  the suite.

The fresh-PC bootstrap story is deliberate: run a portable LWCam Admin build
once on a new capture PC, fill in Station Setup, and LWCAM picks up the same
file on its next launch.


DESIGN CONSTRAINTS WORTH KNOWING BEFORE YOU EDIT
--------------------------------------------------------------------------------

  * Every mutation goes through the `_mutate` primitive in
    lib/services/admin_store_service.dart: reconcile first (pull before
    transform, so an online edit is never applied on top of a stale local
    copy), apply and validate, then push online or queue offline with
    tombstones. A push failure mid-mutation degrades to the offline branch
    rather than losing the edit. Read that method before changing the file.

  * All SQL lives in lib/services/admin_pg_statements.dart as pure Dart
    builders with no `postgres` import, so it is unit-testable without a
    connection. test/services/fake_admin_gateway.dart is the test double for
    the gateway itself.

  * Upserts conflict on projects(project_key), NEVER project_id. `project_id`
    is a human-editable label this app can rename freely; conflicting on it
    would mint a duplicate cloud row on every rename.

  * LWCAM-owned columns are deliberately excluded from the user upsert's
    DO UPDATE: `last_login_at`, `password` and `must_change_password`. A
    whole-store push carrying a stale snapshot must never regress a password a
    capture user just changed. Admin-intended password writes go through the
    targeted `userPasswordResetSql` instead.

  * projectSoftDeleteSql rewrites `country_location_code` to `~deleted~<id>`.
    That column is a unique FK target that `devices` references, so the real
    code must be freed for reuse.

  * `buildUsersStoreFromPgRows` reads global roles from `users.roles`, NOT
    re-derived from `user_projects` — a zero-project admin would otherwise
    silently lose their role on the next pull.

  * lib/theme/ is a byte-identical copy of LWCAM's. Keep it that way; the
    Lifewood brand theme is shared design language, not per-app. The three
    Flutter apps are fork-style copies, not a shared library, and that is
    intentional — they ship and version independently.

  * windows/runner/resources/LWCamAdmin.iss has its own AppId GUID so this app
    installs alongside LWCAM without collision. It hand-lists the plugin DLLs
    to bundle; adding a plugin without updating it produces a release build
    that fails at runtime on a clean machine.

  * print() logging with emoji prefixes is the house style, same as LWCAM.
    `avoid_print`, `deprecated_member_use` and
    `no_leading_underscores_for_local_identifiers` are ignored in
    analysis_options.yaml.
