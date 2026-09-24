# AGENTS.md — LWCam suite workspace (`qc-platform` branch)

Guidance for Claude Code working in this repository. Each app has its own
`AGENTS.md` with its architecture; this file covers what spans them — how to
build and verify, what is already broken before you touch anything, and the
deployment traps that are not visible from the source.

**Layout on `qc-platform` (since 2026-09-23):** the apps sit at the repository
root — `LWCAM\`, `LWCamAdmin\`, `LWCam_QC_Platform\`, `installer\`, plus
`verification\` and `docs\`. Every other branch still nests them under
`DEV\All-In-One\apps\`, so a path copied from another branch's docs loses that
prefix here. Merges from `master` follow the move by rename detection. The two
`AGENTS.md` files are the exception: this guide was `DEV\All-In-One\apps\AGENTS.md`
and the FamilySearch handoff that `master` keeps at the root is `docs\FAMILYSEARCH-FIX.md`
here, so a `master` change to either doc conflicts — apply it to the file it
belongs to by hand.

The `AGENTS.md` at the root of the `Dev` work tree — one level ABOVE the
repository, so not tracked here — is a pointer, not a duplicate: Claude Code
walks upward from the working directory and loads every `AGENTS.md` it passes.
Edit THIS file for anything about the code; the pointer describes the folder
layout and the station.

## The three apps

| Path | What it is |
| --- | --- |
| `LWCAM` | Flutter Windows capture app. Capture, the rework recapture list, and supervision of **LWIP** (`LWCAM/LWIP`), the Python deskew/crop/thumbnail watcher. **No QC** since Phase 8 (2026-09-22): the review screens and the local engine are gone. |
| `LWCamAdmin` | Flutter Windows SuperAdmin app. Owns Station Setup, which writes the capture station's config (`lwcam_node_config.json`) and creates/upgrades the PostgreSQL schema. No QC, upload or AI settings since 2026-09-23 — the QC server owns those. |
| `LWCam_QC_Platform` | **QC as a standalone LAN server** — FastAPI backend plus the Vue console it serves from `frontend/dist`. Review, approve, reject, separation, client rework, export, admin settings. It talks to LWCAM only through the database. **Start with `LWCam_QC_Platform/AGENTS.md`** for anything QC. |

All three share one PostgreSQL schema. Column ownership is strict and enforced by
convention only — see the table in `LWCam_QC_Platform/AGENTS.md`.

**Upload lives in the QC server**: `LWCam_QC_Platform/backend/app/services/upload.py`,
a 60-second sweep that sends published packages to S3, verifies each by size,
writes `Upload_Summary.db3` and moves the package to the Uploaded folder. Its
settings are in the QC server's `config.txt` and edited from the console's
Admin → Settings (since 2026-09-23). The console still has no screen for
upload *status* — `GET /api/admin/exports/uploads` and
`POST /api/admin/exports/uploads/retry` exist with nothing calling them.

**The QC server owns all its settings** in its own `config.txt` (DB login, JWT
secret, bind address/port, folders, upload, AI) and reads nothing from LWCam
Admin — `LWCam_QC_Platform/AGENTS.md` has the key list. The two apps share only
the database, and both create/upgrade its schema with the same
`LWCam_QC_Platform/scripts/setup_qc_db.py`.

## Gates, and the baseline they must beat

Run these before claiming anything works. **The numbers on the right were
measured on 2026-09-23 on this branch — several failures are pre-existing and
chasing them wastes a session.**

```bash
cd LWCAM        && flutter analyze && flutter test     # 5 infos, 423 pass
cd LWCamAdmin   && flutter analyze && flutter test     # clean,   117 pass
cd LWCam_QC_Platform/backend && C:\Python314\python.exe -m unittest discover -s tests -t .
                                                       # 196 pass, 0 fail
cd LWCam_QC_Platform/frontend && npm run build         # vue-tsc --noEmit && vite build
cd LWCAM/LWIP/backend && C:\Python314\python.exe -m unittest discover -s tests
                                                       # 64 run, 3 fail, 5 skipped
