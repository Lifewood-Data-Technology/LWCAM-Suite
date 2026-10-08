# AGENTS.md — LWCam suite workspace (`lwip-standalone` branch)

Guidance for Claude Code working in this repository. Each app has its own
`AGENTS.md` with its architecture; this file covers what spans them — how to
build and verify, what is already broken before you touch anything, and the
deployment traps that are not visible from the source.

This branch split off `qc-platform` at `67d90e7` (2026-09-25) to give LWIP its
own installer and its own machine; it inherits everything below up to that
commit, plus the four-installer split described under Deploying.

**Layout on `qc-platform` (since 2026-09-23), carried over here:** the apps sit at the repository
root — `LWCAM\`, `LWCamAdmin\`, `LWIP\`, `LWCam_QC_Platform\`, `LWCam_Upload\`,
`installer\`, plus `verification\` and `docs\`. Every other branch still nests them under
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

## The five modules

| Path | What it is |
| --- | --- |
| `LWCAM` | Flutter Windows capture app. Capture and the rework recapture list. **No QC** since Phase 8 (2026-09-22): the review screens and the local engine are gone. **No LWIP** since 2026-09-25: LWIP is its own installer and boot-time SYSTEM service on its own PC, reports to PostgreSQL itself (`cloud_report.py`), and LWCAM neither starts/stops it nor reads its `state.json` any more — `ProcessingBootstrap`, `ProcessingReportService` and `LwipService` are deleted. |
| `LWCamAdmin` | Flutter Windows SuperAdmin app. Owns Station Setup, which writes the capture station's config (`lwcam_node_config.json`) and (since 2026-09-25) only TESTS the database connection — creating/upgrading the schema is `LWCamDatabaseSetup`'s job, and Station Setup no longer configures or starts LWIP either. Since 2026-09-28 it has no LWIP fields at all: LWCAM's rework finds a recapture's original under the image destination (`rework_service.dart`). No QC, upload or AI settings since 2026-09-23 — the QC server owns those. |
| `LWIP` | Deskew/crop/thumbnail engine, its own product at the repository root since 2026-09-25 (no longer nested under `LWCAM`). Runs as its own boot-time SYSTEM service on its own machine and reports each finished folder straight to PostgreSQL itself (`backend/deskew_crop_tool/cloud_report.py`). **Start with `LWIP/README.txt`.** |
| `LWCam_QC_Platform` | **QC as a standalone LAN server** — FastAPI backend plus the Vue console it serves from `frontend/dist`. Review, approve, reject, separation, client rework, export, admin settings. It talks to LWCAM only through the database. **Start with `LWCam_QC_Platform/AGENTS.md`** for anything QC. |
| `LWCam_Upload` | The S3 upload phase, moved out of the QC server into its own app: a SYSTEM boot task that watches QC's output folder, uploads with size-verified logic, keeps its own ledger, and serves its own console (status, paths/S3 settings, live log). |

Plus `installer\`, which builds the installers for all of the above.

All five share one PostgreSQL schema. Column ownership is strict and enforced by
convention only — see the table in `LWCam_QC_Platform/AGENTS.md`.

**Upload is its own service since 2026-09-25**: `LWCam_Upload/` (LWCamUploadSetup,
the "LWCam Upload" boot task) watches QC's output folder, sends each published
package to S3 verified by size, writes `Upload_Summary.db3` and moves the
package to the Uploaded folder. Its settings are its own
`config\upload_config.json`, edited from its console on port 8091, which also
shows status, failures and a live log. QC no longer uploads and has no upload
settings (until 2026-09-25 this was `LWCam_QC_Platform/backend/app/services/upload.py`).

**The QC server owns all its settings** in its own `config.txt` (DB login, JWT
secret, bind address/port, folders, AI) and reads nothing from LWCam
Admin — `LWCam_QC_Platform/AGENTS.md` has the key list. The two apps share only
the database, whose schema only `LWCamDatabaseSetup` now creates and upgrades,
running the same `LWCam_QC_Platform/scripts/setup_qc_db.py` (`--server-config`)
— neither QCPlatformSetup nor LWCam Admin provisions it any more.

## Gates, and the baseline they must beat

Run these before claiming anything works. **The numbers on the right were
measured on 2026-09-25 on this branch — several failures are pre-existing and
chasing them wastes a session.**

```bash
cd LWCAM        && flutter analyze && flutter test     # 5 infos, 442 pass (2026-09-30)
cd LWCamAdmin   && flutter analyze && flutter test     # clean,   136 pass (2026-09-30)
cd LWCam_QC_Platform/backend && C:\Python314\python.exe -m unittest discover -s tests -t .
                                                       # 375 total (pytest, 2026-10-05): 372 pass, 2 skip, 1 fail - test_secrets parity, only in a sparse worktree that hides LWIP; 0 fail on the full tree
