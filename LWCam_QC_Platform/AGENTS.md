# LWCam QC Platform — the standalone QC console

The QC engine as a **server**, not a sidecar: a FastAPI backend and a Vue 3
frontend that several reviewers reach over the LAN with a browser.

`AGENTS.md` at the repository root is the workspace guide and stays authoritative
for build, test and ship across all modules. This file covers this module.
Records of the non-obvious decisions are in `docs/decisions/`.

## What it is, and what it deliberately is not

The design point everything turns on: **QC is standalone. It speaks to the other
parts only through the database.** No shared config file, no IPC, no assumption
that capture and QC are the same PC. It owns its own settings file (`config.txt`,
below) rather than reading Station Setup's.

| In | Out |
| --- | --- |
| Review, approve, reject, separation, client rework | Capture and LWIP: those stay with their own modules |
| Export to a TIFF/JPEG package, the Exports screen | Upload to S3: the standalone LWCam Upload service does it |
| Admin: dashboards, QC paths, zip/TIFF toggles, AI settings | |
| **SuperAdmin only**: user management, project creation | A QC admin must never reach these |

LWCam Upload (`LWCam_Upload/`) watches this server's `qcOutputRoot` on its own
schedule and has its own settings and console. This server does not sweep, retry
or report upload status. A republished (client-rework) package is uploaded again
because Upload fingerprints each package's files, not because this server clears
anything.

PostgreSQL is local, central or cloud. **No Docker**: the server runs on the
embeddable Python the installers ship.

## Running it

```bash
cd backend
python run_server.py    # port from config.txt, else 8080
```

Everything comes from `config.txt` (below). The server does not read LWCam
Admin's `lwcam_node_config.json`, so `LWCAM_NODE_CONFIG` does nothing here. The
file needs at least `dbHost`/`dbName`/`dbUser`/`dbPassword`. Without `jwtSecret`
the development secret is used, and the server refuses it on any non-loopback
`bindHost`. Copy `config.example.txt` to `config.txt` to start (the real file is
gitignored).

An installed server (QCPlatformSetup.exe) keeps it at `<install>\config\config.txt`,
pointed to by `LWCAM_QC_SERVER_CONFIG` in `START_QC_SERVER.bat`. That folder is
private to SYSTEM and Administrators, because the console saves by writing a temp
file beside the real one, and a new file takes its folder's permissions.

Any Python 3.14 that satisfies `requirements.txt` (fastapi, uvicorn, sqlalchemy,
psycopg, Pillow, numpy, cv2) runs the suite and the server. Nothing in the code
depends on which interpreter runs it.

**Use `run_server.py`. Never `python -m app.main` from this folder when the
interpreter is the shipped embeddable runtime.** Its `python314._pth` hardcodes
the INSTALLED backend onto `sys.path`, ignores `PYTHONPATH`, and does not add
the working directory. So `-m app.main` silently starts the installed engine,
which has no `__main__` block and exits without printing anything; it looks
exactly like the command doing nothing. `run_server.py` puts this directory
first and prints which tree it serves.

The same trap catches ad-hoc scripts: each needs `sys.path.insert(0, ".")` and
is worth a `print(module.__file__)` before its result is believed.
`unittest discover -s tests -t .` is safe: it inserts the target itself.

Frontend:

```bash
cd frontend && npm run build     # vue-tsc --noEmit && vite build
```

The backend serves `frontend/dist` through `_SpaStaticFiles` in `app/main.py`,
whose mount must stay registered **last**. Two things it gets right that are
easy to undo:

- `StaticFiles(html=True)` does **not** do SPA fallback. It serves `index.html`
  for a *directory*, and **raises** `HTTPException(404)` for an unknown path
  rather than returning a 404 response. The fallback is therefore a
  `try/except`, not a status-code check (a status-code check looks correct and
  never fires).
- Vite chunks are content-hashed, so rebuilding `dist/` while somebody has the
  page open breaks their lazy-loaded routes with no visible error.
  `router.onError` in `src/router/index.ts` reloads once on a stale-chunk
  failure. A report of "clicking Settings did nothing" was this, not the route.

