================================================================================
 LWCAM SUITE — DEVELOPER HANDOVER
 Prepared 2026-08-10 by Lifewood (jackson.choy@lifewood.com)
================================================================================

This folder contains the complete, build-verified source for the three
applications that make up the LWCAM document-digitization pipeline, plus the
Python image-processing tool one of them supervises.

Nothing here is a build output. Everything compiles from source with the
toolchains listed under "Prerequisites".

Chinese version of this file: README_CN.txt


--------------------------------------------------------------------------------
 0. CONTENTS
--------------------------------------------------------------------------------

  LWCamAdmin\           Flutter/Windows. Administration app.
  LWCAM\                Flutter/Windows. Capture app.
    LWCAM\LWCam Workflow & SQL update\
                        Capture-side database schema SQL + ERD.
  LWIP\                 Python. Deskew/crop/thumbnail watcher. Its own
                        top-level product since 2026-09-25 (formerly nested
                        inside LWCAM).
  LWCam_QC_Platform\    Vue 3 + FastAPI. QC review web platform.
    LWCam_QC_Platform\database\
                        Unified schema SQL + idempotent migrations.
    LWCam_QC_Platform\scripts\setup_qc_db.py
                        Creates the database and applies the schema.
    LWCam_QC_Platform\shared-images\
                        Empty. Default Docker mount for captured images.
  README.txt            This file.
  README_CN.txt         Chinese translation of this file.

Documentation is deliberately uniform. Every project has exactly three
documents, and no others:

  AGENTS.md       The deep architecture reference. Written service by service,
                  with the design history and the reasoning behind every
                  non-obvious choice. This is where you go to understand the
                  code. English only — the filename is read by tooling.
  README.txt      Setup, commands, runtime requirements, and the conventions
                  that look like mistakes but are not. English, primary.
  README_CN.txt   Chinese translation of README.txt.

Plus, where they exist:

  CHANGELOG.txt   Dated, reason-annotated change history (both Flutter apps).
  LWIP\README.txt / README_CN.txt
                  Full behavioural spec of the image watcher — stability
                  gates, atomic publication, checksum audits, recovery. LWIP
                  has no AGENTS.md, so this file is its whole documentation.

Reading order for a new developer: this file, then the AGENTS.md of whichever
application you are assigned to, then that project's README.txt when you are
ready to build it.

Every project follows the convention that CHANGELOG.txt gets an entry for each
user-visible or behavioural change. Please keep that up.

Sixteen pre-fork or duplicated documents were removed on 2026-08-10 while
preparing this handover: LWCAM's ten (five near-duplicate "Phase 1" status
reports, an index of them, a July deployment checklist, IMPROVEMENTS_PLAN.md,
TESTING_GUIDE_PHASE1.md and Life_Transfer_Documentation.docx), the QC
platform's backend/README.md and its two Chinese agent-authored design notes,
and assorted stubs. They described the pre-fork LifeTrans app — the .docx even
calls it "LWIP", which now means something else entirely — and documented a
checkpoint system deleted on 2026-07-20. FILE_LOCK_SERVICE_DOCS.md went with
them because its API reference was wrong: it described a "200+ line" service
with seven members, where lib/services/file_lock_service.dart is 111 lines with
four. Everything of substance was folded into the AGENTS.md and README.txt
files above. The originals remain in Lifewood's working copy.


--------------------------------------------------------------------------------
 1. HOW THE PIECES FIT TOGETHER
--------------------------------------------------------------------------------

  Android phone (document scans in DCIM)
        |  adb.exe  (pull / delete / launch camera)
        v
  +----------------+       reads config        +------------------+
  |     LWCAM      | <------------------------ |   LWCam Admin    |
  | capture app    |  lwcam_node_config.json   | admin app        |
  +----------------+                           +------------------+
        |  verified file copy                          |
        v                                              | owns users /
  <destination>\<work week>\<YYYYMMDD>\<folder>\        | projects /
        |                                              | app_settings
        |  lwcam_capture_marker.json written            |
        v                                              v
  +----------------+   results   +-----------------------------------+
  |      LWIP      | ----------> |         PostgreSQL (shared)       |
  | deskew / crop  |             |  users, projects, app_settings,   |
  | / thumbnails   |             |  capture_boxes/_folders/_images,  |
  +----------------+             |  rework_logs, qc_* tables         |
        |                        +-----------------------------------+
        |  processed images                    ^          |
        v                                      |          v
  <processed root>\...  <-------------  +---------------------+
                          reads images  |  QC Platform        |
                                        |  FastAPI + Vue 3    |
                                        +---------------------+
                                                 |
                                                 v
                                        Export folder (CSV + images)