cd LWCam_QC_Platform/frontend && npm run build         # vue-tsc --noEmit && vite build
cd LWIP/backend        && C:\Python314\python.exe -m unittest discover -s tests
                                                       # 206 run, 2 fail, 1 skipped (2026-09-30)
cd LWCam_Upload/backend && C:\Python314\python.exe -m unittest discover -s tests
                                                       # 143 pass (no real S3 or DB; 2026-09-30)
```

(The QC backend count is the same whether collected by `unittest` or by
`pytest` — the 4 skips are `test_setup_qc_db.py` tests that need a reachable
local PostgreSQL.)

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
- **LWIP: 2 failures**, the negative controls in `test_long_paths.py`
  (`test_a_long_path_is_writable_only_through_fs_path`,
  `test_the_same_folder_fails_without_the_guard`): they expect a long path to
  FAIL without the `\\?\` guard, and on this PC it succeeds — long paths are
  enabled for this Python. The 1 skip (`test_non_windows_is_untouched`) is
  POSIX-only and expected on Windows.

If a count changes, that is yours. **Establish the baseline before concluding a
failure is pre-existing.** The stash stack is shared by every worktree and by
other sessions, so prefer a detached worktree of `HEAD`
(`git worktree add --detach <dir> HEAD`, run, `git worktree remove`) or a WIP
commit over `git stash`.

**The shipped runtime imports the INSTALLED backend, not your worktree.** Moot
while nothing is installed here; it comes back with the next install. Its
`runtime\python\python314._pth` hardcodes `..\..\backend` — that is
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

LWIP is no longer one of these: since 2026-09-25 LWCAM neither launches nor
supervises it (`resolveLwipRoot` and the services that called it are deleted),
so a LWCAM dev build needs no LWIP runtime beside it at all — LWIP runs, if at
all, as its own installed service on its own PC.

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
cd installer  && powershell -File build-installer.ps1 -Target All   # or Database / QC / LWIP / LWCam
```