## Settings: `config.txt`

Plain `key = value` text beside `backend/` (or wherever `LWCAM_QC_SERVER_CONFIG`
points), hand-editable, rewritten whole by the console on save (values survive;
hand-written comments do not). Read by `app/core/server_settings.py`, whose
`SETTINGS_BY_KEY` is the complete list; anything not in it is a code default.
The file's own header (and `config.example.txt`) documents every key.

Server keys, read once at start (restart after changing): `dbHost`, `dbPort`,
`dbName`, `dbUser`, `dbPassword`, `dbUseSsl`, `jwtSecret`, `jwtExpireMinutes`,
`bindHost` (`0.0.0.0` = LAN), `port`, `tlsCertFile`, `tlsKeyFile`. AI
(`aiReviewEnabled`, `aiPreanalysisEnabled`, `openrouterApiKey`,
`openrouterExtractModel`, `openrouterCompareModel`) is edited live from
Admin → Settings; secrets are write-only there (never returned; blank keeps the
saved one). Also `exportWorkerCount` (default 0 = auto: logical CPUs - 1, max 61;
each worker is a process holding a full-size decode, so lower it on small-RAM
PCs) and `exportTempRetentionHours`. A value containing a line break or control
character is refused, because it would plant a key of the sender's choosing.

Upload's keys (`uploadEnabled`, `uploadS3*`, `uploadDoneRoot`,
`uploadSummaryRoot`) are not in this file: they live in the Upload service's own
`upload_config.json`. `SETTINGS_BY_KEY` does not map them, so a `config.txt` that
still has them keeps loading, and the next console save drops them.

Folder keys: `qcInputRoot` is LWIP's output and `exportWorkRoot` is the export
scratch. (Older files used `qcImagesRoot` for the first and `qcInputRoot` for the
second. A file carrying a `qcImagesRoot` line is read with the old meanings
through `LEGACY_SETTINGS_BY_KEY`, and the next console save rewrites it with the
new keys. Internal names `qc_images_root`, `export_temp_dir` and the API fields
`qcImagesRoot`, `exportTempDir` did not change.)

| Key | Meaning |
| --- | --- |
| `qcInputRoot` | LWIP's output (2.Batches), where QC finds captured folders. **Empty on a single PC**: the engine then uses the path LWCAM recorded in the DB. Set it on a split site (e.g. `\\capture-pc\2.Batches`); each folder's own date and name are kept, only the prefix is replaced (`paths.relocate_under`, anchored on the `YYYYMMDD` segment so `thumbs` nests correctly). Validated **writable**, not just readable: approval writes `qc_ops.json` into each capture folder. Never created by validation, so a typo in a share name is reported. |
| `exportWorkRoot` | Export **scratch** (`<root>\.lwcam-export\…`, cleared after `exportTempRetentionHours`). Must not be, contain, or sit inside `qcInputRoot` or `qcOutputRoot` (validation check `exportTempDirSeparate`). On a split site keep it LOCAL. |
| `qcOutputRoot` | Where the finished package is published. |
| `exportZipOutput` | true = a `.zip`, false = a folder. |
| `exportTiffOutput` | true = lossless TIFF. false re-encodes edited pages as q100 4:4:4 JPEG and byte-copies untouched ones. |
| `luminanceEnabled` | Allows luminance correction in review, the one tool that bakes pixels. Off by default. |
| `exportAutoEnabled` | true = the server sweeps approved folders out by itself. false leaves every PASS folder waiting for an admin. **A missing line reads TRUE**, not false (see the decision below). |
| `previewCacheMaxMb` | Soft cap on the rendered-preview cache; `previews.py` sweeps oldest-first past it. |

A malformed boolean or integer **raises** rather than defaulting. This file
decides whether deliveries are lossless, so a typo has to be reported.