```

**Interpreter:** `C:\Python314\python.exe`. The installed LW Suite and both of
its bundled Pythons were removed from this station on 2026-09-21; `C:\Python314`
satisfies the QC backend's `requirements.txt` and LWIP's imports. pytest is in
neither `requirements.txt` nor the offline wheels — the suites are
`unittest.TestCase` classes written to run without it.

**Known-failing before any change:**

- **LWCAM `flutter analyze`: 5 `curly_braces_in_flow_control_structures` infos** in
  `box_session_controller.dart`, `box_integrity.dart` (two), `pg_sync_sink.dart`,
  `transfer_queue_service.dart`.
- **QC backend: none.** Any failure is a regression. Two alarming-looking log
  lines in a green run are tests doing their job: *"cv2 is not importable;
  falling back to Pillow BICUBIC"* comes from a test that patches `cv2` to
  `None` on purpose, and the *"AI review OpenRouter call failed"* lines are the
  retry ladder being exercised against a stub.
- **LWIP: 3 failures, identical on the tree before the 2026-09-23 move** (checked
  in a detached worktree). Two are the negative controls in `test_long_paths.py`
  (`test_a_long_path_is_writable_only_through_fs_path`,
  `test_the_same_folder_fails_without_the_guard`): they expect a long path to
  FAIL without the `\\?\` guard, and on this PC it succeeds — long paths are
  enabled for this Python. The third,
  `test_preview_detection_crops_at_original_resolution`, measures a width 25 px
  off its expectation against a 16 px tolerance. The older "1 fail, 29 pass"
  figure (an 8.3 short-path artifact) is from a smaller suite on another PC.

If a count changes, that is yours. **Establish the baseline before concluding a
failure is pre-existing.** The stash stack is shared by every worktree and by
other sessions, so prefer a detached worktree of `HEAD`
(`git worktree add --detach <dir> HEAD`, run, `git worktree remove`) or a WIP
commit over `git stash`.

**The shipped runtime imports the INSTALLED backend, not your worktree.** Moot
while nothing is installed here; it comes back with the next install. Its
`runtime\python\python313._pth` hardcodes `..\..\backend` — that is
`C:\Program Files\LW Suite\QC\backend` — onto `sys.path`, and an embeddable
`._pth` ignores `PYTHONPATH` and does not put the working directory on the path
either. So:

```bash
# LIES: silently imports the installed copy, whatever you have edited
python.exe -c "from app.main import app; print(len(app.routes))"