**Five installers on `upload-standalone` (2026-09-25):** the four below plus
`LWCamUploadSetup.exe` (`Upload.iss`) — the S3 upload phase moved OUT of the QC
server into `LWCam_Upload\` (`b09b179`, `0806ae3`, `7efc6ee`): the "LWCam
Upload" SYSTEM boot task watches QC's output folder, uploads with QC's old
size-verified logic, keeps its own ledger with a per-package fingerprint so a
client-rework republish is uploaded again, and serves a console on 8091
(status, paths/S3 settings, live tagged log; same sign-in and DB-down local
fallback as the LWIP console). QC no longer has upload settings; an old
config.txt's upload* keys are ignored and dropped on the next Settings save,
so an upgraded site must enter its S3 details in LWCamUploadSetup. Tested on
this PC with real boto3 against a fake bucket (403 -> FAILED + back-off,
Retry, no secrets logged); a real bucket upload is unproven here.

**Four installers since 2026-09-25** (`installer/README.txt` has the detail).
Site install order: `LWCamDatabaseSetup` first (once, on the database PC),
then `QCPlatformSetup` and `LWIPSetup` (once each, on their own PCs, in either
order), then `LWCamSetup` on every capture PC — each of the other three needs
the database login `LWCamDatabaseSetup`'s finish page shows, and `LWCamSetup`/
`QCPlatformSetup` also need LWIP's output folder from `LWIPSetup`'s finish page.

- `LWCamDatabaseSetup.exe` (`Database.iss`) — the only installer that can
  install PostgreSQL (or use an existing server); creates/upgrades the schema
  with `setup_qc_db.py`, and optionally opens a local server to the LAN
  (`--open-lan` + firewall rule "LWCam Database"). Writes the login to a
  private `config\database.txt`, shown on the finish page.
- `QCPlatformSetup.exe` (`QCPlatform.iss`) — the QC server + console. Writes
  `{app}\config\config.txt` (private folder; fresh CSPRNG `jwtSecret`,
  `bindHost = 0.0.0.0`) on a fresh install, asking for a database that must
  already exist — it no longer installs PostgreSQL or runs `setup_qc_db.py`.
  Registers the "LWCam QC Server" task at system start as SYSTEM, and opens the
  configured port in the firewall (Domain + Private).
- `LWIPSetup.exe` (`LWIP.iss`) — LWIP as its own offline Python runtime, run by
  the "LWCam LWIP" scheduled task (SYSTEM, at boot). Writes a private
  `config\deskew_crop_config.json` (input/output folders, plus the database
  login LWIP now reports to directly via `cloud_report.py`). No firewall rule —
  LWIP listens on no port.
- `LWCamSetup.exe` (`LWCam.iss`) — LWCAM + LWCam Admin only, no LWIP and no
  PostgreSQL flow. Keeps the old LW Suite AppId, so an all-in-one station
  upgrades in place: an old `{app}\LWCAM\LWIP`, an old all-in-one `{app}\QC`
  engine, and `{app}\Database` are all stopped and removed, and the old
  per-user LWIP logon Run key is deleted. LWCam Admin is Start-menu only.

Only `LWCamDatabaseSetup` ships the PostgreSQL exe (`installer/postgres.iss`,
now included only by `Database.iss`); the other three no longer touch it.
`PythonProcessesUnder` and `RestrictToAdmins` moved into `installer\common.iss`
(`7756ff5`), included directly by `LWIP.iss`/`QCPlatform.iss`/`LWCam.iss` and,
for `Database.iss`, through `postgres.iss`. Every installer that runs a
background process still stops it in `PrepareToInstall` and aborts if it
survives, and secrets are still written only into files already restricted to
SYSTEM + Administrators. **None of the four has been built into a `.exe` or
test-installed yet** (2026-09-25) — see "State of play" below.

`C:\Program Files\LW Suite\` **needs elevation** — plain `cp` fails. Either
rebuild the installer or copy with elevation.

`-ScrcpyDir` is optional. The script takes `LWCAM/scrcpy` (gitignored, like
`LWIP/wheels/`) whenever it holds a `scrcpy.exe` — the same folder
`LWCam.iss`'s own `#ifndef` default names; winget's package is only the
fallback. The gitignored inputs (vendor zip, vcruntime, adb, wheels, jpegtran,
scrcpy, the PostgreSQL exe) are listed in `installer/README.txt`; on this
station they were copied from the `Source` worktree.