Roles in one line each:

  LWCam Admin   The ONLY writer of users / projects / app_settings in
                PostgreSQL, and the ONLY editor of the per-PC station config.
                SuperAdmin-only login. No capture workflow, no phone, no
                local SQLite.

  LWCAM         The operator-facing capture app. Pulls images off the phone
                over ADB, keys metadata (Box Mode), copies to the destination
                with heavy reliability safeguards, records everything in a
                local SQLite DB, and drains a sync outbox into PostgreSQL.
                It PULLS users/projects/settings and never writes them
                (three whitelisted exceptions: own-password change, login
                timestamp, project has_data flag).

  LWIP          Standalone Python watcher. Watches the capture destination for
                folders carrying a completion marker, deskews/crops/thumbnails
                them into an output root, and writes integrity manifests. It
                touches no database; LWCAM tails its state.json and reports
                results. Runs either standalone or supervised by LWCAM.

  QC Platform   Web app for the QC team. Reads processed folders from disk and
                capture rows from PostgreSQL, lets QC claim tasks, review and
                fix images, edit metadata, pass or reject per image, then
                export. Rejections come back to LWCAM as rework_logs rows.

Direction of truth:
  * PostgreSQL is the source of truth for users, projects and app settings.
  * The phone is the source of truth for captured image bytes, with one
    documented exception (see LWCAM\AGENTS.md, stageBoxFiles).
  * The local SQLite DB is the source of truth for box membership on the
    capture PC, and its sync_outbox rows exist nowhere else until pushed.


--------------------------------------------------------------------------------
 2. PREREQUISITES
--------------------------------------------------------------------------------

Windows is the only supported target for LWCAM, LWCam Admin and LWIP. The QC
platform runs anywhere Docker or Python+Node run, but was developed on Windows.

  Flutter          3.44.4 stable (Dart 3.12.2). Both Flutter apps declare
                   environment sdk ^3.8.1, so anything from Flutter 3.32 up
                   should resolve; 3.44.4 is what the delivered pubspec.lock
                   files were generated against.
  Visual Studio    2022 with the "Desktop development with C++" workload —
                   required by `flutter build windows`.
  Python           3.13 for LWIP (pinned wheels: numpy 2.5.1,
                   opencv-python 4.13.0.92, Pillow 11.3.0).
                   3.11+ for the QC backend.
  Node.js          20+ for the QC frontend (Vite 6, Vue 3.5, TypeScript 5.6).
  PostgreSQL       Any recent server. The suite has been run against a LAN
                   server and against a local install. Default DB name `lwcam`.
  adb.exe          Android platform-tools. LWCAM resolves it, in order, from:
                   next to the exe, the project root,
                   C:\Android\platform-tools\adb.exe, then PATH.
  scrcpy           Windows build, only for LWCAM's Box Mode phone mirror.
                   NOT included here — see section 7.
  Docker Desktop   Optional, only for the QC platform's compose workflow.
  Inno Setup 6     Only if you need to rebuild the Windows installers.


--------------------------------------------------------------------------------
 3. PROJECT: LWCamAdmin
--------------------------------------------------------------------------------

Flutter Windows desktop app. Package `lwcam_admin`, window title "LWCam Admin".
State management, routing and DI use GetX throughout, as in all three Flutter
apps in this family.

Build and run:

    cd LWCamAdmin
    flutter pub get
    flutter run -d windows
    flutter analyze                  # currently: no issues
    flutter test
    flutter build windows --release