# TRUE: `unittest discover -s tests -t .` inserts the target dir itself
python.exe -m unittest discover -s tests -t .
# any ad-hoc script needs the same, explicitly:
python.exe -c "import sys; sys.path.insert(0, '.'); import app.main"
```

Start the server with `run_server.py`, never `python -m app.main`, for the same
reason — `LWCam_QC_Platform/AGENTS.md` has the detail. Confirm which tree you
actually loaded (`print(module.__file__)`) before believing a result.

## Line endings are mixed, per file

`.gitattributes` sets `* -text`, so git converts nothing and every file keeps
whatever it already uses — `AGENTS.md` and `LWSuite.iss` are CRLF,
`export.py` and `LWCam_QC_Platform/AGENTS.md` are LF. Anything that rewrites a
whole file must preserve its style, or the commit shows every line changed.
**Git Bash's `sed -i` silently converts a CRLF file to LF** — that is how this
file lost its endings once. Use an editor, or a script that reads and writes
bytes, and check `file <path>` before committing.

## Running a dev build: bundled runtimes are NOT beside it

This cost three separate debugging sessions. `flutter build windows --debug`
produces `LWCAM/build/windows/x64/runner/Debug/lwcam.exe`, and **the things
it shells out to live next to the INSTALLED exe, not the built one**:

| Needs | Resolver | Fix for a dev build |
| --- | --- | --- |
| `adb.exe` (+ `AdbWinApi.dll`, `AdbWinUsbApi.dll`) | `gallery_page.dart:_resolveAdbPath` — exe dir, cwd, `C:\Android\platform-tools`, PATH | copy into the Debug folder from an install or the Android platform-tools |
| `scrcpy` | `scrcpy_service.dart:resolveScrcpyExe` — walks 7 levels up looking for `scrcpy/scrcpy.exe` | put a Windows build in `LWCAM\scrcpy` (gitignored), which the walk finds |
| LWIP runtime | `lwip_autostart_service.dart:resolveLwipRoot` — needs `runtime/python/pythonw.exe` **and** `backend/deskew_crop_tool` | run `LWCAM\LWIP\SETUP_DESKEW_CROP.bat`, or ignore |

The install these used to be copied from (`C:\Program Files\LW Suite`) is gone
from this station. Without `adb` every capture symptom appears at once — no
crop, dead shutter, no images detected — because all three are adb calls.
`build/` is gitignored, so none of this pollutes the repo, but **`flutter clean`
deletes it all**.

Debug builds relink the runner exe only when native code changes: after a Dart-only
change the **exe timestamp stays old and `data/flutter_assets/kernel_blob.bin` is
what updates**. Check that, not the exe.

## Verifying a build actually contains a change

String-searching a build is valid but easy to get wrong — three false alarms in
one session:

- `strings` finds nothing in `app.so`; use `grep -a` (raw bytes).
- Interpolated Dart strings are stored as fragments — `'Page ${i} of ${n}'` never
  appears as `Page 1 of 3`. Search a literal fragment.
- The installer is LZMA-compressed; `grep` on `LWSuite.exe` proves nothing. Read
  the ISCC compile log instead.
- **Always check a control string** that certainly exists before trusting a
  negative result.

Release builds put Dart in `data/app.so`; debug builds in `kernel_blob.bin`.

## Deploying

```bash
cd LWCAM      && flutter build windows --release
cd LWCamAdmin && flutter build windows --release
cd installer  && powershell -File build-installer.ps1 -Target All   # or LWCam / QC
```

**Two installers since 2026-09-23** (`installer/README.txt` has the detail):

- `LWCamSetup.exe` (`LWCam.iss`) — LWCAM, LWCam Admin, LWIP, plus
  `{app}\Database\` (setup_qc_db.py + SQL) for Station Setup. Keeps the old
  LW Suite AppId, so an all-in-one station upgrades in place; its old `{app}\QC`
  engine is stopped and removed. LWCam Admin is Start-menu only.
- `QCPlatformSetup.exe` (`QCPlatform.iss`) — the QC server + console. Writes
  `{app}\config\config.txt` (private folder; fresh CSPRNG `jwtSecret`,
  `bindHost = 0.0.0.0`), creates/upgrades the schema, registers the "LWCam QC
  Server" task at system start as SYSTEM, and opens the configured port in the
  firewall (Domain + Private).

Both can install PostgreSQL (shared `installer/postgres.iss`), both stop their
running processes in `PrepareToInstall` and abort if one survives, and both
write secrets only into files already restricted to SYSTEM + Administrators.
**Neither has been test-installed yet.**

`C:\Program Files\LW Suite\` **needs elevation** — plain `cp` fails. Either
rebuild the installer or copy with elevation.

`-ScrcpyDir` is optional. The script takes `LWCAM/scrcpy` (gitignored, like
`LWIP/wheels/`) whenever it holds a `scrcpy.exe` — the same folder
`LWCam.iss`'s own `#ifndef` default names; winget's package is only the
fallback. The gitignored inputs (vendor zip, vcruntime, adb, wheels, jpegtran,
scrcpy, the PostgreSQL exe) are listed in `installer/README.txt`; on this
station they were copied from the `Source` worktree.

Outputs land at the repository root: `LWCamSetup.exe` (~103 MB),
`QCPlatformSetup.exe` (~99 MB) and, copied beside them,
`postgresql-18.6-1-windows-x64.exe` (359 MB). All ignored by `*.exe`. **Ship
each setup file with the PostgreSQL exe** — see Station facts.

The installer bundles the **Release** builds and the repo's LWIP and QC backend
trees, so backend changes ship automatically — but stale Release builds ship
silently. Check `data/app.so` timestamps against `lib/` before compiling.
**Building only `--debug` and then reinstalling ships the previous Release** —
that happened once and looked exactly like the installer not picking changes up.

**Setup stops running Python before copying**, in `PrepareToInstall` — before
any file is written or deleted — and aborts if a process survives. Without it
an upgrade left the old process alive: setup overwrites its `.py` underneath
it, the process keeps serving the code it imported at startup, and the station
looks freshly installed while running the previous version — no error
anywhere. Restart Manager cannot catch it, since Python closes a `.py` after
reading it and holds no lock, which is also why the overwrite succeeds
silently. Processes are matched by COMMAND LINE against the install folder,
never by name (`PythonProcessesUnder` in `postgres.iss`), so unrelated Python
survives. LWCam drains LWIP gracefully first (stop file, 90 s) and removes an
all-in-one `{app}\QC`; the QC installer ends its scheduled task and restarts it
after the upgrade.

## Decisions inherited from `master` (the Taiping/FamilySearch baseline)

