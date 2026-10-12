# AGENTS.md — LWCam Module edition (branch lwcam-module)

Technical guide for developers and AI coding tools. Each module has its own
`AGENTS.md` with file-by-file architecture. This file covers what spans them:
how to build and verify, the traps that are not visible from the source, and the
design decisions that look like mistakes. Setup, tests and releases are in
`docs/` (`DEV-SETUP.md`, `TESTING.md`, `RELEASING.md`); short records of the
non-obvious decisions are in `docs/decisions/`.

Layout: every module sits at the repository root. The older All-In-One edition
(branch `lwcam-all-in-one`) uses the same layout, except that LWIP sits inside
the capture app there (`LWCAM\LWIP\`) and there is no `LWCam_Upload\`.

## The five modules

| Path | What it is |
| --- | --- |
| `LWCAM` | Flutter Windows capture app: pulls photos from an Android phone over adb, keys metadata, copies to the destination, and runs the rework (recapture) list. No QC and no LWIP inside it. |
| `LWCamAdmin` | Flutter Windows SuperAdmin app: users, projects, devices, shared settings, and Station Setup (writes the capture PC's `lwcam_node_config.json`; only TESTS the database connection). The only writer of `users`/`projects`/`app_settings`. |
| `LWIP` | Python service: deskew/crop/thumbnail. Runs as a boot-time SYSTEM task, reports each finished folder to PostgreSQL itself (`backend/deskew_crop_tool/cloud_report.py`). Start with `LWIP/README.md`. |
| `LWCam_QC_Platform` | FastAPI backend plus the Vue console it serves from `frontend/dist`: review, approve, reject, separation, client rework, export. Talks to the other parts only through the database. Start with `LWCam_QC_Platform/AGENTS.md`. |
| `LWCam_Upload` | Python service: watches QC's output folder, uploads each package to S3 with size verification, keeps its own ledger (`Upload_Summary.db3`), serves its own console on 8091. |

Plus `installer/` (Inno Setup scripts for the five installers) and `verification/`.

All five share one PostgreSQL schema (`LWCam_QC_Platform/database/`). Column
ownership is strict and enforced by convention only: see the table in
`LWCam_QC_Platform/AGENTS.md`. Each part can run on a different PC.

- The QC server owns all its settings in its own `config.txt` and reads nothing
  from LWCam Admin.
- Only `LWCamDatabaseSetup` creates and upgrades the schema, by running
  `LWCam_QC_Platform/scripts/setup_qc_db.py`. No other installer and no
  Station Setup does.
- Schema level: the highest number in `schema_migrations`. QC requires 8
  (`REQUIRED_SCHEMA` in `services/schema_check.py`); LWCAM, LWIP and Upload
  require 7. An older database blocks the part and the QC status page says so.

## Build, test, run

```bash
cd LWCAM        && flutter analyze && flutter test
cd LWCamAdmin   && flutter analyze && flutter test
cd LWCam_QC_Platform/backend  && python -m unittest discover -s tests -t .
cd LWCam_QC_Platform/frontend && npm run build        # vue-tsc --noEmit && vite build
cd LWIP/backend               && python -m unittest discover -s tests
cd LWCam_Upload/backend       && python -m unittest discover -s tests
```

Expected counts and the known failures are in `docs/TESTING.md`. Run the suites
before claiming anything works. Python is 3.14. The suites are
`unittest.TestCase` classes written to run without pytest (it is in no
`requirements.txt` and no offline wheel folder).

Known failures that exist before any change:

- LWCAM `flutter analyze`: 5 `curly_braces_in_flow_control_structures` infos
  (`box_session_controller.dart`, `box_integrity.dart` twice, `pg_sync_sink.dart`,
  `transfer_queue_service.dart`).
- QC backend: none. Two alarming log lines in a green run are tests working:
  "cv2 is not importable; falling back to Pillow BICUBIC" (a test patches `cv2`
  to `None`) and "AI review OpenRouter call failed" (the retry ladder against a stub).
- LWIP: 2 failures, the negative controls in `test_long_paths.py`
  (`test_a_long_path_is_writable_only_through_fs_path`,
  `test_the_same_folder_fails_without_the_guard`). They expect a long path to fail
  without the `\\?\` guard; they fail on a PC where long paths are enabled. One
  skip (`test_non_windows_is_untouched`) is expected on Windows.

If a count changes, it is yours. Establish the baseline on a clean checkout of
`HEAD` before you conclude a failure was already there.

Build the installers (needs the build inputs; see `installer/README.md`):

```bash
cd LWCAM      && flutter build windows --release
cd LWCamAdmin && flutter build windows --release
cd installer  && powershell -File build-installer.ps1 -Target All   # or LWCam / QC / LWIP / Upload / Database
```

## Trap: the shipped runtime imports the INSTALLED backend

The embeddable Python in an installed QC or LWIP folder has a `._pth` file
(`runtime\python\python314._pth`) that puts the INSTALLED `backend` folder on
`sys.path`. An embeddable `._pth` ignores `PYTHONPATH` and does not add the
working directory. So, with that runtime:

```bash
# LIES: silently imports the installed copy, whatever you edited
python.exe -c "from app.main import app; print(len(app.routes))"

# TRUE: `unittest discover -s tests -t .` inserts the target dir itself
python.exe -m unittest discover -s tests -t .
# any ad-hoc script needs the same, explicitly:
python.exe -c "import sys; sys.path.insert(0, '.'); import app.main"
```

Start the QC server with `run_server.py`, never `python -m app.main`, for the
same reason (`LWCam_QC_Platform/AGENTS.md` has the detail). Print
`module.__file__` before you believe a result. A normal system Python has no
such problem.

## Trap: line endings are mixed, per file

`.gitattributes` sets `* -text`: git converts nothing, and every file keeps the
style it already has. Some files are CRLF, some LF (`file <path>` tells you; `export.py` is LF). Anything that rewrites a whole
file must keep its style, or the commit shows every line changed. Git Bash
`sed -i` silently turns CRLF into LF. Use an editor, or a script that works on
bytes, check `file <path>`, and check `git diff --stat` before you commit.

## Trap: a dev build has no bundled runtimes beside it

`flutter build windows --debug` produces
`LWCAM/build/windows/x64/runner/Debug/lwcam.exe`. The tools it starts live next
to the INSTALLED exe, not the built one:

| Needs | Resolver | Fix for a dev build |
| --- | --- | --- |
| `adb.exe` (+ `AdbWinApi.dll`, `AdbWinUsbApi.dll`) | `gallery_page.dart:_resolveAdbPath`: exe dir, cwd, `C:\Android\platform-tools`, PATH | copy them into the Debug folder, or install the Android platform-tools |
| `scrcpy` | `scrcpy_service.dart:resolveScrcpyExe`: walks 7 levels up for `scrcpy/scrcpy.exe` | put a Windows build in `LWCAM\scrcpy` (gitignored) |

Without `adb`, every capture symptom appears at once (no crop, dead shutter, no
images detected), because all three are adb calls. LWCAM needs no LWIP beside it.
`flutter clean` deletes `build/`, including anything you copied there. After a
Dart-only change a debug build's exe timestamp stays old; the file that updates
is `data/flutter_assets/kernel_blob.bin`.

Never run the installed LWCAM and a dev build at once: they share the per-device
SQLite DB and the transfer lock.

## Trap: verifying that a build contains a change

- `strings` finds nothing in `app.so`; use `grep -a`.
- Interpolated Dart strings are stored as fragments (`'Page ${i} of ${n}'` never
  appears as `Page 1 of 3`). Search a literal fragment.
- The installer is LZMA-compressed; `grep` on the `.exe` proves nothing. Read
  the ISCC compile log, or install and inspect.
- Always check a control string that certainly exists before you trust a
  negative result.
- Release builds keep Dart in `data/app.so`; debug builds in `kernel_blob.bin`.
- The installer bundles the Release builds, and stale Release builds ship
  silently. Compare `data/app.so` timestamps with `lib/` before you compile.
  Building only `--debug` and reinstalling ships the previous Release.

## Installers

Five installers (`installer/`, details in `installer/README.md`):

| Installer | Script | What it does |
| --- | --- | --- |
| `LWCamDatabaseSetup.exe` | `Database.iss` | The only one that installs PostgreSQL (or uses an existing server). Creates and upgrades the schema, creates the shared login, can open the server to the LAN (`--open-lan` + firewall rule), schedules backups. Ships with the PostgreSQL installer exe beside it. |
| `QCPlatformSetup.exe` | `QCPlatform.iss` | QC server + console. Writes `{app}\config\config.txt` on a fresh install (generated `jwtSecret`, `bindHost = 0.0.0.0`). Task "LWCam QC Server" at boot as SYSTEM; firewall rule for the port. |
| `LWIPSetup.exe` | `LWIP.iss` | LWIP with its own offline Python runtime. Task "LWCam LWIP". Own `config\deskew_crop_config.json`. Console on 8090. |
| `LWCamUploadSetup.exe` | `Upload.iss` | LWCam Upload. Task "LWCam Upload". Own `config\upload_config.json`. Console on 8091. |
| `LWCamSetup.exe` | `LWCam.iss` | LWCAM + LWCam Admin (Admin is Start-menu only). Keeps the old LW Suite AppId, so an all-in-one station upgrades in place (old LWIP, old QC engine, old Database folder are stopped and removed). |

Site install order: `LWCamDatabaseSetup` once, then `QCPlatformSetup` and
`LWIPSetup` and `LWCamUploadSetup`, then `LWCamSetup` on each capture PC. Every
part needs the database login the first installer's finish page shows.

Rules the installers follow, and that a change must not break:

- **Stop Python before copying.** `PrepareToInstall` stops every Python process
  whose COMMAND LINE points into the install folder (`PythonProcessesUnder` in
  `common.iss`; never match by name) and aborts if one survives. Without it an
  upgrade overwrites `.py` files under a running process, which keeps serving
  the code it imported at start, with no error anywhere. Restart Manager cannot
  see it, because Python closes a `.py` after reading it.
- **Secrets only go into files restricted to SYSTEM + Administrators**
  (`RestrictToAdmins`, `SetExactAcl`, `LockProgramFolder` in `common.iss`), and
  are encrypted right after (see `SECURITY.md`).
- Boot tasks are registered with `Register-ScheduledTask` with no time limit, and
  the `START_*.bat` files restart the service in a loop.
- `{app}` and `%ProgramData%\LWCAM` are admin-write only.
- Uninstall keeps `state.json`, `uploads.json` and `database.txt`.
- `build-installer.ps1` appends `-dirty` to the build id when the tree is dirty,
  runs `npm ci` first, and checks the staged inputs against `SHA256SUMS.txt`.
  `VERSION` is `1.1.0`; the installed version is `1.1.0+<git sha>`.
- The PostgreSQL password changes whenever the server is reinstalled over an
  existing data directory, and a stale password file can disagree with the
  cluster. `config\database.txt` is rewritten when PostgreSQL is reinstalled.

## Design decisions (do not "fix" these)

Each has a longer record in `docs/decisions/`. The summary:

1. **Geometry is data until export.** Nothing between the camera and the TIFF
   re-encodes a page. LWIP measures and records ops; QC replays the whole chain
   once at export. FamilySearch rejected an earlier delivery for "image
   enhancement" (`docs/FAMILYSEARCH-FIX.md`).
2. **Client rework replaces the delivered package under the SAME Group ID.**
   FamilySearch's requirement.
3. **QC keeps the pages it adds through a capture rework** (`qc_kept_pages.py`).
4. **QC is standalone.** It speaks to the other parts only through the database.
5. **One shared database login** (group role `lwcam_app`), chosen at install.
6. **Volume is free text and the folder name IS the Volume.**
7. **Rejecting a separated child stays blocked.**
8. **One live sign-in per account, the first wins.**
9. **Every console is https-only**, with a per-PC certificate authority.
10. **Upload is its own service.** QC does not upload and has no upload settings.

### Geometry details

- **LWIP measures, never rotates.** It crops the camera JPEG in its own coded
  blocks (`jpegtran`), so the page in `2.Batches` is the camera's bytes. The
  tilt becomes an op list in the manifest `.deskew_crop_manifest.json`
  `files[].qc_ops` = `[{"op":"deskew","degrees":D},{"op":"crop","rect":[x0,y0,x1,y1]}]`,
  empty under `deskew_min_degrees` (0.5). The rect is normalised against the
  ROTATED, EXPANDED frame, exactly what `replay_pending_ops` produces; LWIP
  predicts Pillow's `expand=True` geometry rather than calling it. Thumbnails
  (512 px) are the one place LWIP applies the ops.
- **A tilted page keeps `crop_padding` of real background in the TIFF.** The
  lossless trim is the pre-image of the final straightened crop (page +
  padding) plus `RESAMPLE_REACH` (8 px, the export's Lanczos4 reach).
  `_clamp_to_rotated_frame` pulls in only the side that runs off the photo,
  keeping 8 px clear. Straight pages use the exact `cv2.boundingRect` box.
- **The engine layers three lists**: LWIP baseline (`lwip_baseline.py`, from the
  manifest), committed QC ops (`qc_ops_store.py`, `qc_ops.json` beside the
  manifest, written at approval) and the reviewer's draft (`pending_ops`).
  `effective_ops` is the concatenation; preview, thumbnail, version stamp and
  export all use it. Crop rects are normalised, so one list drives the 1600 px
  preview and the full-size TIFF.
- **Approval writes data, not pixels.** `commit_current_draft` folds pending
  geometry into `qc_ops.json`. Replace sets `ignore_lwip`; delete drops the
  entry; restore original leaves `{"restored": true}`.
- **Export replays once.** `convert_to_tiff(source, target, ops)` decodes the
  camera crop, replays `effective_ops`, writes a lossless TIFF (predictor 2).
  Rotation is Lanczos through OpenCV (`opencv-python-headless`), sized and
  placed exactly as Pillow's `rotate(expand=True)`; Pillow bicubic is the
  fallback when cv2 is missing. A page with no ops is pixel-identical to the
  camera decode.
- **Luminance is the only thing allowed to bake pixels**, and it is OFF by
  default (`luminance_enabled`, `NodeConfig.luminanceEnabled`). When on,
  `flush_pending_ops` bakes the chain into the work copy and marks the item
  `baked`; approval then commits `ops: []` and `ignore_lwip: true`.
- **Mat fill synthesises pixels, only outside the photo.** A tilted page near
  the photo edge keeps full padding; the rotation void inside the crop is
  recorded as a trailing `{"op":"matfill"}` and painted with surrounding
  background at preview, thumbnail and export, in the same single resample.
  Never on a side the page itself runs off (`off_frame`); that side is trimmed
  instead. LWIP config `mat_fill` (default true). Upgrade QC before LWIP.
- **The replay is ONE file, `geometry_replay.py`, byte-identical in
  `LWIP\backend\deskew_crop_tool\` and `LWCam_QC_Platform\backend\app\services\`**
  (`test_geometry_replay.py` checks parity; edit QC's copy, then copy it). QC's
  `geometry_ops.py` is a `sys.modules` alias of it.
- **Encode once covers every format.** Only a JPEG with a page is rewritten
  (lossless jpegtran trim). PNG/TIFF/BMP/JPEG XL and a page-less JPEG ship the
  source bytes with the crop recorded as ops. JPEG XL needs `pillow-jxl-plugin`.
- Order is the contract: cropping then rotating is not the same picture, so the
  list is replayed exactly as recorded.

### Other decisions

- **Volume is free text; the folder name IS the Volume.** Uniqueness holds
  because the name becomes a real directory that `TransferController._destPathFor`
  joins: compared case-insensitively (Windows does not distinguish `Register 12`
  from `register 12`); names taken by OTHER groups are reserved
  (`UploadStatsDB.reservedFolderNames`); a blank Volume is detected on the RAW
  value BEFORE sanitising (`sanitizeWindowsName('')` returns `_`).
- **Carry-over of Volume between folders is off.** One call site in
  `gallery_page.dart`.
- **Batch image operations run on threads, not processes.** Pillow releases the
  GIL; 12 deskews went 16.9 s to 3.9 s. Capped at 8 because memory binds before
  cores. `export.py` already refuses processes for small batches.
- **Preview URLs are stamped per image.** A folder-wide `updated_at` made
  editing page 12 re-render every page in the rail. Previews also `draft()` the
  JPEG decode (454 ms to 284 ms).
- **Client rework.** `revert` returns a finished folder to PENDING with
  `client_rework`, clears `is_exported`, KEEPS `group_id`, and claims it for the
  reverter. Four guards that stop double publishing each carry a rework-only
  exception: the export's adopt branch (otherwise it ships the package the
  client REJECTED), `publish_zip`/`publish_folder`, the upload sweep's UPLOADED
  skip, and `move_to_done`. `revert` is the only mutating QC endpoint that
  cannot `assert_lock_owner` (approve and reject release the lock, so a
  finished folder is never claimed). It checks the one-task-per-person rule
  BEFORE changing anything.
- **A row can outlive its file, and both repairs must work.** LWIP rebuilds a
  folder from a capture rework, so a file QC added is gone while its
  `capture_images` row lives on. A page lost that way must not strand the
  folder: the open check needs ANY readable page, `expected_image_path`
  (`routers/qc.py`) splits path resolution from the existence check, and the task
  view reports a replaced page as available through its draft copy. The traversal and
  unconfigured-folder guards stay on both paths; only `is_file` moved.
- **Pages QC adds are kept through a capture rework** (`services/qc_kept_pages.py`).
  After every commit (Save changes, Approve) QC copies each inserted or
  replaced page and `qc_ops.json` to `<qc_work_dir>\qc_kept\<folder id>\` with
  the manifest's publish marker (`created_at` + `source_fingerprint`) and
  per-file sha256. At claim time (row lock held) a changed marker, a missing
  kept page, or a missing `qc_ops.json` means LWIP republished: kept pages are
  copied back and `qc_ops.json` entries return for every page NOT recaptured
  (unsure means the edits are dropped). Restore and snapshot never raise.
  Names read from `qc_ops.json`/`kept.json` must be bare file names (they sit on
  shares and are moved as SYSTEM); store copies are written temp-then-replace
  and checked by sha256. `reject_task` refuses kept pages (400). The store is
  dropped only on split; it is deliberately kept after export. Not covered:
  pages lost before this existed, and a recapture LWIP reproduces with
  identical bytes and no QC Rework log.
- **Separation: page 1 is an implicit start.** `PUT .../separation-markers`
  takes the EXTRA start ids (an old client that sends page 1 is ignored; `[]`
  clears). The split needs at least one extra start. Pages still staged by the
  commit are written straight into their child folder (`final_target`,
  `SeparationFileTransaction(pending_names=...)`). Each child gets the parent's
  LWIP manifest narrowed to its pages (`child_manifest`).
- **`exportWorkRoot` is the export scratch root, not the image source.** Images
  come from `capture_folders.folder_path` through `to_local`. On a split site
  the work root must be LOCAL, or every export writes ~10x TIFF scratch across
  the network. `qcInputRoot` is LWIP's output.
- **Two-PC image paths.** Station Setup's "Images captured on another PC"
  (`captureImageHostPath` / `captureImageContainerPath`, read by `paths.to_local`)
  lets the capture PC record fast local paths while the QC PC maps that prefix
  onto a share. The QC console's own `qcInputRoot` is the other way.

### Conventions that look like mistakes

- `upload_summary.normalize_rework` returns the CSV's `"TRUE"`/`"FALSE"` TEXT.
  `bool("FALSE")` is True, so compare to the string.
- Hand-listed field copies silently drop new fields. Record Type was lost in
  three places that listed columns by hand (`updateCaptureFolderMetadata`, the
  New Group re-home, the export/QC title-map precedence). When you write a field
  list, ask what happens when field 15 arrives.
- `Set-Content -Encoding utf8` on Windows PowerShell 5.1 writes a BOM. A BOM in
  `pg_hba.conf` stops PostgreSQL starting, and the part reports only "could not
  reach the database server". Write config files with `UTF8Encoding($false)`.
- `pg_hba` must allow the `postgres` database, not just `lwcam`: the provisioner
  connects to the maintenance database first. `--open-lan` writes a rule that
  covers it; a hand-opened server or an older rule scoped to `lwcam` can break this.
- A switch that is read only at startup passes every unit test that starts a
  fresh object. Flip it on a running process. (That is how the `PeriodicSweep`
  bug was found: export and upload sweeps kept working after being turned off.)
- A misleading comment is worse than none. Two bugs survived because a comment
  claimed a case was handled.
- Prove a regression test fails without the fix. Twice a test passed either way.
- Python files `lwcam_secrets.py`, `tls.py`, `netlogin.py` and `geometry_replay.py`
  are copied byte-for-byte between modules; a parity test in each suite fails
  when the copies drift. Edit one, copy it, run the suites.
- Station data on an installed PC lives inside the install tree
  (`{app}\...` for the services; `1.Images`, `2.Batches`, `3.Export`,
  `4.Uploaded`, `Upload_Summary.db3` for a capture/QC site). Back it up before
  uninstalling. The PostgreSQL server survives an uninstall of the other parts.

## Throughput (measurements)

Bench on a 6-core desktop CPU, 99 real 20 MB pages (target 0.926 img/s per stage):
LWIP 2.4 img/s at 4 workers, 3.5 at 11. TIFF export converts at 2.45 img/s
(11 workers); the zip step (DEFLATE of already-compressed TIFFs, ratio 1.000)
cut that to 0.90. So the export zip now STORES `.tif`/`.tiff`/`.jpg`/`.jpeg`
members (CSVs stay deflated; 20 TIFFs: 19.7 s to 0.7 s). LWIP `workers` default is 0
(auto: logical CPUs - 1; about 410 MB peak RSS per worker, lower it on small-RAM
PCs); `exportWorkerCount` 0 is auto too. An existing install keeps the values
already written to its config.

## Config and data locations

- Capture PC: `%USERPROFILE%\LWCAM_DBs\` holds `lwcam_node_config.json` (written
  by Station Setup), `lwcam_users.json` (snapshot of users/projects, overwritten
  by every sync pull) and `lwcam_stats_<deviceId>.db`.
- QC server: `config.txt` (`<install>\config\config.txt` when installed).
- LWIP: `config\deskew_crop_config.json`, `runtime\state.json`, `logs\`.
- Upload: `config\upload_config.json`.
- Database: `config\database.txt` (setup logins, encrypted).
- Per-PC certificate authority: `%ProgramData%\LWCAM\tls`. Saved network-share
  logins: `%ProgramData%\LWCAM\network-logins\`.
- A QC server on a LAN bind with no `corsAllowedOrigins` gets no CORS; the console
  is same-origin. A dev checkout stays on loopback.

## Open work

See `docs/HANDOVER.md`. Not yet proven in the field: separate real PCs at a
real site, a real S3 bucket (the bucket half of client rework), a database-PC
reboot, an upgrade from an all-in-one station.
