# LWCam QC Platform — the standalone QC console

The QC engine as a **server**, not a sidecar: a FastAPI backend and a Vue 3
frontend that several reviewers reach over the LAN with a browser. It is the
`qc-platform` branch's reason to exist.

`AGENTS.md` at the repository root (one level up) is the workspace guide and stays authoritative
for build/test/ship across all three apps. This file covers this app, and is
the place to start after a break.

## What it is, and what it deliberately is not

The design point the whole branch turns on: **QC is standalone. It speaks to
LWCam only through the database.** No shared config file, no IPC, no assumption
that capture and QC are the same PC. It therefore owns its own settings file
(`config.txt`, below) rather than reading Station Setup's.

| In | Out |
| --- | --- |
| Review, approve, reject, separation, client rework | Capture, LWIP — those stay with LWCam |
| Export to TIFF/JPEG package, the Exports screen | Upload to S3 — moved to the standalone LWCam Upload service |
| Admin: dashboards, QC paths, zip/TIFF toggles, AI settings | |
| **SuperAdmin only**: user management, project creation | A QC admin must never reach these |

**Upload moved out** (2026-09-25) to `LWCam_Upload\`, a standalone service
shipped as its own installer (`LWCamUploadSetup.exe`). It watches this
server's `qcOutputRoot` on its own schedule and has its own settings and
console — this server no longer sweeps, retries or reports upload status; a
republished (client-rework) package is picked up because LWCam Upload
fingerprints each package's files, not because this server clears anything.

PostgreSQL (local, central or cloud). **No Docker** — it runs on the shipped
embeddable Python like the rest of the suite.

## Running it

```bash
cd backend
C:\Python314\python.exe run_server.py    # port from config.txt, else 8080
```

**Everything comes from `config.txt`** (below) since 2026-09-23 — the server no
longer reads LWCam Admin's `lwcam_node_config.json`, so `LWCAM_NODE_CONFIG` does
nothing here. The file needs at least `dbHost`/`dbName`/`dbUser`/`dbPassword`;
without `jwtSecret` the development secret is used, which the server refuses on
any non-loopback `bindHost`. On this station the gitignored `config.txt` holds
the DB login copied from the node config.

An installed server (QCPlatformSetup.exe) keeps it at
`<install>\config\config.txt`, pointed to by `LWCAM_QC_SERVER_CONFIG` in
`START_QC_SERVER.bat`; that folder is private to SYSTEM and Administrators,
because the console saves by writing a temp file beside it and a new file takes
its folder's permissions.

**The interpreter changed on 2026-09-21.** The installed LW Suite was removed
from this station, and with it `C:\Program Files\LW Suite\QC\runtime\python`,
which every command in this file used to name. `C:\Python314` already satisfies
`requirements.txt` — fastapi, uvicorn, sqlalchemy, psycopg, Pillow, numpy and
cv2 are all importable there — and the whole suite passes on it. A station that
still has LW Suite installed can keep using the shipped runtime; nothing in the
code depends on which of the two runs it.

**Use `run_server.py`. Never `python -m app.main` from this folder.** The
shipped runtime's `python313._pth` hardcodes the INSTALLED backend
(`C:\Program Files\LW Suite\QC\backend`) onto `sys.path`, ignores `PYTHONPATH`,
and does not add the working directory — so `-m app.main` silently starts the
installed engine, which has no `__main__` block and exits without printing
anything. It looks exactly like the command doing nothing. `run_server.py`
exists only to put this directory first, and prints which tree it serves.

The same trap catches ad-hoc scripts: any of them needs
`sys.path.insert(0, ".")` explicitly, and is worth a `print(module.__file__)`
before its result is believed. `unittest discover -s tests -t .` is safe — it
inserts the target itself.

Frontend:

```bash
cd frontend && npm run build     # vue-tsc --noEmit && vite build
```

The backend serves `frontend/dist` through `_SpaStaticFiles` in `app/main.py`,
whose mount must stay registered **last**. Two things it gets right that are
easy to undo:

- `StaticFiles(html=True)` does **not** do SPA fallback — it serves
  `index.html` for a *directory*, and **raises** `HTTPException(404)` for an
  unknown path rather than returning a 404 response. The fallback therefore has
  to be a `try/except`, not a status-code check; a status-code check looks
  correct and never fires.
- Vite chunks are content-hashed, so rebuilding `dist/` while somebody has the
  page open breaks their lazy-loaded routes with no visible error. `router.onError`
  in `src/router/index.ts` reloads once on a stale-chunk failure. A report of
  "clicking Settings did nothing" was this, not the route.

## Settings: `config.txt` at the platform root

Plain `key = value` text beside `backend/` (or wherever
`LWCAM_QC_SERVER_CONFIG` points), hand-editable in Notepad, rewritten whole by
the console on save (values survive; hand-written comments do not). Read by
`app/core/server_settings.py`, whose `SETTINGS_BY_KEY` is the complete list —
anything not in it is a code default. The file's own header documents every key.

Server keys, read once at start (restart after changing): `dbHost`, `dbPort`,
`dbName`, `dbUser`, `dbPassword`, `dbUseSsl`, `jwtSecret`, `jwtExpireMinutes`,
`bindHost` (`0.0.0.0` = LAN), `port`. AI (`aiReviewEnabled`,
`aiPreanalysisEnabled`, `openrouterApiKey`, `openrouterExtractModel`,
`openrouterCompareModel`) is edited live from Admin → Settings; secrets are
write-only there (never returned; blank keeps the saved one). Also
`exportWorkerCount` and `exportTempRetentionHours`. `captureImageHostPath`/
`ContainerPath` are retired in favour of `qcInputRoot`. A value containing a
line break or control character is refused — it would otherwise plant a key
of the sender's choosing.

**Upload's keys are gone from this file** (2026-09-25): `uploadEnabled`,
`uploadS3Path`, `uploadS3Region`, `uploadS3AccessKey`, `uploadS3SecretKey`,
`uploadDoneRoot` and `uploadSummaryRoot` moved to the standalone LWCam Upload
service's own `upload_config.json`. `SETTINGS_BY_KEY` no longer maps them, so
they are unrecognised lines like any other stale key — a `config.txt` that
still has them keeps loading, and the next console save drops them (the
writer only ever emits keys it knows about).

**The folder keys were renamed on 2026-09-24**, because "QC input root" meant
the export scratch folder and everyone read it as the image source. Now
`qcInputRoot` = LWIP's output (was `qcImagesRoot`) and `exportWorkRoot` = the
export scratch (was `qcInputRoot`). Internal names (`qc_images_root`,
`export_temp_dir`) and the API fields (`qcImagesRoot`, `exportTempDir`) did not
change. A file carrying a `qcImagesRoot` line is the old layout and is read with
the old meanings (`LEGACY_SETTINGS_BY_KEY`) — every writer of that layout wrote
that line, blank or not — and the next console save rewrites it with the new keys.

| Key | Meaning |
| --- | --- |
| `qcInputRoot` | LWIP's output (2.Batches) — where QC finds captured folders. **Empty on a single PC** — the engine then uses the path LWCAM recorded in the DB. Set it on a split site (e.g. `\\capture-pc\2.Batches`) and each folder's own date and name are kept, only the prefix is replaced (`paths.relocate_under`, anchored on the `YYYYMMDD` segment so `thumbs` nests correctly). Validated **writable**, not just readable: approval writes `qc_ops.json` into each capture folder. Never created by validation — a typo in a share name is reported. |
| `exportWorkRoot` | Export **scratch** (`<root>\.lwcam-export\…`, cleared after `exportTempRetentionHours`). Must not be, contain, or sit inside `qcInputRoot` or `qcOutputRoot` (validation check `exportTempDirSeparate`). On a split site keep it LOCAL, or every export writes ~10× TIFF scratch across the network. |
| `qcOutputRoot` | Where the finished package is published. |

**Every folder key accepts a UNC path** (`\\server\share\…`); `fs_path` turns it
into `\\?\UNC\…` at the system-call boundary. Proven on 2026-09-24 by running the
whole suite with `TMP` on `\\localhost\C$\…` (202 pass), plus
`test_every_path_can_be_a_network_path`. **A mapped drive letter does not work**:
the installed server runs as SYSTEM, which never sees a user's mapped drives, so
validation refuses a drive letter the server cannot see and says to use the UNC
path. SYSTEM reaches a share as the PC's computer account (`DOMAIN\PC$`), so the
share must grant that account — on a workgroup with no domain it gets no access
("Access is denied"). **Since 2026-09-28 the fix is a saved network login**
(`app/core/netlogin.py`, Settings → "Network folder logins"): one list per PC
in `%ProgramData%\LWCAM\network-logins\`, shared with LWIP and Upload on the
same PC, because Windows gives all SYSTEM services on a PC one logon session
and allows it one account per remote PC (a second is error 1219).
`check_directory` signs in with it before probing, and a background keeper
signs in again every 120 s. The module is byte-identical in LWIP and Upload;
`test_netlogin_copies_match` fails when they drift. Also on Python 3.13 (the
shipped runtime) `Path.is_dir()` RAISES for WinError 5/1326 where 3.14
answers False — `directory_state` exists because that was a 500 on Validate
paths.
| `exportZipOutput` | true = a `.zip`, false = a folder. |
| `exportTiffOutput` | true = lossless TIFF. false re-encodes edited pages as q100 4:4:4 JPEG and byte-copies untouched ones. |
| `luminanceEnabled` | Allows luminance correction in review — the one tool that bakes pixels. Off by default. |
| `exportAutoEnabled` | true = the server sweeps approved folders out by itself. false leaves every PASS folder waiting for an admin. **A missing line reads TRUE**, not false — see the decision below. |
| `previewCacheMaxMb` | Soft cap on the rendered-preview cache; `previews.py` sweeps oldest-first past it. |

A malformed boolean or integer **raises** rather than defaulting: this file
decides whether deliveries are lossless, so a typo has to be reported.

## Tests

```bash
cd backend
C:\Python314\python.exe -m unittest discover -s tests -t .
```

**202 tests, 0 failures** on this branch (master's copy of the same suite is
110 — this branch adds the separation, settings, cache, rate-limit,
attribution, user-role-filter, auto-export-toggle, disabled-template-field,
sweep-switch, admin-settings and setup_qc_db suites). Any failure is a
regression. `tests/test_setup_qc_db.py` creates and drops uniquely named
scratch databases (`lwcam_setup_test_<uuid>`) on the local PostgreSQL, using
the DB login in `config.txt`; it never touches `lwcam`, and skips without a
reachable server.

Conventions, because they are not the usual ones: `unittest.TestCase` classes,
collected by pytest but **runnable without it** — pytest is in neither
`requirements.txt` nor the offline wheels. No `conftest.py`, no fixtures, no
`TestClient`. Settings are mutated with `patch.object`. A test written after
`if __name__ == "__main__":` is orphaned and never collected — check the count
rises.

## Decisions worth not re-litigating

**One live sign-in per account, the FIRST wins** (2026-09-29, asked for after a
newest-wins version was built the same day). A second sign-in gets 409 while the
first is in use; "in use" = a request in the last 3 minutes, and the console
checks in every minute (`main.ts`), so a browser closed without signing out
frees the account in 3 minutes rather than when its 8-hour token expires. Sign
out (`POST /auth/logout`) frees it at once. In memory (`security.py`), one
process; the LWIP and Upload consoles' `SessionStore.create` do the same.

**Geometry is DATA until export.** LWIP crops in coded JPEG blocks and only
*measures* tilt; the engine layers LWIP baseline + committed QC ops
(`qc_ops.json`) + the reviewer's draft, and replays the chain ONCE at export.
Approval writes data, not pixels. Full account in the root `AGENTS.md`.

**The delivery TIFF carries predictor 2** (`export.py`, `TIFF_PREDICTOR_HORIZONTAL`).
Horizontal differencing: deflate compresses the difference between neighbouring
pixels instead of the pixels. Reversible — measured 193.4 MB → 137.6 MB (−29%)
over one real folder with every pixel identical, at ~40% more encode time. It
rides in the **provenance `ImageFileDirectory`** because Pillow accepts one
`tiffinfo` and a second dict silently drops the camera tags.

**Separation splits `qc_ops.json` per child.** `commit_current_draft` used to
capture the parent's path, move the images into children, then write the ops
file to the now-deleted parent — every edit on a separated folder was lost.
Rejection of a separated child is blocked (`separated_from_folder_id`,
migration 005) because rework resolves paths back through `1.Images`, where a
child never existed.

**After finishing a task the console lands on Available** when nothing is held
and nothing is waiting, matching the Flutter desk. It probes with a COUNT
rather than a speculative `claimNext()`, so declining never leaves a folder
locked to somebody who said no.

**Rejecting a separated child stays BLOCKED** (decided 2026-09-21, after the
alternative was offered and declined). Resolving the rework through
`separated_from_folder_id` back to the originating folder is the richer fix and
was not taken: the block is correct, cheap and understood, and a path-rewriting
rework is none of those. Treat it as intended behaviour, not a defect awaiting
a fix.

**Approved folders export THEMSELVES, on a sweep.** `ExportAutoScheduler`
(`export.py`) starts a run every `export_auto_interval_seconds` (30) for every
eligible folder. Not a call from the approve handler, for two structural
reasons: approve is done by a QcUser and every export route is AdminUser-gated,
so the client cannot start one on the operator's behalf; and
`ExportCoordinator.start` raises `taskAlreadyRunning` while a run is alive, so
firing on approve would lose the second of two near-simultaneous approvals —
silently, leaving a PASS folder unexported with nothing recording that it should
have been. This is not new to the web console: the Flutter Exports screen only
ever WATCHED it happen (`qc_exports_controller.dart:9`).

**`exportAutoEnabled` turns that sweep off** (2026-09-21), from Admin →
Settings, for Admin and SuperAdmin alike. It joins the keys `config.txt` owns
and `PUT /settings` applies live — the sweep reads `settings.export_auto_enabled`
through its `enabled` callback on every tick, so a save lands on the next pass
with no restart. Turning it off confirms first, like lossless TIFF and for the
same reason: off is the direction that changes what the station produces. A key
MISSING from `config.txt` must never read as False — a file written before this
existed has no such line, and reporting False would override Settings' True
default and quietly stop every upgraded station exporting. `test_server_settings.py`
holds that.

**That "on every tick" was not true until 2026-09-22, and no test caught it.**
`PeriodicSweep` read `enabled` only in `start()`; `_run` then ticked until
`stop()`. So the switch was restart-only in both directions — a save after boot
did nothing, and a sweep that booted disabled had no thread for a later save to
re-enable. Of the three sweeps only AI pre-analysis escaped, by checking its own
switch again at the top of `scan_once`; **export and upload both did real work
while switched off.** Proven on the station, which is the only thing that could
have proven it: folder 14 approved 13:56:09 with the switch false in
`config.txt`, false in the singleton and rendered off on the screen, exported
13:56:48 as `…000013`. The gate now lives in `_run`, the thread always runs and
idles, and `is_running()` means alive AND switched on — kept apart from the
`_thread_alive()` start guard so the console's AI-scanner indicator still
reports the switch rather than the thread. `tests/test_sweep_switch.py` holds
it; 4 of its 5 tests fail against the old loop.

The lesson worth keeping: **a switch that is only read at startup passes every
unit test that starts a fresh object.** Nothing short of flipping it on a
running engine finds this, which is why it survived to a station test.

**A migration is not applied by writing it.** `004` (`qc_reviewed_by`) was
written and not run, and every tab answered "Internal Server Error" because the
model declared a column the database lacked. Apply it, then check.

**And a migration nobody lists is never applied either** (fixed 2026-09-23).
`scripts/setup_qc_db.py` named 001-003 by hand, so 004 and 005 reached no
station: every fresh install lacked `qc_reviewed_by` and
`separated_from_folder_id` and 500'd on every QC tab. It now applies every
`database/migrations/*.sql` in name order, on fresh and existing databases
(each migration is idempotent; the unified pg_dump still loads only into an
empty database), and verifies those columns and the `qc` role.

**Schema upgrades are `LWCamDatabaseSetup`'s job now** (2026-09-25, the
`lwip-standalone` branch): it is the only installer that runs this script
(`--server-config`), and neither `QCPlatformSetup` nor LWCam Admin's Station
Setup provisions or upgrades the database any more — Station Setup's Save only
tests the connection. A QC release that adds a migration therefore needs a
newer `LWCamDatabaseSetup` run on the database PC before the new columns exist,
not a QC server reinstall. `--config <node json>` still works for anything
else that ever needs it, but nothing installs that caller.

## Test data without a camera

```bash
C:\Python314\python.exe scripts\reset_test_folder.py <folder_id>
```

Puts an approved/exported folder back to PENDING by rebuilding it from
`1.Images`. The non-obvious part it encodes: **LWIP only UPDATEs
`capture_folders`** — the row is created by LWCAM's capture app. Delete the row,
re-run LWIP, and the images land on disk with no row to point at them and no
error anywhere. The script rebuilds the row from LWCAM's local SQLite
(`%USERPROFILE%\LWCAM_DBs\lwcam_stats_<device>.db`), which still holds every
field the operator keyed, and uses `transferred_name` for `image_name` because
QC resolves each page as `folder_path / image_name`.

**On this station both `1.Images` and the LWIP install are gone** with the LW
Suite uninstall, so the rebuild-from-capture path cannot run here. Two flags
added 2026-09-22 cover that: `--skip-lwip` keeps the batch output exactly as it
stands and rebuilds the rows alone, and `--batch-dir` names that folder when the
DB still records the old tree. The pages then have to be put there by hand —
the untouched LWIP output for folder 12 is in `Desktop\LWCam Test Data Backup
2026-09-21` — and the script's closing `every row resolves to a file` line is
what says the folder is usable:

```bash
C:\Python314\python.exe scripts\reset_test_folder.py 12 --skip-lwip --yes \
    --batch-dir "C:\LWCamTest\2.Batches\20260910\9145 1334-1350 file no. 1334"
```

## State of play (2026-09-23)

**The database now holds only folder 15** — the same capture again, PASS and
exported as group `M92P-…000014` (`3.Export` also holds `…000012` and
`…000013` from the resets in between). The queue is empty.

**Client rework ran end to end on 2026-09-23, driven through the API** rather
than the console's buttons (tokens minted in-process with
`create_access_token`, since no password is known on this station). Clement
reverted folder 15: PENDING, `client_rework` true, `is_exported` false, Group
ID kept, claimed by him. A 90° rotate on page 1 was approved, and the sweep
republished `…000014` **in place** 28 s later — no `…000015`; page 1 now
3568×5738, pages 2–4 byte-identical to before, `GroupMetadataImage.csv`'s
Rework `FALSE` → `TRUE`, the four source JPEGs unchanged, `qc_ops.json` holding
the rotate. That leaves page 1 of the delivered package rotated; the package
and pages from before the test are in
`C:\LWCamTest\scratch\before-client-rework-test-20260923`. Not covered: the
Revert/Approve buttons themselves, and the bucket half (upload is off here).

The folder-12/13 history below is kept for how the reset was done.

**Folder 13 replaced folder 12** — the same capture, reset on 2026-09-22 with
the two flags above after its pristine four pages were copied back from the
backup, then reviewed, approved and exported the same day. Folder 12's reviewed
state — the three surviving originals, the two pages inserted during review, and
`qc_ops.json` — was moved aside rather than deleted, to
`C:\LWCamTest\scratch\reviewed-folder12-20260922`. Its row is gone;
`3.Export`'s `…000011` package is its output and stays. **The queue is empty
again**, so testing anything on the desk means another reset.

Its `folder_path` now reads `C:\LWCamTest\2.Batches\...`. **Every row the
uninstall left behind still pointed into `C:\Program Files\LW Suite`** — the
reset is what repointed this one, and `config.txt`'s `qcImagesRoot` is what
carried the console over the gap before that.

Working and exercised on this station: login, the review desk (icon toolbar,
arrow-key paging, selection, collapsible AI and rejection panels), draft save,
approve with unsaved metadata flushed first, separation, client rework, admin
settings writing `config.txt`, export with predictor 2, and the Completed list.

**A full approval ran end to end on 2026-09-21** (folder 12, by Clement):
rotate, crop, deskew, delete and insert across five pages, all committed to
`qc_ops.json` as data with the source JPEGs untouched; the desk landed on
**Available with no dialog** afterwards, which is the empty-queue case that
behaviour exists for; and the sweep exported it unasked within the minute as
`M92P-…000011` — 5 TIFFs, predictor 2, the 90° rotation turned into pixels for
the first time at export.

**Both remaining screen items were exercised on 2026-09-22, and both pass.**

**Mapped metadata.** The guess that the project template might carry no mapped
field was wrong: "South Africa Military Project 2024" maps **Record Type, Start
Date and End Date** from `title`, storing them as `mode: "mapped"` with a stale
`inputType` that `metadata_template` normalises to `input: "mapped"`. Folder
13's title `WWII Medical Files` derived `Military Medical Records` / `1939` /
`1945`; all three rendered `readOnly` on the desk, and all three reached
`GroupMetadataImage.csv` in the delivered package without anyone keying them.

**`exportAutoEnabled`.** The console rewrote `config.txt` whole — the
hand-written 2026-09-21 comments went, the values stayed, and the file gained
the `exportAutoEnabled` line it had never carried. Saving is
`paths/validate` then `PUT /api/admin/settings`, and the off direction confirms
first. What this run did **not** prove is the live half: folder 13 was PENDING
while the switch moved, so the sweep had nothing to skip. Only
`test_server_settings.py` covers that.

**The export that closed both** (folder 13, group `M92P-…000012`): approved with
no Cover tag value at all, swept out unasked, 4 TIFFs at predictor 2 carrying
`Xiaomi / Xiaomi 15 Ultra` and no GPS.

**A field the project DISABLES is not required — fixed 2026-09-22** (`b1bcdd8`).
The desk showed `* Cover tag` as a mandatory free-text box and Approve refused
with "This field is required: Cover tag", sending no request: that project sets
`"enabled": false` on Cover Tag, so `metadata_template` drops it and
`validate_metadata_for_approval`, iterating the same list, never asked for it.
`editableTemplateFields` mapped a hardcoded key list and fell back per key,
and `fallbackMandatoryByKey` marks `coverTag` mandatory — so a field the project
had removed came back required, satisfiable only by typing into a column it had
chosen not to collect. That is how the 2026-09-21 approval got through. The
fallback is for a folder whose project carries **no template at all**, and now
only applies then. `tests/test_disabled_template_field.py` holds the backend
half of the contract the console mirrors.

**Open:**

- **Phase 8, the desktop cutover, is DONE** (2026-09-22, `081a756` for LWCAM
  and `9bc46d5` for LWCamAdmin), the hold lifted after this console was tested
  end to end. It went as the spec bullet that used to stand here described,
  with two departures, both recorded in the commits:

  **`UserRole.qc` stayed**, inert. Deleting the enum member was the plan and
  would have lost data: `lwcam_users.json` is shared with LWCam Admin and LWCAM
  rewrites it, while `UserRole.fromJson` ignores a role it does not recognise —
  so LWCAM would have read a reviewer's account, dropped the role, and written
  the snapshot back without it, with nothing failing anywhere. The member is
  parsed and serialized and acted on nowhere; `canQc`, the card, the route and
  the area count are gone, and a reviewer-only account is refused at the LWCAM
  login. PostgreSQL was never at risk — LWCAM only ever UPDATEs `password` and
  `last_login_at` on `users`. `user_role_qc_test.dart` guards that round-trip.

  **LWCamAdmin lost only the local engine** in Phase 8:
  `qc_backend_autostart_service.dart` and its logon registration went, while
  its QC fields stayed because the engine still read them. **That stopped on
  2026-09-23:** the server owns every setting in its own `config.txt`
  (`node_config.py` is deleted), and Station Setup lost its QC, captured-on-
  another-PC, AI and Upload sections. It kept only database provisioning at
  that point, running the LWCam install's own copy of `setup_qc_db.py` with the
  LWIP runtime's Python. **That in turn stopped on 2026-09-25** (`lwip-standalone`):
  provisioning moved to its own installer (`LWCamDatabaseSetup`), and Station
  Setup's Save now only tests the connection. The node-config model keeps the
  old fields so an older file still round-trips.

  Both tripwires held: `win32_job.dart` survives on `scrcpy_service.dart`, and
  `scope_bar_height_test.dart` kept working with `scopeBarControlHeight` moved
  to `app_theme.dart`. Totals: 45 files and 11,122 lines out of LWCAM, 430 more
  out of Admin; LWCAM analyze 5 known infos and 421 tests pass, Admin analyze
  clean and 131 pass.

  **This branch now has 0 of those files and the other four still have 20**, so
  a later merge from `master` that touches one will raise a modify/delete
  conflict. **The answer is always: stay deleted.** Low odds — those files have
  been touched by exactly 2 commits in the repo's history — but write it down
  when it happens.

- The preview and the exported TIFF resample at different SIZES, not with
  different filters: the preview replays ops on a 1600 px frame (Pillow LANCZOS
  after a JPEG `draft()` decode), export replays the same ops on the full 18 MP
  frame (OpenCV LANCZOS4). Both call the same `replay_pending_ops`, so geometry
  is identical and the preview is honest about framing, not about pixels — the
  ~130 ms vs ~1500 ms gap is the whole reason an edit click feels instant.
  Pillow BICUBIC appears only in the `cv2`-missing fallback, which this station
  never takes (`opencv-python-headless` is in `requirements.txt` and importable
  in the shipped runtime); the BICUBIC line in a test run comes from
  `test_deferred_geometry.py` patching `cv2` to `None` on purpose. Accepted as
  designed. A reviewer who must judge SHARPNESS needs a 1:1 viewport render,
  not a different filter.

**Fixed since:** `list_users` showed no multi-role account (`qc,admin`) under
any role filter — same comma-joined-column bug `reviewer_workload` already had.
Now filters on `role_set` in Python, with paging moved alongside it so `total`
and the window agree (`8bf1673`, `tests/test_user_role_filter.py`).

## Multi-PC hardening (2026-09-30)

The QC server is assumed to be a different PC from the database, LWIP, Upload
and the capture PCs (LAN or Tailscale, differing clocks, a slow or absent
peer). What that changed here:

- **Schema level 8.** `REQUIRED_SCHEMA = 8` (`services/schema_check.py`); every
  other part stays at 7. Migration `008_hardening.sql` adds
  `public.lwcam_next_export_number(bigint)` (SECURITY DEFINER, EXECUTE for
  `lwcam_qc` only) and takes CREATE on `public` away from `lwcam_qc`. Export
  keeps its advisory lock and calls the function instead of CREATE SEQUENCE +
  nextval. An old database answers "The database is older than this program
  (needs level 8, has N). Run LWCamDatabaseSetup on the database PC." on the
  status page and blocks work; it re-checks by itself.
- **System status** (`services/heartbeat.py`, the status page): the parts that
  must exist are `qc`, `qc-export`, `lwip`, `upload`, `backup` (a missing row is
  a red "never reported"); `capture` rows are informational (grey when off);
  ages are computed in SQL from the DB's `now()`; rows silent for over 7 days
  are hidden unless asked for; `DELETE /api/admin/system-status/{part}/{host}`
  ("Forget this PC", Admin) needs the DELETE grant migration 008 gives
  `lwcam_qc`.
- **Console** is https only (`core/tls.py` is byte-identical in QC, LWIP and
  Upload - edit LWIP's, copy the others). Installer docs:
  `installer\README.txt`.

Note (round 3): `setup_qc_db.py --open-lan` also sets `tcp_keepalives_idle=60`, `_interval=10`, `_count=6` (ALTER SYSTEM, reloadable) so a dead client PC's session, and the advisory locks it holds (an export lock), is dropped in about 2 minutes instead of hours.