`qc-platform` branched from `master`, which was cut from the tree the South
Africa DoD installer was built from and grew through the Taiping All Saints
Church delivery. These decisions came with it and hold here.

**Volume is free text and the folder name IS the Volume.** The `file no.`
convention is gone: `fileNumberOfVolume`, `volumeCarryOver`,
`finalizeVolumeForUnknown` and `CaptureFolder.fileNumber` are deleted, and
transfer prep no longer rewrites `volume` - it used to substitute
`(unknown file [N])` INTO it, so the exported value differed from what was
keyed. Uniqueness survives, because the name becomes a real directory that
`UploadController._destPathFor` joins:

- compared case-INSENSITIVELY - Windows does not distinguish `Register 12` from
  `register 12`, and both keeping the bare name merged two folders into one;
- names taken by OTHER groups are reserved (`UploadStatsDB.reservedFolderNames`),
  because the destination is `<root>\<YYYYMMDD>\<folderName>` - a shared day
  folder with nothing in the path identifying the group;
- a blank Volume is detected on the RAW value BEFORE sanitising, since
  `sanitizeWindowsName('')` returns `_` and would otherwise name a folder `_`.

**Carry-over between folders is OFF.** One call site in `gallery_page.dart`, so
restoring it is a one-line change.

**Geometry is DATA until export. Nothing between the camera and the TIFF
re-encodes a page.** (Since 2026-09-10; the earlier design flushed edits into a
q100 JPEG at approval, and before that LWIP itself rotated and re-encoded every
page - FamilySearch rejected that delivery for "image enhancement".)

- **LWIP measures, never rotates.** It crops the camera JPEG in its own coded
  blocks (`jpegtran`, see `LWIP/README.txt`), so the page file in 2.Batches is
  the camera's bytes. The measured tilt becomes an op list in the manifest:
  `.deskew_crop_manifest.json` `files[].qc_ops` =
  `[{"op":"deskew","degrees":D},{"op":"crop","rect":[x0,y0,x1,y1]}]`, empty
  under `deskew_min_degrees` (0.5). The rect is normalised against the ROTATED,
  EXPANDED frame, i.e. exactly what `replay_pending_ops` produces - LWIP
  predicts Pillow's `expand=True` geometry rather than calling it. Thumbnails
  are the one place LWIP applies the ops, at 512 px, because the QC rail shows
  them.
- **The engine layers three lists**, in order: LWIP baseline (`lwip_baseline.py`,
  from the manifest), committed QC ops (`qc_ops_store.py`, `qc_ops.json` beside
  the manifest, written at approval), and the reviewer's draft (`pending_ops`).
  `effective_ops` is that concatenation; preview, thumbnail, `to_task_vo`'s
  version stamp and export all use it. Crop rects stay normalised, so one list
  drives the 1600 px preview and the full-size TIFF.
- **Approval writes data, not pixels.** `commit_current_draft` folds pending
  geometry into `qc_ops.json` through the same stage/finalize/abort as every
  other file write. Replace sets `ignore_lwip` (a new capture, LWIP's angle no
  longer applies); delete drops the entry; restore original leaves a
  `{"restored": true}` marker so committed ops from an earlier round are
  dropped and the page returns to LWIP's baseline. `qc_ops.json` lives in the
  folder LWIP republishes, so a capture rework wipes it - correct, the pages
  are new.
- **Export replays once.** `convert_to_tiff(source, target, ops)` decodes the
  camera crop, replays `effective_ops`, writes the lossless TIFF (predictor 2 —
  see `LWCam_QC_Platform/AGENTS.md`). Rotation is Lanczos through OpenCV
  (`opencv-python-headless`, in the wheels), sized and placed exactly as
  Pillow's `rotate(expand=True)` so the rects align; Pillow bicubic is the
  fallback if cv2 is missing. A page with no ops is pixel-identical to the
  camera decode.
- **Luminance is the only thing allowed to bake pixels**, and it is OFF by
  default (`luminance_enabled`, `NodeConfig.luminanceEnabled`, both false since
  2026-09-10). When a project turns it on, `flush_pending_ops` bakes the
  effective chain into the work copy first and marks the item `baked`, so
  approval commits that copy with `ops: []` and `ignore_lwip: true` - the
  pixels already contain everything.

Order is the contract - cropping then rotating is not the same picture - so the
list is replayed exactly as recorded, never bucketed by kind.