**Every folder key accepts a UNC path** (`\\server\share\…`); `fs_path` turns it
into `\\?\UNC\…` at the system-call boundary. `test_every_path_can_be_a_network_path`
covers it, and the whole suite passes with `TMP` on a UNC path. **A mapped drive
letter does not work**: the installed server runs as SYSTEM, which never sees a
user's mapped drives, so validation refuses a drive letter the server cannot see
and says to use the UNC path. SYSTEM reaches a share as the PC's computer account
(`DOMAIN\PC$`), so the share must grant that account. On a workgroup with no
domain that account gets "Access is denied". The fix is a saved network login
(`app/core/netlogin.py`, Settings → "Network folder logins"): one list per PC in
`%ProgramData%\LWCAM\network-logins\`, shared with LWIP and Upload on that PC,
because Windows gives all SYSTEM services on a PC one logon session and allows it
one account per remote PC (a second is error 1219). `check_directory` signs in
before probing, and a background keeper signs in again every 120 s. The module is
byte-identical in LWIP and Upload; `test_netlogin_copies_match` fails when they
drift. On Python 3.13, `Path.is_dir()` RAISES for WinError 5/1326 where 3.14
answers False; keep the guard (`directory_state`), because that was a 500 on
Validate paths.

## Tests

```bash
cd backend
python -m unittest discover -s tests -t .
```

Counts and known failures are in `docs/TESTING.md`. Any failure is a regression.
`tests/test_setup_qc_db.py` creates and drops uniquely named scratch databases
(`lwcam_setup_test_<uuid>`) on a local PostgreSQL, using the DB login in
`config.txt`. It never touches the real database, and it skips without a
reachable server.

Conventions, because they are not the usual ones: `unittest.TestCase` classes,
collected by pytest but **runnable without it** (pytest is in neither
`requirements.txt` nor the offline wheels). No `conftest.py`, no fixtures, no
`TestClient`. Settings are mutated with `patch.object`. A test written after
`if __name__ == "__main__":` is orphaned and never collected: check the count
rises.

## Decisions worth not re-litigating

**QC keeps the pages it adds through a capture rework**
(`services/qc_kept_pages.py`; the root `AGENTS.md` has the full account). LWIP
rebuilds the folder and wipes QC's inserted/replaced pages and `qc_ops.json`; QC
snapshots them under `<qc_work_dir>\qc_kept\<folder id>\` after every commit and
restores them at claim time when LWIP's publish marker changed or the folder is
visibly missing them. Edits survive for pages that were not recaptured.
`reject_task` refuses a kept page (400); the store is dropped on split only.

**Separation API:** page 1 is an implicit start; `PUT .../separation-markers`
takes only the EXTRA start ids (an old client sending page 1 is ignored, `[]`
clears), and the split needs at least one extra.

**One live sign-in per account, the FIRST wins.** A second sign-in gets 409 while
the first is in use; "in use" = a request in the last 3 minutes, and the console
checks in every minute (`main.ts`), so a browser closed without signing out frees
the account in 3 minutes rather than when its 8-hour token expires. Sign out
(`POST /auth/logout`) frees it at once. In memory (`security.py`), one process;
the LWIP and Upload consoles' `SessionStore.create` do the same.

**Geometry is DATA until export.** LWIP crops in coded JPEG blocks and only
*measures* tilt; the engine layers LWIP baseline + committed QC ops
(`qc_ops.json`) + the reviewer's draft, and replays the chain ONCE at export.
Approval writes data, not pixels. The replay lives in `services/geometry_replay.py`
(shared byte-for-byte with LWIP; `geometry_ops.py` is an alias) and knows a fourth
op, `matfill`, which paints rotation void outside the photo with surrounding
background. Full account in the root `AGENTS.md`.

**The delivery TIFF carries predictor 2** (`export.py`, `TIFF_PREDICTOR_HORIZONTAL`).
Horizontal differencing: deflate compresses the difference between neighbouring
pixels instead of the pixels. It is reversible: 193.4 MB to 137.6 MB (-29%) over
one real folder with every pixel identical, at about 40% more encode time. It
rides in the **provenance `ImageFileDirectory`**, because Pillow accepts one
`tiffinfo` and a second dict silently drops the camera tags.

**Separation copies LWIP's manifest into every child.** The deskew/crop baseline
is `.deskew_crop_manifest.json`, which stays in the retained parent; without a
copy the children lose deskew/crop in preview, thumbnails and export.
`SeparationFileTransaction` writes `child_manifest(...)` (files[] and
thumbnails.files narrowed to that child's pages; none for a child of only
QC-added pages) into each temp dir, so it is published by the same rename and
removed by `rollback()`. LWIP's own thumbnails are already baked, so moved
thumbnails stay right; one LWIP never made is rendered with the baseline.
`backend\repair_split_manifests.py` repairs children split before this existed
(dry run; `--yes` writes). Tests: `tests/test_split_manifest.py`.

**Separation splits `qc_ops.json` per child.** `commit_current_draft` once
captured the parent's path, moved the images into children, then wrote the ops
file to the now-deleted parent, so every edit on a separated folder was lost.

**Rejecting a separated child stays BLOCKED** (`separated_from_folder_id`,
migration 005), because rework resolves paths back through `1.Images`, where a
child never existed. Resolving the rework through `separated_from_folder_id` to
the originating folder was offered and declined: the block is correct, cheap and
understood, and a path-rewriting rework is none of those. Treat it as intended
behaviour.

**After finishing a task the console lands on Available** when nothing is held
and nothing is waiting. It probes with a COUNT rather than a speculative
`claimNext()`, so declining never leaves a folder locked to somebody who said no.

**Approved folders export THEMSELVES, on a sweep.** `ExportAutoScheduler`
(`export.py`) starts a run every `export_auto_interval_seconds` (30) for every
eligible folder. It is not a call from the approve handler, for two structural
reasons: approve is done by a QcUser and every export route is AdminUser-gated,
so the client cannot start one on the operator's behalf; and
`ExportCoordinator.start` raises `taskAlreadyRunning` while a run is alive, so
firing on approve would lose the second of two near-simultaneous approvals,
silently leaving a PASS folder unexported.

**`exportAutoEnabled` turns that sweep off**, from Admin → Settings, for Admin and
SuperAdmin alike. It joins the keys `config.txt` owns and `PUT /settings` applies
live: the sweep reads `settings.export_auto_enabled` through its `enabled`
callback on every tick, so a save lands on the next pass with no restart.
Turning it off confirms first, like lossless TIFF, because off is the direction
that changes what the station produces. A key MISSING from `config.txt` must
never read as False: a file written before the key existed has no such line, and
reporting False would quietly stop every upgraded station exporting.
`test_server_settings.py` holds that.

**`PeriodicSweep` must re-read its switch on every tick.** It once read `enabled`
only in `start()`, so a save after boot did nothing, and a sweep that booted
disabled had no thread for a later save to re-enable. The gate now lives in
`_run`; the thread always runs and idles, and `is_running()` means alive AND
switched on (kept apart from the `_thread_alive()` start guard, so the console's
AI-scanner indicator reports the switch rather than the thread).
`tests/test_sweep_switch.py` holds it. The lesson: a switch that is only read at
startup passes every unit test that starts a fresh object; flip it on a running
engine.

**A field the project DISABLES is not required.** A template field with
`"enabled": false` is dropped by `metadata_template`, and
`validate_metadata_for_approval` iterates the same list. The desk's
`editableTemplateFields` must not fall back to a hardcoded mandatory list for a
field the project removed; the fallback applies only to a folder whose project
carries no template at all. `tests/test_disabled_template_field.py` holds the
backend half of that contract.

**Preview and exported TIFF resample at different SIZES, not with different
filters.** The preview replays ops on a 1600 px frame (Pillow LANCZOS after a JPEG
`draft()` decode); export replays the same ops on the full-size frame (OpenCV
LANCZOS4). Both call the same `replay_pending_ops`, so geometry is identical and
the preview is honest about framing, not about pixels. That gap is the reason an
edit click feels instant. A reviewer who must judge sharpness needs a 1:1
viewport render, not a different filter.

**A migration is not applied by writing it.** Migration 004 (`qc_reviewed_by`)
was written and not run, and every tab answered "Internal Server Error" because
the model declared a column the database lacked. **And a migration nobody lists
is never applied either**: `scripts/setup_qc_db.py` once named 001-003 by hand.
It now applies every `database/migrations/*.sql` in name order, on fresh and
existing databases (each migration is idempotent; the unified pg_dump loads only
into an empty database), records each in `schema_migrations`, and verifies the
expected columns and roles. Migrations 006-008 run in one transaction with a 30 s
lock timeout.

**Schema upgrades are `LWCamDatabaseSetup`'s job.** It is the only installer that
runs `setup_qc_db.py` (`--server-config`). `QCPlatformSetup` and LWCam Admin's
Station Setup do not provision or upgrade the database. A QC release that adds a
migration therefore needs a newer `LWCamDatabaseSetup` run on the database PC
before the new columns exist, not a QC server reinstall.

**Schema level 8.** `REQUIRED_SCHEMA = 8` (`services/schema_check.py`); the other
parts need 7. Migration `008_hardening.sql` adds
`public.lwcam_next_export_number(bigint)` (SECURITY DEFINER, with a pinned
`pg_catalog` search path, EXECUTE for `lwcam_qc` only) and takes CREATE on
`public` away from `lwcam_qc`. Export keeps its advisory lock and calls the
function instead of CREATE SEQUENCE + nextval. An old database answers "The
database is older than this program (needs level 8, has N). Run
LWCamDatabaseSetup on the database PC." on the status page and blocks work; it
re-checks by itself every minute.

## System status (multi-PC)

The QC server is assumed to be a different PC from the database, LWIP, Upload and
the capture PCs (LAN or Tailscale, differing clocks, a slow or absent peer).
Nothing waits on a remote host without a timeout; everything queues and retries.
`services/heartbeat.py` and the status page: the parts that must exist are `qc`,
`qc-export`, `lwip`, `upload`, `backup` (a missing row is a red "never
reported"); `capture` rows are informational (grey when off, red only for held or
old unsent records or an error); ages are computed in SQL from the DB's `now()`;
rows silent for over 7 days are hidden unless asked for;
`DELETE /api/admin/system-status/{part}/{host}` ("Forget this PC", Admin) needs
the DELETE grant migration 008 gives `lwcam_qc`.

The console is https only (`core/tls.py` is byte-identical in QC, LWIP and
Upload; edit LWIP's, copy the others). `setup_qc_db.py --open-lan` also sets
`tcp_keepalives_idle=60`, `_interval=10`, `_count=6` (`ALTER SYSTEM`, reloadable),
so a dead client PC's session, and the advisory locks it holds (an export lock),
is dropped in about 2 minutes instead of hours. See `installer/README.md`.

## Test data without a camera

```bash
python scripts\reset_test_folder.py <folder_id>
```

Puts an approved/exported folder back to PENDING by rebuilding it from `1.Images`.
The non-obvious part it encodes: **LWIP only UPDATEs `capture_folders`**; the row
is created by LWCAM's capture app. Delete the row, re-run LWIP, and the images
land on disk with no row to point at them and no error anywhere. The script
rebuilds the row from LWCAM's local SQLite
(`%USERPROFILE%\LWCAM_DBs\lwcam_stats_<device>.db`), which still holds every
field the operator keyed, and uses `transferred_name` for `image_name` because QC
resolves each page as `folder_path / image_name`.

Without `1.Images` or an LWIP install, use `--skip-lwip` (keeps the batch output
as it stands and rebuilds the rows alone) and `--batch-dir` (names that folder
when the DB still records the old tree). Put the pages there by hand; the
script's closing `every row resolves to a file` line says the folder is usable:

```bash
python scripts\reset_test_folder.py <folder_id> --skip-lwip --yes \
    --batch-dir "C:\LWCamDev\2.Batches\20260910\<folder name>"
```

## Open items

- The Revert and Approve buttons of client rework have been exercised through
  the API only; the bucket half (the same Group ID replacing the package in S3)
  is untested.
- Upload has no status screen in this console (its own console on 8091 has one;
  upload failures also appear on the QC System status page).
- A later merge from the All-In-One edition that touches a file this edition
  deleted raises a modify/delete conflict. The answer is always: stay deleted.