Login: SuperAdmin only. There is no multi-user login here — the accounts this
app creates log into LWCAM, never into this app. The SuperAdmin bcrypt hash is
compiled into lib/auth/super_admin.dart and is byte-identical to the copy that
used to live in LWCAM. It is not derivable from anything in the source; it was
generated once. An override hash can be set from the app and is stored in
PostgreSQL's app_settings, with the compiled-in hash as the offline fallback,
so login always works on a fresh or disconnected PC.

  >>> ASK LIFEWOOD FOR THE FACTORY SUPERADMIN PASSWORD BEFORE YOU START.
      It is deliberately not written down in this handover.

What it owns:
  * users, projects, user_projects, roles, app_settings in PostgreSQL.
    It is the only writer. See lib/services/admin_pg_statements.dart — pure
    Dart SQL builders with no `postgres` import, unit-testable without a live
    connection.
  * lwcam_node_config.json — the per-PC station config that LWCAM, LWIP and
    the QC backend all read. Station Setup is the only editor of it, for every
    app in the suite. There are no hand-edited config files anywhere.

Offline behaviour is a first-class design constraint, not a nicety: every
mutation reconciles first, then pushes, and degrades to a local queue with
tombstones when PostgreSQL is unreachable. Read the `_mutate` primitive in
lib/services/admin_store_service.dart before changing anything in that file.

Key files to read first:
  lib/services/admin_store_service.dart     the mutation/reconcile engine
  lib/services/admin_pg_gateway.dart        the PostgreSQL seam (+ test double)
  lib/services/admin_pg_statements.dart     all SQL, pure Dart
  lib/controllers/station_setup_controller.dart   the station config editor
  lib/models/node_config.dart               the shared config shape

Installer: windows/runner/resources/LWCamAdmin.iss (Inno Setup). It has its own
AppId GUID, distinct from LWCAM's, so both install side by side. It hand-lists
the plugin DLLs to bundle — if you add or remove a plugin with a Windows
implementation, update the .iss in the same commit or the release build ships
broken.


--------------------------------------------------------------------------------
 4. PROJECT: LWCAM
--------------------------------------------------------------------------------

Flutter Windows desktop app. Package `lwcam`, window title
"LWCAM (Lifewood Capture)".

Build and run:

    cd LWCAM
    flutter pub get
    flutter run -d windows
    flutter analyze                  # currently: 6 info-level lints, no errors
    flutter test
    flutter test test/services/transfer_destination_service_test.dart
    flutter build windows --release

There is no Settings page in LWCAM by design. If the app complains that the
destination is empty, that is Station Setup's job — run LWCam Admin.

Two capture workflows behind a per-account metadata-keying toggle:
  * Normal Mode (`/gallery`, keying off) — the legacy flow.
  * Box Mode (`/boxes`, keying on) — boxes contain keyed folders, each folder
    gets its own destination subdirectory, transfers run in a background
    per-box queue with persisted per-tile outcomes and retry.

Reliability machinery you should understand before touching the transfer path:
  * 10-minute per-copy timeout, 30-second stall detection checked every 5 s,
    destination-availability polling with a reconnect dialog. Constants live
    at the top of lib/controllers/upload_contoller.dart.
  * Crash recovery is DB-based, not checkpoint-based. An upload_records row is
    written only after a verified copy; a restarted batch skips already
    recorded base names. A resume-by-index checkpoint was deliberately removed
    on 2026-07-20 — do not reintroduce one.
  * Capture integrity: the per-image capture_images assignment is the only
    record of box membership. A failed write stashes bytes to a filesystem
    orphan ledger (deliberately NOT a DB table — the DB is what just failed),
    and verifyBoxComplete gates every transfer-complete marking.
  * OS-level file locks and WAL checkpointing guard the SQLite DB during a
    batch.

Two filenames are misspelled and the misspellings are load-bearing —
imports depend on them. Do not "fix" them casually:
    lib/controllers/upload_contoller.dart      (sic — "contoller")
    lib/pages/settings_page.dart               (holds only SettingsController;
                                                there is no settings page)

Highest-risk file: lib/pages/gallery_page.dart, roughly 5900 lines. It hosts
the ADB plumbing, the replacement-image workflow and the QC rework loop. The
project convention is that it is never modified for feature work that does not
require it. Treat the ADB/transfer half as untouchable and budget accordingly.