**Batch image operations run on threads, not processes.** Pillow releases the
GIL for decode, resample and encode; 12 deskews went 16.9s -> 3.9s. Capped at 8
because memory binds before cores. Processes would pay a Windows interpreter
spawn each, which `export.py` already refuses for small batches.

**Preview URLs are stamped PER IMAGE.** They carried the manifest's folder-wide
`updated_at`, so editing page 12 changed the URL of every page already edited
and the rail re-rendered all of them. Previews also `draft()` during JPEG decode
(454ms -> 284ms).

**Client rework replaces the delivered package under the SAME Group ID.**
FamilySearch's requirement, not a convenience. `revert` returns a finished
folder to PENDING with `client_rework`, clears `is_exported`, KEEPS `group_id`,
and claims it for the reverter so they land straight in review. Four guards that
exist to stop double publishing each carry a rework-only exception: the export's
adopt branch (which would otherwise ship the package the client REJECTED),
`publish_zip`/`publish_folder`, the upload sweep's UPLOADED skip (the export
clears that ledger row), and `move_to_done`. `revert` is the only mutating QC
endpoint that cannot `assert_lock_owner`: approve and reject both release the
lock, so a finished folder is never claimed. It checks the one-task-per-person
rule BEFORE changing anything, so a refusal cannot leave a folder reopened but
unclaimed.

**A row can outlive its file, and both repairs must work.** An image inserted
during QC does not survive a capture rework: LWIP rebuilds the folder from what
was captured, and an inserted page was never in the capture folder. That is
intended - a recaptured folder is a fresh decision about what belongs in it -
but it must not strand the folder. So `canOpenQcTask` needs ANY readable page
rather than every one (opening it is the only way to fix a missing page), and
`expected_image_path` splits path resolution from the existence check so the
commit can delete or replace a page whose file has gone. The traversal and
unconfigured-folder guards stay on BOTH paths; only `is_file` moved.

**`qcInputRoot` is the export SCRATCH root, not the image source.** Images come
from `capture_folders.folder_path` through `to_local`. The name misleads; it
defaults to 2.Batches only because that is convenient on a single PC. On a split
site it must be LOCAL, or every export writes ~10x TIFF scratch back across the
network into the capture PC's pipeline folder.

### Two-PC sites (capture PC hosts the database, QC/export PC connects)

- Installer task **"This station uses a PostgreSQL server on another PC"** makes
  `NeedsPostgreSql` false, so no server is installed, no `station-seed.json` is
  written (it would point the client at localhost) and `PrepareToInstall` stops
  demanding the 358 MB file.
- Station Setup gained **"Images captured on another PC"** -
  `captureImageHostPath` / `captureImageContainerPath`, mapped through the node
  config and read by `paths.to_local`. This lets the capture PC keep recording
  fast local paths while the QC PC maps that prefix onto a share, instead of
  making the capture PC write UNC paths and pay SMB on its own writes. The
  console's own `qcImagesRoot` (`config.txt`) is the other way to do the same.
- `SETUP-LAN-DB.bat` (in the Taiping deploy folder, not this repository)
  configures the hosting PC end to end (static IP on the cable, `pg_hba`,
  firewall, restart), idempotent and self-healing. `SHOW-DB-PASSWORD.bat` prints
  the password from both places it can live and says which one actually logs in.

**The PostgreSQL password changes whenever the server is reinstalled**, and
`postgres-password.txt` can go stale by itself: when setup reinstalls over an
existing data directory the cluster keeps its OLD password while the file may
record a freshly invented one. `lwcam_node_config.json`'s `pgPassword` is the
value the station actually connects with. This cost real time twice - check it
before debugging anything else.

### Traps that cost time here

- **`Set-Content -Encoding utf8` on Windows PowerShell 5.1 writes a BOM.** One
  in `pg_hba.conf` stops PostgreSQL starting, and the station then reports only
  "could not reach the database server", which points nowhere near the cause.
  Write config files with `UTF8Encoding($false)`.
- **`pg_hba` must allow the `postgres` database, not just `lwcam`.** Saving
  Station Setup runs the provisioner, which connects to the maintenance
  database to see whether `lwcam` exists - you cannot connect to a database in
  order to create it. Test connection passes and the save fails.
- **`upload_summary.normalize_rework` returns the CSV's `"TRUE"`/`"FALSE"`
  TEXT.** `bool("FALSE")` is True, so a bool() check reads every package as a
  rework and overwrites unconditionally. Compare to the string.