Outputs land at the repository root: `LWCamDatabaseSetup.exe`,
`QCPlatformSetup.exe`, `LWIPSetup.exe` and `LWCamSetup.exe`, all ignored by
`*.exe`. Only `LWCamDatabaseSetup.exe` needs the PostgreSQL exe beside it —
`build-installer.ps1` copies the newest staged
`postgresql-18.*-windows-x64.exe` next to it for that target; the other three
ship without it. **Ship `LWCamDatabaseSetup.exe` together with the PostgreSQL
exe** — see Station facts.

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
never by name (`PythonProcessesUnder`, now in `installer\common.iss`), so
unrelated Python survives. `LWCamSetup` drains an all-in-one station's old
LWIP gracefully first (stop file, 90 s) before removing `{app}\LWCAM\LWIP` and
an all-in-one `{app}\QC`; `QCPlatformSetup` and `LWIPSetup` each end their own
scheduled task and restart it after the upgrade.

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
- **A tilted page keeps `crop_padding` of REAL background in the delivered
  TIFF** (since 2026-09-24, master `94ff454` + `0258dda`). The lossless trim is
  the pre-image of the FINAL straightened crop (page + padding) plus
  `RESAMPLE_REACH` (8 px, the export's Lanczos4 reach), and
  `_clamp_to_rotated_frame` pulls in only the side that runs off the photo,
  keeping 8 px clear. Before, the trim was the unrotated page + padding, the
  rotation's corner wedges landed in the padding and a uniform shrink cost all
  four sides: 80-125 px margins, and a page cut on one capture. Straight pages
  are unchanged (the exact `cv2.boundingRect` box). The tilted trim is
  slightly larger on disk. Only new captures are affected.
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
  folder LWIP republishes, so a capture rework wipes it - but QC keeps its own
  copy (`qc_kept_pages.py`, see "Pages QC adds are kept" below) and puts back
  the entries of every page that was not recaptured.
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
- **Mat fill is the one exception that SYNTHESISES pixels, and only outside
  the photo** (2026-10-06, ported from `lwip_deskew_crop_v2.py`). A tilted
  page close to the photo edge keeps its full padding; the rotation void that
  leaves inside the crop is recorded as a trailing `{"op":"matfill"}` and
  painted with surrounding background at preview/thumbnail/export, in the
  same single resample. Never on a side the page itself runs off
  (`off_frame` - there the void lands on the page, so that side alone is
  trimmed, by the wedge width + `RESAMPLE_REACH`). Per page in the manifest
  (`mat_fill`). LWIP config `mat_fill` (default true); false = the old
  trim-every-side behaviour. Upgrade QC before LWIP at a site.
- **The replay is ONE file, `geometry_replay.py`, byte-identical in
  `LWIP\backend\deskew_crop_tool\` and `LWCam_QC_Platform\backend\app\services\`**
  (`test_geometry_replay.py` checks parity; edit QC's copy, then copy it).
  QC's `geometry_ops.py` is a `sys.modules` alias of it (tests patch
  `geometry_ops.cv2`); LWIP's `image_ops.apply_qc_ops` calls it. Before
  2026-10-06 LWIP's thumbnail had its own copy that lacked `rotate`.
- **Encode once covers every format.** Only a JPEG with a page is rewritten
  (lossless jpegtran trim); PNG/TIFF/BMP/JPEG XL and a page-less JPEG ship
  the source bytes with their crop recorded as ops. JPEG XL needs
  `pillow-jxl-plugin` (staged in both wheels folders with `packaging`).

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

**A row can outlive its file, and both repairs must work.** LWIP rebuilds the
folder from a capture rework (fresh directory, swapped in), so a file QC added
is gone while its capture_images row - which LWIP never touches - lives on.
Pages added or replaced since 2026-10-02 are kept (next paragraph); a page
lost any other way (or before that) is repaired by Replace or Delete, so it
must not strand the folder: `canOpenQcTask` needs ANY readable page rather than
every one, `expected_image_path` splits path resolution from the existence
check so the commit can delete or replace a page whose file has gone, and the
task view reports a replaced page as available through its draft work copy
(the Approve button waits on that). The traversal and unconfigured-folder
guards stay on BOTH paths; only `is_file` moved. Rotate/crop/luminance on a
missing page still answer a clear 404.

**Pages QC adds are kept through a capture rework** (`services/qc_kept_pages.py`,
2026-10-02; supersedes "a rework wipes them - correct"). LWIP is unchanged and
still refuses extra files. After every commit (Save changes, Approve) QC copies
each inserted/replaced page and `qc_ops.json` to
`<qc_work_dir>\qc_kept\<folder id>\` with the manifest's publish marker
(`created_at` + `source_fingerprint`) and per-file sha256. At claim time
(`claim_task` / `claim_next`, row lock held) a changed marker means LWIP
republished - the fingerprint alone is not enough, it describes LWIP's INPUT
and stays the same when LWIP rebuilds because adoption failed - and so does
the folder missing a stored kept page, or `qc_ops.json` missing while the
store has entries. A snapshot first restores when those signals hold, so it
never overwrites the good copy with a rebuilt state. Kept pages are copied back (thumbnails rebuilt; a cross-format replace retires the
`lwip_name` file LWIP produced into `qc_deleted\<id>\republish-*`), and
`qc_ops.json` entries come back for every page that was NOT recaptured -
recaptured = its manifest sha256 changed OR a `QC Rework` rework_logs row is
newer than the snapshot; unsure means the edits are dropped. Restore and
snapshot never raise (a failure is logged and the folder still opens). Entries
for added pages carry `kept` (`inserted`/`replaced`) and `lwip_name`, and keep
them through restore-original or a later bake (`ignore_lwip` is forced on); a
luminance bake of an ordinary LWIP page does not make it kept. Entries written
before the tag existed are recognised by LWIP's manifest instead (a page not in
`files[]` was added in QC) - never by `ignore_lwip` alone, which baked LWIP
pages carry too. Names read from `qc_ops.json`/`kept.json` must be bare file
names (they sit on shares and end up in moves done as SYSTEM); store copies
are written temp-then-replace and checked by sha256 before restoring.
`reject_task` refuses kept pages (400 "Pages added or replaced in QC can't be
sent for recapture — replace the page again instead."), reading the store
as well as `qc_ops.json`. The store is dropped only when the folder is
split; it is deliberately KEPT after export (a client rework can become a
capture rework, and nothing prunes it - it holds only QC-added/replaced pages).
`reject_task` snapshots just before the status flips, so a reverted folder
nobody saved is covered, and it names the rejected pages in the store
(`recaptured`, their edits left out of the copy - no clock involved; the
rework-log check, millisecond-tolerant, is only the fallback for older stores;
the list is cleared once a genuine republish is restored). A snapshot does not
re-hash a kept page whose size and mtime match its record. A restore only fills what is missing (existing
`qc_ops.json` entries are newer than the snapshot) and overwrites an existing
kept page only when the publish marker changed. Not covered: pages already lost before this shipped (no copy exists),
and a recapture that LWIP reproduces with identical bytes and no QC Rework log.

**Separation: page 1 is an implicit start.** `PUT .../separation-markers` takes
the EXTRA start ids (0..n), stores them without the first page (an old client
that still sends it is ignored) and `[]` clears; the split needs at least one
extra start, and a mark that a reorder put on page 1 means no split. The task
view's `separationStart` is true for page 1 only while another start exists.
In the same save as the split, pages still staged by the commit (inserted,
cross-format replaced) are written straight into their child folder
(`final_target`, `SeparationFileTransaction(pending_names=...)`); before
2026-10-02 an insert plus a split in one Save failed in preflight and a
replace landed in the emptied parent.

**`exportWorkRoot` is the export SCRATCH root, not the image source** (it was
called `qcInputRoot` until 2026-09-24, which everyone misread; `qcInputRoot` now
means LWIP's output, the old `qcImagesRoot` — `LWCam_QC_Platform/AGENTS.md` has
the rename and how old files are read). Images come from
`capture_folders.folder_path` through `to_local`. On a split site the work root
must be LOCAL, or every export writes ~10x TIFF scratch back across the network.

### Two-PC sites (capture PC hosts the database, QC/export PC connects)

- The **"use an existing server"** task now lives only in `LWCamDatabaseSetup`
  (`postgres.iss`'s `remotedb` task, included only by `Database.iss`): "Use an
  existing PostgreSQL server (on this PC or another) instead of installing
  one." Ticking it makes `NeedsPostgreSql` false there, so no server is
  installed and `PrepareToInstall` stops demanding the PostgreSQL exe.
  `LWCamSetup` no longer has this task or the PostgreSQL flow at all — it never
  writes `station-seed.json` any more (removed with LWCam.iss's old
  provisioning code; only its `[UninstallDelete]` entry, cleaning up an older
  install's copy, remains).
- Station Setup gained **"Images captured on another PC"** -
  `captureImageHostPath` / `captureImageContainerPath`, mapped through the node
  config and read by `paths.to_local`. This lets the capture PC keep recording
  fast local paths while the QC PC maps that prefix onto a share, instead of
  making the capture PC write UNC paths and pay SMB on its own writes. The
  console's own `qcInputRoot` (`config.txt`) is the other way to do the same.
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
- **`pg_hba` must allow the `postgres` database, not just `lwcam`.** The
  provisioner connects to the maintenance database first, to see whether
  `lwcam` exists — you cannot connect to a database in order to create it. This
  is now `LWCamDatabaseSetup`'s concern, not Station Setup's: its `--open-lan`
  ("Allow other PCs on this network to connect") writes
  `host all all samenet scram-sha-256` to `pg_hba.conf`, and the `all` covers
  every database including `postgres`, so this trap should no longer bite —
  but a server opened to the LAN by hand, or an older `pg_hba.conf` line
  scoped to `lwcam` only, still can.
- **`upload_summary.normalize_rework` returns the CSV's `"TRUE"`/`"FALSE"`
  TEXT.** `bool("FALSE")` is True, so a bool() check reads every package as a
  rework and overwrites unconditionally. Compare to the string.
- **Hand-listed field copies silently drop new fields.** Record Type was lost in
  THREE separate places that enumerated columns by hand instead of copying the
  model - `updateCaptureFolderMetadata`, the New Group flow's re-home, and the
  export/QC title-map precedence. If you are writing a field list, ask what
  happens when field 15 arrives.

## State of play (2026-09-25)

The QC platform's own state — what was exercised on the console, test folders,
and its open list — is in `LWCam_QC_Platform/AGENTS.md`. What spans the apps:

**2026-09-30: one shared database login replaces the five per-part logins.**
`LWCamDatabaseSetup` asks for database name, port, user and password on one
page (defaults `lwcam` / 5432 / `lwcam_user`; password >= 12 chars, typed
twice; on a re-run prefilled from `config\database.txt`, blank keeps it) and
stores `appUser` / `appPassword` / `dbName` / `dbPort` there beside the
`postgres` login; `logins.txt` is no longer written. The password reaches
`setup_qc_db.py --app-login` only through the `LWCAM_APP_PASSWORD` environment
variable (`Win32SetEnv` in `Database.iss`, read by `SETUP_DATABASE.bat`, which
falls back to database.txt when run by hand). Silent: `/APPDB /DBPORT /APPUSER
/APPPASSWORD` (no default password). The chosen port goes to the EDB installer
(`--serverport {code:GetPgPort}` in `postgres.iss`), the firewall rule and
database.txt; a port already listening is refused on a fresh install. QC, LWIP
and Upload installers got a Database name field (`/DBNAME`, default `lwcam`)
and user default `lwcam_user`, written as `dbName` / `db_name`;
`ValidateDbPage` in `common.iss` now has five fields. Not built into a
running install here; compiled with ISCC only.

**2026-09-30: multi-PC hardening (round 2).** Core rule: the database, QC,
LWIP, Upload and every capture PC may be different machines on a LAN or
Tailscale, with different clocks and shares reached through saved logins, and
any of them may be off - so nothing waits on a remote host without a timeout,
everything queues and retries, and the QC console's **System status** page
shows it (green / red / grey; QC, QC export, LWIP, Upload and backup are
"never reported" red until they report; capture PCs are informational - grey
when off, red only for held/old unsent records or an error; ages come from the
DB's own `now()`; "Forget this PC" deletes a stale row, `lwcam_qc` has DELETE
on `service_heartbeat`). What changed, by area:

- **Schema level 8** (`008_hardening.sql`): QC needs 8, every other part 7.
  `lwcam_qc` lost CREATE on `public`; export numbers come from
  `public.lwcam_next_export_number(bigint)` (SECURITY DEFINER). The DB PC's
  `LWCamDatabaseSetup` must therefore run BEFORE any QC upgrade.
  `setup_qc_db.py`: `--create-roles` refuses a lost `logins.txt`
  (`--reset-missing-roles` is never passed by the installer);
  `--strict-logins` refuses while a non-part login is connected from another PC
  or a broader non-TLS `pg_hba` line remains (`--force-strict` overrides only
  the first); migrations 006-008 are one transaction with a 30 s lock timeout.
- **Installers (`installer\`)**: `Database.iss` locks `{app}` (new
  `SetExactAcl`/`LockProgramFolder` in `common.iss`: Set-Acl with read-back, so
  other explicit grants are removed; trailing backslashes stripped) BEFORE it
  registers the SYSTEM backup task, refuses an unlockable folder; rewrites a
  kept `database.txt` (old copy `.bak-<time>`) when PostgreSQL was reinstalled;
  backup page refuses drive roots/system folders/foreign non-empty folders;
  "Run a backup now" default ticked; `strictlogins` requires `openlan`; the
  finish page shows setup_qc_db's `[ERROR]` line. `LWCam.iss` deletes old
  `station-seed.json`/`postgres-password.txt`. `build-installer.ps1` appends
  `-dirty` to the build id when the tree is dirty and runs `npm ci` first.
- **Backup/restore**: `backup_db.py` also writes
  `lwcam-globals-YYYYMMDD-HHMM.sql` (`pg_dumpall --globals-only`, the roles and
  their hashes), pruned with the dumps; `--tool NAME` prints the newest pg tool
  and `--safety-dump` writes `pre-restore-*.dump`. `RESTORE_DATABASE.bat` uses
  those, needs `fltmc` elevation, aborts if the safety dump fails, restores with
  `--single-transaction`, stops/restarts only the LWCam tasks that are running.
- **Web consoles are https-only** (`tls.py`, one copy per service, trusted per
  viewing PC; Firefox has its own store). With the database down they are
  read-only (a local browser sees status; a saved admin list lets a prior admin
  in); a capture PC's marker carries `image_count` and LWIP waits for that many
  images; the capture DB password is stored DPAPI-protected
  (`pgPasswordProtected`).
- **Docs**: `installer\README.txt` has the site upgrade order ("Upgrading a
  multi-PC site"), status page, held records / Try again, schema-gate messages,
  strictlogins guidance and the rebuild-on-new-hardware recipe; `LWIP\README.txt`
  and `LWCam_Upload\README.txt` describe https and DB-down behaviour.
- **Unproven here** (nothing was installed on this PC): the new `SetExactAcl`
  with `Users:RX` on a real Program Files folder, the restore script elevated,
  and a live multi-PC upgrade. The installers compile; `QCPlatformSetup.exe`
  was compiled with ISCC directly (BuildId `test`), not through the script.

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

- **2026-09-25: LWIP split into its own installer + service.** Six commits
  `7756ff5..447eeed` give the suite four installers instead of two
  (`LWCamDatabaseSetup`, `QCPlatformSetup`, `LWIPSetup`, `LWCamSetup`; see
  Deploying above and `installer/README.txt`), move LWIP's settings and DB
  login into its own `deskew_crop_config.json`, have LWIP report each finished
  folder to PostgreSQL itself (`cloud_report.py`), and delete LWCAM's
  `ProcessingBootstrap`/`ProcessingReportService`/`LwipService` and LWCam
  Admin's LWIP autostart/config-writer services. Gates: LWCAM analyze 5 infos /
  407 pass, LWCamAdmin analyze clean / 93 pass, QC backend 203 (199 pass, 4
  skip), LWIP 77 run / 2 fail / 1 skip. **All four `.exe` files built
  2026-09-25 12:01** (`build-installer.ps1 -Target All`: Database 18 MB, LWIP
  78 MB, QC 104 MB, LWCam 32 MB — LWCam was ~103 MB with LWIP inside). **Not
  yet test-installed** — next step is test-installing `LWCamDatabaseSetup` +
  `LWIPSetup` on this PC (ask the user first). A worktree made by copying
  another's folder carries that folder's `build\windows` CMake cache and
  `windows\flutter\ephemeral\.plugin_symlinks` — both break
  `flutter build windows` until deleted (they are regenerated).
- **LWIP console** (2026-09-25, `a2b1867` + `7429574`): the service runs
  `deskew_crop_tool.service`, a supervisor that serves a web page on
  `ui_port` (8090) and runs the worker as a child — status, queue, log tail,
  settings (validated by `load_config`, password write-only), save = restart.
  Sign-in: active Admin/SuperAdmin DB accounts (QC's bcrypt check and rate
  limit). DB unreachable ⇒ a browser ON the LWIP PC (Host `localhost` too) may
  edit without signing in; other PCs read-only. LWIP suite now 105 run / 2
  fail / 1 skip. Run end to end on this PC against scratch folders and the
  local DB (processing, clean stop, local fallback, save-and-restart,
  rebinding guard); `LWIPSetup.exe` rebuilt (74.7 MB). Real sign-in with an
  admin account and the installed task are not yet exercised.
- **The installer split is built and reviewed but not test-installed**
  (2026-09-23/24: the QC server owns its settings, the console edits upload and
  AI, Station Setup lost its QC sections, two installers). Neither installer has
  been run on a PC; the scheduled task at boot, the firewall rule, the private
  config folder and an all-in-one upgrade are proven only by review and by
  scratch tests of the permission helper.
- **LAN access** is installer-configured (`bindHost = 0.0.0.0`, firewall rule on
  Domain + Private networks). A dev checkout stays on loopback. A LAN bind with
  no `corsAllowedOrigins` gets no CORS — the console is same-origin.
- **Upload status** has no console screen (see "The five modules"). Also
  untested: the bucket half of client rework (the same Group ID replacing the
  package in S3 and in `4.Uploaded`); upload is off here and no bucket is set.
- **Capture rework cannot be exercised on this station** — no camera, no LWIP
  install.

## Station facts

- Config: `%USERPROFILE%\LWCAM_DBs\` — `lwcam_node_config.json` (LWCAM's PG
  credentials and paths; its old QC/upload/AI/LWIP-provisioning fields are kept
  only so the file round-trips), `lwcam_users.json` (the snapshot LWCAM
  authenticates against), `lwcam_stats_<deviceId>.db`. The `lwip/` runtime +
  journal here is now only what an **old all-in-one** station wrote — a
  standalone `LWIPSetup` install keeps its own `config\deskew_crop_config.json`,
  `runtime\state.json` and `logs\` under `{app}` instead
  (`installer/README.txt` explains copying `state.json` across when a new
  install takes over folders an old one already processed). The QC server's
  settings are `LWCam_QC_Platform\config.txt` (gitignored; on this station it
  carries the DB login and JWT secret copied from the node config).
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

## Throughput (2026-10-07)

Bench on i5-12400F, 99 real 20 MB pages (target 0.926 img/s/stage): LWIP 2.4
img/s at 4 workers, 3.5 at 11; TIFF export converts at 2.45 img/s (11 workers)
but the zip tail (DEFLATE of already-compressed TIFFs, ratio 1.000) cut it to
0.90. Changes: export zip now STORES .tif/.tiff/.jpg/.jpeg members (CSVs stay
deflated; 20 TIFFs zip step 19.7 s -> 0.7 s); LWIP `workers` default 4 -> 0
(auto, logical CPUs - 1; ~410 MB peak RSS per worker, lower it on small-RAM
PCs); `exportWorkerCount` was already 0 = auto. Existing installs keep their
written config values.