Local database: lib/db/upload_stats_db.dart, singleton over sqflite FFI, in
%USERPROFILE%\LWCAM_DBs\lwcam_stats_<deviceId>.db, plus one monthly-rotation
file per device per month for the two high-volume tables. The capture tables
MIRROR the cloud schema column-for-column. Stable schema is at version 2 with
a real onUpgrade migration. There is a corruption-recovery path that rebuilds
the local DB from a PostgreSQL snapshot; read it before changing DB open logic.

Sync pipeline: lib/services/sync_service.dart, 30-second tick. Each tick pulls
a fresh users/projects/app_settings snapshot first, then drains the outbox.
Outbox payloads carry NATURAL keys and the sink resolves cloud identity ids per
batch. Projects resolve by `project_key`, never by `project_id` — the latter is
a human-editable label LWCam Admin can rename freely. Getting this wrong mints
duplicate cloud rows.

Key files to read first:
  lib/services/sync_service.dart, pg_sync_sink.dart, pg_statements.dart
  lib/db/upload_stats_db.dart
  lib/services/transfer_destination_service.dart   (the folder layout rule)
  lib/services/box_integrity.dart, orphan_image_store.dart
  lib/services/lwip_service.dart, processing_report_service.dart
  lib/services/rework_service.dart, open_rework_cache.dart

Destination layout produced by transfers:
  <root>\<work week, e.g. "June 15-19">\<YYYYMMDD>\<folder>\
Weeks run Monday to Friday; weekend dates fall into the preceding work week.
This is the only unit-tested code inherited unchanged from the pre-fork app.

Installer: windows/runner/resources/LWCAM.iss. It hand-lists the plugin DLLs
AND the scrcpy-win64 folder. Same warning as above: keep it in sync.

--- LWIP -----------------------------------------------------------------------

Standalone Python watcher. Its own top-level product since 2026-09-25
(formerly nested inside the LWCAM folder).

    LWIP\backend\deskew_crop_tool\    the tool (config, image_ops, orchestrator)
    LWIP\backend\tests\               unittest suite
    LWIP\config\deskew_crop_config.json
    LWIP\SETUP_DESKEW_CROP.bat        one-time offline setup
    LWIP\START_DESKEW_CROP.bat        continuous watcher
    LWIP\RUN_TESTS.bat                end-to-end verification

The two .bat files expect a private Python and an offline wheel cache that are
NOT in this handover (see section 7). To run it from a normal developer
environment instead:

    cd LWIP
    python -m venv venv
    runtime\python\python.exe -m pip install -r requirements.txt
    runtime\python\python.exe -m unittest discover -s backend/tests -v
    runtime\python\python.exe -m deskew_crop_tool        # run from backend\

Creating the venv at LWIP\venv with that exact name makes the delivered .bat
files work again unchanged, since they invoke runtime\python\python.exe.

How LWCAM drives it: when the station config enables processing, LWCAM writes
deskew_crop_config.json (absolute paths, folder_depth 2, completion marker
"lwcam_capture_marker.json", 512px thumbnails), spawns the tool bound to a
kill-on-close Win32 job object, and restarts it on crash with backoff. A folder
is only eligible once LWCAM has written the marker into it, which happens only
after the box's transfer fully verifies. LWIP never touches the database; it
embeds the marker's identity in its output manifest and LWCAM reports the
result. Read LWIP\README.txt in full — it documents the stability gates,
atomic publication, checksum audits and recovery behaviour precisely.


--------------------------------------------------------------------------------
 5. PROJECT: LWCam_QC_Platform
--------------------------------------------------------------------------------

Vue 3 + Vite + TypeScript + Element Plus + Pinia + Vue I18n + ECharts frontend,
FastAPI + SQLAlchemy backend, PostgreSQL.

Local development:

    cd LWCam_QC_Platform\backend
    python -m venv .venv
    .\.venv\Scripts\Activate.ps1
    pip install -r requirements.txt
    copy .env.example .env            # then edit DB_* and JWT_SECRET
    uvicorn app.main:app --reload --port 8080

    cd LWCam_QC_Platform\frontend
    npm install
    npm run dev

    # verification
    cd backend  && python -m compileall app     # currently clean
    cd backend  && pytest
    cd frontend && npm run build