- **Hand-listed field copies silently drop new fields.** Record Type was lost in
  THREE separate places that enumerated columns by hand instead of copying the
  model - `updateCaptureFolderMetadata`, the New Group flow's re-home, and the
  export/QC title-map precedence. If you are writing a field list, ask what
  happens when field 15 arrives.

## State of play (2026-09-23)

The QC platform's own state — what was exercised on the console, test folders,
and its open list — is in `LWCam_QC_Platform/AGENTS.md`. What spans the apps:

**Done.** Phase 8, the desktop cutover (2026-09-22): LWCAM has no QC and
LWCamAdmin no longer registers a local QC engine. The console has been tested
end to end on this station: review, approve, separation, export with predictor
2, the auto-export sweep and its on/off switch. **Client rework was proven on
2026-09-23** against the running server (folder 15, driven through the API
rather than the console's buttons): revert kept Group ID `…000014`, a 90°
rotate was committed as data, and the sweep replaced the package in
`3.Export` in place 28 s after approval — page 1 rotated, pages 2–4
byte-identical, the CSV's Rework column `FALSE` → `TRUE`, source JPEGs
untouched. The pre-test package is kept at
`C:\LWCamTest\scratch\before-client-rework-test-20260923`.

**Open:**

- **The installer split is built and reviewed but not test-installed**
  (2026-09-23/24: the QC server owns its settings, the console edits upload and
  AI, Station Setup lost its QC sections, two installers). Neither installer has
  been run on a PC; the scheduled task at boot, the firewall rule, the private
  config folder and an all-in-one upgrade are proven only by review and by
  scratch tests of the permission helper.
- **LAN access** is installer-configured (`bindHost = 0.0.0.0`, firewall rule on
  Domain + Private networks). A dev checkout stays on loopback. A LAN bind with
  no `corsAllowedOrigins` gets no CORS — the console is same-origin.
- **Upload status** has no console screen (see "The three apps"). Also
  untested: the bucket half of client rework (the same Group ID replacing the
  package in S3 and in `4.Uploaded`); upload is off here and no bucket is set.
- **Capture rework cannot be exercised on this station** — no camera, no LWIP
  install.

## Station facts

- Config: `%USERPROFILE%\LWCAM_DBs\` — `lwcam_node_config.json` (LWCAM/LWIP's
  PG credentials and paths; its old QC/upload/AI fields are kept only so the
  file round-trips), `lwcam_users.json` (the snapshot LWCAM authenticates
  against), `lwcam_stats_<deviceId>.db`, `lwip/` runtime + journal. The QC
  server's settings are `LWCam_QC_Platform\config.txt` (gitignored; on this
  station it carries the DB login and JWT secret copied from the node config).
- **This station has no LW Suite install** (removed 2026-09-21). Test data lives
  at `C:\LWCamTest` (`2.Batches`, `3.Export`, `scratch`), with an untouched copy
  at `Desktop\LWCam Test Data Backup 2026-09-21`. The node config's upload
  folders still point into `C:\Program Files\LW Suite`, which no longer exists.
- On an installed station data lives **inside the install tree**:
  `C:\Program Files\LW Suite\LWCam Capture\` (`1.Images`, `2.Batches`,
  `3.Export`, `4.Uploaded`), plus `C:\Program Files\LW Suite\Upload Reports\Upload_Summary.db3`
  (one row per uploaded package). **Back it up before uninstalling.**
- PostgreSQL is a separate install and survives an LW Suite uninstall — but the
  installer reinstalls it if absent, with a new password. Its 359 MB setup exe
  is **not inside either installer**: it ships beside them and `[Run]` launches
  it from `{src}`. `PrepareToInstall` aborts by name when the PC needs a server
  and the file is not there. `build-installer.ps1` copies it next to the built
  installers; ship it with each.
- Never run the installed LWCAM and a dev build at once: they share the per-device
  SQLite DB and the transfer lock.

## Working habits that paid off here

- **Prove a regression test fails without the fix.** Several times a test passed
  either way until checked; twice the "fix" was in the wrong place.
- **Baseline before blaming.** Run the same check on `HEAD` in a detached
  worktree, then compare.
- **A misleading comment is worse than none.** Two bugs survived because a
  comment claimed the case was handled — `"Replacement slots are always
  re-pulled"` was true of the branch above it and false of the one below.
- **A switch that is only read at startup passes every unit test that starts a
  fresh object.** Flip it on a running process — that is how the sweep-switch
  bug was found.