Docker (frontend + backend only — it does NOT start PostgreSQL and does NOT
create or migrate the schema):

    copy .env.example .env            # edit it first, see below
    docker compose up -d --build

Default ports: 5432 PostgreSQL, 8080 backend, 5174 frontend console.
  http://localhost:5174        QC console
  http://localhost:8080/docs   API documentation

Configuration precedence: in production the backend reads
%USERPROFILE%\LWCAM_DBs\lwcam_node_config.json, located via the
LWCAM_NODE_CONFIG environment variable — the same file LWCam Admin writes.
See backend/app/core/node_config.py. The .env files document the same settings
for local development. Required keys in the node config are pgHost, pgDatabase,
pgUser, pgPassword, qcJwtSecret (minimum 32 characters), qcInputRoot and
qcOutputRoot. When a node config is used, the preview / work / audit caches are
forced to %LOCALAPPDATA%\LWCam\QC regardless of the .env values.

Image paths: capture_folders.folder_path and thumbnail_path in the database
must be readable by the account running the backend. Under Docker they must be
CONTAINER paths, not Windows host paths — the host prefix goes in
CAPTURE_IMAGE_HOST_PATH and must exactly match the prefix stored in the
database rows. This is the single most common cause of "page loads but images
are missing".

API surface (full list in LWCam_QC_Platform\README.txt section 7):
    /api/auth/login, /api/auth/me, /api/auth/password
    /api/admin/*                     statistics, users, QC project assignment
    /api/admin/qc-tasks/*            view and release stuck QC tasks
    /api/qc/metadata-tasks/*         claim, release, edit metadata, image
                                     operations, drafts, review, preview
    /api/exports/*                   export preflight, run, status

Every response, success or failure, is {code, message, data}, and the message
reaches the operator verbatim.

The backend NEVER creates tables at startup. Apply the schema first — see
section 6.

  >>> LANGUAGE NOTE. backend/tests/test_no_cjk.py enforces that no CJK
      characters appear under backend\ — app/**/*.py, tests/*.py,
      backend/README.md and backend/.env.example. A commit that adds Chinese
      strings to the backend fails the test suite. This is intentional: the
      codebase was de-localized on 2026-08-07 and the frontend ships en-US
      only. The gate does not reach the project root, which is why
      README_CN.txt is allowed to exist. README.txt is the English primary and
      should be updated first; README_CN.txt tracks it.

Key files to read first (AGENTS.md explains all of them in context):
  backend/app/core/paths.py          host-to-container path translation, the
                                     subtlest piece of the backend
  backend/app/core/node_config.py    the shared-config contract
  backend/app/dependencies.py        role_set vs role — read the comment
  backend/app/routers/qc.py          the QC task lifecycle (~1750 lines)
  backend/app/services/qc_drafts.py  the on-disk draft model: no QC edit ever
                                     touches a source image before approval
  backend/app/services/qc_separation.py   the staged folder split + rollback
  backend/app/services/export.py     the export pipeline (~1130 lines)
  frontend/src/views/qc/QcIndexView.vue   the main review screen


--------------------------------------------------------------------------------
 6. DATABASE SCHEMA
--------------------------------------------------------------------------------

All three apps share ONE PostgreSQL schema, and no application creates it.
LWCAM never creates cloud schema — the team applies the SQL file manually. The
QC backend never creates tables at startup. Applying the schema is therefore
step one of standing up any environment.

The files:

  LWCam_QC_Platform\database\LWCam_database_unified_20260731.sql
        The unified schema. Apply this to an EMPTY database. This is the file
        to use for a fresh environment.
  LWCam_QC_Platform\database\migrations\001_qc_platform_deltas.sql
  LWCam_QC_Platform\database\migrations\002_role_case_normalization.sql
        Both idempotent. Apply these to a database that already has the
        capture schema but predates the QC platform.
  LWCam_QC_Platform\scripts\setup_qc_db.py
        Does the above decision for you. Creates the database if missing,
        applies the unified schema when public.capture_folders is absent,
        otherwise applies both migrations, then verifies that
        capture_folders.qc_locked_by exists and fails loudly if it does not.
  LWCAM\LWCam Workflow & SQL update\LWCam_database_20260720.sql
        The capture-side authority referenced throughout LWCAM's AGENTS.md.
        LWCAM's local SQLite capture tables mirror this file column for
        column. When you change one, change the other.
  LWCAM\LWCam Workflow & SQL update\LWCam_database_20260720_updated_ERD.drawio
  LWCAM\LWCam Workflow & SQL update\...drawio.svg
        Entity-relationship diagram. Open the .drawio in diagrams.net; the
        .svg is for quick viewing.
  LWCAM\LWCam Workflow & SQL update\LWCam software development.xlsx
        Development tracking spreadsheet, included for context.

Applying it:

    cd LWCam_QC_Platform
    pip install "psycopg[binary]"                # if not already in your venv
    python scripts\setup_qc_db.py ^
        --config %USERPROFILE%\LWCAM_DBs\lwcam_node_config.json ^
        --database-dir database

    python scripts\setup_qc_db.py --self-test    # no database needed

The --config file is the station config LWCam Admin writes; the script reads
pgHost, pgPort, pgDatabase, pgUser, pgPassword and pgUseSsl from it. If you
have not run Station Setup yet, hand-write a JSON file with just those keys.
In production the LW Suite installer runs this script through a SETUP_QC_DB.bat
wrapper when Station Setup is saved; that wrapper is bound to the installer's
folder layout and is deliberately not shipped here — invoke the .py directly.

Applying the SQL by hand instead works too, but note the unified schema file
contains psql meta-commands (lines starting with a backslash). setup_qc_db.py
strips them; `psql -f` handles them natively; a plain driver execute() will
choke on them.

Schema facts you will need:

  * Global user roles live in users.roles, NOT derived from user_projects.
    A zero-project admin would otherwise silently lose their role on the next
    sync pull.
  * projects.project_key is the stable identity everything resolves by.
    projects.project_id is a freely renamable human label owned by LWCam
    Admin. Resolving by project_id mints duplicate cloud rows on rename.
  * projects.country_location_code is a unique FK target that devices
    reference — the device-to-project binding is structural. A soft-deleted
    project's code is rewritten to ~deleted~<id> so the real code can be
    reused.
  * project_id, project_name and users.device_id are partial unique indexes
    over live rows only.
  * Column ownership is strict and enforced by convention only:
      LWCam Admin  users, projects, user_projects, roles, app_settings
      LWCAM        capture_boxes, capture_folders, capture_images, rework_logs
      QC           group_id, client_qc_status, client_rework on capture_folders
    Crossing those lines causes silent data loss on the next sync tick.
  * There are exactly two writers of the capture_folders pipeline columns
    (is_deskewed / is_cropped / is_created_thumbnail / folder_path /
    thumbnail_path / qc_status). See LWCAM\AGENTS.md, the sync-pipeline
    bullet, before adding a third.


--------------------------------------------------------------------------------
 7. WHAT IS NOT IN THIS HANDOVER
--------------------------------------------------------------------------------

Excluded because they are regenerated by the build:
    build\, .dart_tool\, .flutter-plugins-dependencies
    windows\flutter\ephemeral\      (308 MB per Flutter app — `flutter pub get`
                                     and the first build recreate it)
    frontend\node_modules\, frontend\dist\
    __pycache__\, .pytest_cache\, backend\.cache\
    LWIP\runtime\ (the private 3.13 interpreter, plus state and logs),
    LWIP\wheels\ (offline wheel cache), nuget.exe

Excluded deliberately:
    .git histories.  This is a clean snapshot, not a repository — see
        section 12 for how it is version-controlled now. The .gitignore files
        are in place and were corrected for this handover: the QC one
        previously ignored database\ and scripts/serve_frontend.py, which would
        have dropped the schema on the first commit.
    Sixteen pre-fork or duplicated documents. See section 0.
    LWIP\Test Images\  — 18 real client scans, ~304 MB. Sample data, not test
        fixtures: the unittest suite does not use them. Ask if you want them.
    .claude\ — machine-specific tooling state, plus two Chinese agent-authored
        design notes for an optional QC workflow variant that was largely never
        built. Ask Lifewood if you want them.
    scrcpy-win64  — third-party binary, used only by LWCAM's Box Mode phone
        mirror. Download the official Windows build, or ask Lifewood for the
        v4.0 copy currently in use.
    adb.exe  — install Android platform-tools.
    .env files with real credentials. Only .env.example files are included.
    SETUP_QC_DB.bat  — the installer-side wrapper around setup_qc_db.py. It
        hard-codes the LW Suite deployment layout (a private Python runtime at
        runtime\python\python.exe and a sibling database\ folder), so it would
        not work from a source checkout. The script it calls IS included, at
        LWCam_QC_Platform\scripts\setup_qc_db.py — invoke it directly, see
        section 6.

The database schema and ERD ARE included — see section 6.


--------------------------------------------------------------------------------
 8. FIRST DAY: RECOMMENDED ORDER
--------------------------------------------------------------------------------

  1. Read LWCAM\AGENTS.md end to end. Then LWCamAdmin\AGENTS.md and
     LWCam_QC_Platform\AGENTS.md. Budget two hours; they will save you a week.
  2. Install PostgreSQL. Create the login role the suite will use; you do not
     need to create the database itself.
  3. Build LWCam Admin, log in as SuperAdmin, fill in Station Setup. This
     writes %USERPROFILE%\LWCAM_DBs\lwcam_node_config.json, which everything
     else reads. Nothing in the suite is configured any other way.
  4. Apply the schema (section 6). setup_qc_db.py reads the node config you
     just wrote, creates the database and applies the unified SQL in one go.
     Station Setup will report a healthy connection afterwards; before it, a
     "schema outdated" state is expected and correct.
  5. Create a project (it needs a unique country/location code) and a user
     with the capture role and a Device ID.
  6. Build and run LWCAM. It reads the same node config. Without a phone you
     can still exercise login, the box list and the DB layer.
  7. Bring up the QC platform locally against the same database.
  8. Only then start on LWIP, which needs a real folder of images to be
     interesting.

Sanity checks that should all pass on a clean checkout:

    cd LWCamAdmin        && flutter pub get && flutter analyze && flutter test
    cd LWCAM             && flutter pub get && flutter analyze && flutter test
    cd LWCam_QC_Platform\backend  && python -m compileall app && pytest
    cd LWCam_QC_Platform\frontend && npm install && npm run build

Verified at handover time: LWCamAdmin analyze is clean; LWCAM analyze reports
6 pre-existing info-level lints and no errors; the QC backend byte-compiles
clean.


--------------------------------------------------------------------------------
 9. CONVENTIONS THAT ARE NOT ACCIDENTS
--------------------------------------------------------------------------------

Several things in this codebase look like mistakes and are not. Before
"cleaning up", check this list and the AGENTS.md History sections.

  * `upload_contoller.dart` and `settings_page.dart` — see section 4.
  * print() logging with emoji prefixes is the established style across all
    three Flutter apps. avoid_print, deprecated_member_use and
    no_leading_underscores_for_local_identifiers are deliberately ignored in
    analysis_options.yaml.
  * The three Flutter apps are fork-style copies, NOT a shared library. Shared
    files (lib/theme/, super_admin.dart) are intentionally byte-identical
    duplicates. Keep them identical rather than extracting a package — the
    apps ship and version independently.
  * A fourth sibling exists: LWRework, the rework-only fork. It is not part of
    this handover. Note that LWCAM ALSO has a rework loop, added 2026-07-30 —
    it is a different design that lives inside gallery_page.dart, not the
    standalone Rework Mode that lives in LWRework.
  * Each app defines only its own UserRole values (LWCAM: admin/capture;
    LWCam Admin: SuperAdmin-only; LWRework: admin/rework). Unknown role
    strings parse to nothing rather than throwing. That tolerance is load-
    bearing for accounts that pre-date the splits.
  * win32, ffi and hotkey_manager stay in the dependency list even where
    nothing currently uses them — the phone mirror and remote shutter are
    planned to return.
  * The Inno Setup .iss files hand-list plugin DLLs. There is no automation
    for this. Adding a plugin without updating the .iss produces a release
    build that fails at runtime on a clean machine.


--------------------------------------------------------------------------------
 10. RUNTIME PATHS AND PORTS (CHEAT SHEET)
--------------------------------------------------------------------------------

  %USERPROFILE%\LWCAM_DBs\lwcam_node_config.json   shared station config,
                                                   written by LWCam Admin,
                                                   read by LWCAM, LWIP and the
                                                   QC backend
                                                   (env var LWCAM_NODE_CONFIG)
  %USERPROFILE%\LWCAM_DBs\lwcam_users.json         local read-only snapshot of
                                                   users/projects/settings
  %USERPROFILE%\LWCAM_DBs\lwcam_stats_<id>.db      LWCAM per-device SQLite DB
  %USERPROFILE%\LWCAM_DBs\lwcam_transfer_in_progress.lock
  %LOCALAPPDATA%\LWCam\QC\{previews,qc_work,qc_audit}   QC caches
  %USERPROFILE%\Downloads\lwcam_log_<timestamp>.txt     crash log

  On the phone: /storage/emulated/0/DCIM/..., /sdcard/life_transfer_camera_ui.xml
  Per capture folder: lwcam_capture_marker.json  (LWIP's completion gate)

  5432  PostgreSQL        8080  QC backend        5174  QC console
  Only 5174 needs to be reachable from operator PCs.


--------------------------------------------------------------------------------
 11. OPEN ITEMS / KNOWN GAPS
--------------------------------------------------------------------------------

  1. Every README_CN.txt is maintained by hand. Nothing enforces that a
     Chinese copy tracks its English original; the English copy always wins.
  2. Schema application is a script, not a migration system. Alembic is a
     dependency of the QC backend and alembic.ini exists, but there are no
     versioned migrations under backend/app/db/migrations — only env.py, and
     the two files under database\migrations\ are hand-written idempotent SQL.
     Putting the schema under real migration control would be a high-value
     early contribution.
  3. LWCAM's local SQLite capture tables mirror LWCam_database_20260720.sql by
     hand. Nothing enforces that they stay in step.
  4. Column ownership across the three apps is enforced by convention and code
     review only, not by database permissions.
  5. LWCAM's gallery_page.dart is ~5900 lines and is the acknowledged risk
     concentration in the suite.


--------------------------------------------------------------------------------
 12. SOURCE CONTROL
--------------------------------------------------------------------------------

This snapshot is version-controlled as a SINGLE private repository containing
all three applications:

    github.com/djchoy-LW/LWCAM-Suite       (private)

One repository rather than three, deliberately. The three applications share
one PostgreSQL schema and a set of contracts that only hold if all sides agree:
the column-ownership table in section 6, `project_key` as the resolution key,
`users.roles` as the role source, and the bcrypt prefix/cost that makes a hash
written by one app readable by the others. A change that touches two of them
should be one reviewable commit, not two commits in two repositories that can
be merged in either order or only half-deployed.

The trade-off is that the apps version and ship independently, so a release tag
covers the whole suite whether or not every app changed. Tag as
`<app>-v<version>` (for example `lwcam-v1.1.0`) rather than tagging the repo as
a unit.

Layout notes:

  * There is no root .gitignore. Each project has its own and they are scoped
    correctly — Flutter's `/build/` patterns are anchored to the directory
    holding the .gitignore, so they do not leak across projects.
  * LWIP is its own top-level project with its own .gitignore, tracked as
    ordinary directories. It is not a submodule and should not become one.
    Formerly nested inside LWCAM (which resolved it by relative path at
    runtime); it moved to the repository root as its own product on
    2026-09-25.
  * No LICENSE file. Absence of a license means all rights reserved, which is
    the intent for proprietary client work.

Credentials: no real secret should ever be committed here, private repository
or not — history is permanent and the dev team inherits everything in it. Two
were removed on 2026-08-10 before the first push: a hardcoded PostgreSQL
password that was the default value of `db_password` in
backend/app/core/config.py, and the same password used as the plaintext in
backend/tests/test_password_interop.py (the fixture was regenerated with a
throwaway string and a freshly Dart-produced hash, so the test still proves
exactly what it did before). Rotate that PostgreSQL password anyway — it was in
a working copy for some time.

================================================================================
 END
================================================================================
