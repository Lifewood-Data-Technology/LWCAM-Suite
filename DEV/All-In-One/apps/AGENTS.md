# AGENTS.md — LWCAM All-In-One workspace

Guidance for Claude Code working in this workspace. Each app has its own
`AGENTS.md` with its architecture; this file covers what spans them — how to
build and verify, what is already broken before you touch anything, and the
deployment traps that are not visible from the source.

`START-HERE.md` (one level up) is the operator-facing setup guide. This is the
developer one.

This file lives in the repository so it travels with the code. The `AGENTS.md`
at the root of the `Dev` work tree — one level ABOVE the repository, so not
tracked here — is a pointer, not a duplicate: Claude Code walks upward from the
working directory and loads every `AGENTS.md` it passes. Edit THIS file; the
pointer describes the folder layout and never needs to change.

## The three apps

| Path | What it is |
| --- | --- |
| `apps/LWCAM` | Flutter Windows capture app. Also hosts **QC review** since the Vue console stopped shipping. Bundles **LWIP** (`apps/LWCAM/LWIP`), a Python deskew/crop/thumbnail watcher. |
| `apps/LWCamAdmin` | Flutter Windows SuperAdmin app. Owns Station Setup, which writes every station config file. |
| `apps/LWCam_QC_Platform` | FastAPI backend + a Vue frontend that is **no longer shipped** (`LWSuite.iss:35`). The backend still runs; the frontend survives only as the reference for the Flutter QC port. |

All three share one PostgreSQL schema. Column ownership is strict and enforced by
convention only — see the table in `apps/LWCam_QC_Platform/AGENTS.md`, which
exists on the `qc-platform`, `usa-demo` and `color-cal` branches. This branch
carries no per-app doc for it.

## Gates, and the baseline they must beat

Run these before claiming anything works. **The numbers on the right are the
current, known-good state — several failures are pre-existing and chasing them
wastes a session.**

```bash
cd apps/LWCAM        && flutter analyze && flutter test    # 6 infos, 585 pass
cd apps/LWCamAdmin   && flutter analyze && flutter test    # clean,   131 pass
cd apps/LWCam_QC_Platform/backend && .venv/Scripts/python.exe -m pytest -q
                                                           # 8 fail, 338 pass
cd apps/LWCAM/LWIP/backend && ../venv/Scripts/python.exe -m unittest discover -s tests
                                                           # 1 fail,  29 pass
```

**Known-failing before any change:**

- **LWCAM `flutter analyze`: 6 `curly_braces_in_flow_control_structures` infos** in
  `box_session_controller.dart`, `box_integrity.dart`, `pg_sync_sink.dart`,
  `transfer_queue_service.dart`.
- **QC backend: 8 failures** in `test_ai_review`, `test_qc_separation`,
  `test_reset_test_db`, and one `test_export` case. Verified pre-existing by
  stashing changes and re-running.
- **LWIP: 1 failure**, `test_config_resolves_relative_paths_from_project_root` —
  an 8.3 short-path artifact (`CAMCAP~1`) of the shell's `TMP`. Fails identically
  on pristine `HEAD`.

If a count changes, that is yours. **Establish the baseline by stashing before
concluding a failure is pre-existing** — `git stash push -- <paths>`, run, pop.

## Running a dev build: bundled runtimes are NOT beside it

This cost three separate debugging sessions. `flutter build windows --debug`
produces `apps/LWCAM/build/windows/x64/runner/Debug/lwcam.exe`, and **the things
it shells out to live next to the INSTALLED exe, not the built one**:

| Needs | Resolver | Fix for a dev build |
| --- | --- | --- |
| `adb.exe` (+ `AdbWinApi.dll`, `AdbWinUsbApi.dll`) | `gallery_page.dart:_resolveAdbPath` — exe dir, cwd, `C:\Android\platform-tools`, PATH | copy from `C:\Program Files\LW Suite\LWCAM\` into the Debug folder |
| `scrcpy` | `scrcpy_service.dart:resolveScrcpyExe` — walks 7 levels up looking for `scrcpy/scrcpy.exe` | `mklink /J scrcpy "C:\Program Files\LW Suite\LWCAM\scrcpy"` in the Debug folder |
| LWIP runtime | `lwip_autostart_service.dart:resolveLwipRoot` — needs `runtime/python/pythonw.exe` **and** `backend/deskew_crop_tool` | the repo tree has the old `venv/` layout, so it does not resolve; run `SETUP_DESKEW_CROP.bat` or ignore |

Without `adb` every capture symptom appears at once — no crop, dead shutter, no
images detected — because all three are adb calls. `build/` is gitignored, so
none of this pollutes the repo, but **`flutter clean` deletes it all**.

Debug builds relink the runner exe only when native code changes: after a Dart-only
change the **exe timestamp stays old and `data/flutter_assets/kernel_blob.bin` is
what updates**. Check that, not the exe.

## Verifying a build actually contains a change

String-searching a build is valid but easy to get wrong — three false alarms this
session:

- `strings` finds nothing in `app.so`; use `grep -a` (raw bytes).
- Interpolated Dart strings are stored as fragments — `'Page ${i} of ${n}'` never
  appears as `Page 1 of 3`. Search a literal fragment.
- The installer is LZMA-compressed; `grep` on `LWSuite.exe` proves nothing. Read
  the ISCC compile log instead.
- **Always check a control string** that certainly exists before trusting a
  negative result.

Release builds put Dart in `data/app.so`; debug builds in `kernel_blob.bin`.

## Deploying

`C:\Program Files\LW Suite\` **needs elevation** — plain `cp` fails. Either
rebuild the installer or copy with elevation.

```bash
cd apps/LWCAM      && flutter build windows --release
cd apps/LWCamAdmin && flutter build windows --release
cd apps/installer  && powershell -File build-installer.ps1
```

`-ScrcpyDir` is optional. The script takes `apps/LWCAM/scrcpy` (gitignored,
like `LWIP/wheels/`) whenever it holds a `scrcpy.exe` — the same folder the
`.iss`'s own `#ifndef` default names, so the script and a bare
`ISCC LWSuite.iss` build the same thing; winget's package is only the fallback
for a checkout without one. It used to be required here, because winget's
scrcpy is not installed on this PC.

It prints TWO outputs: `LWSuite.exe` (~150 MB) and, copied next to it,
`postgresql-18.6-1-windows-x64.exe` (359 MB). **Ship both together** — see the
PostgreSQL bullet under Station facts for why it is no longer inside the
installer.

The installer bundles the **Release** builds and the repo's LWIP and QC backend
trees, so backend changes ship automatically — but stale Release builds ship
silently. Check `data/app.so` timestamps against `lib/` before compiling.
**Building only `--debug` and then reinstalling ships the previous Release** —
that happened once and looked exactly like the installer not picking changes up.

**Setup stops a running QC engine before copying** (`StopQcBackend` in
`LWSuite.iss`, at `ssInstall`). Without it an upgrade left the logon-started
backend alive: setup overwrites the backend's `.py` underneath it, the process
keeps serving the code it imported at startup, and the station looks freshly
installed while running the previous engine — no error anywhere. Restart Manager
cannot catch it, since Python closes a `.py` after reading it and holds no lock,
which is also why the overwrite succeeds silently. Processes are matched by
COMMAND LINE against `{app}\QC`, never by name, so a station's other Python —
LWIP's twenty workers among them — is untouched. Nothing restarts it: Station
Setup's save is what rewrites the logon launcher and starts it, and that save is
required after an upgrade anyway, so setup says so in a message shown only when
it actually stopped one. **Since 2026-09-04 that save also stops a running
engine first** (`stopQcBackend`, same command-line match), because the engine
reads its config once at import and a start-only save left the old process
serving old settings. **LWIP is deliberately not stopped** — it is a worker
mid-folder rather than a server, so killing it needs its journal thought through
first.

## You are on the `taiping` release branch

Branched from `d6182f0` - the exact tree the **South Africa DoD** installer was
built from, and the only tree that had run in production. It is NOT `fsi-demo`,
which carries the general/template-v3 version. **Never merge this branch into
`fsi-demo`**; that would drag the general version backwards.

It exists because the Taiping All Saints Church project needed the DoD build
plus a few specific changes, on a one-day deadline, and `fsi-demo` has never
been run on a station (see its own "State of play"). It has since grown well
past those three changes - everything below landed on 2026-09-06/07, and every
line of it was driven by testing on a real station.

Deliberately absent, still: the template library, arbitrary fields, per-project
PostgreSQL schemas, per-project S3 targets and export sub-folders, the TIFF
toggle, `RESET_STATION.ps1`. A project is configured through the fixed 14-field
template editor, which covers dropdown options, `Place`, the Title->Record Type
map, mandatory flags and field order - but not field labels, which field names
the folder, or the CSV column order.

### Gates on this branch (measured 2026-09-07, not copied forward)

```
apps/LWCAM        flutter analyze && flutter test    # 6 issues,  595 pass
apps/LWCamAdmin   flutter analyze && flutter test    # clean,     136 pass
apps/LWCam_QC_Platform/backend  pytest -q            # 8 fail,    385 pass
apps/LWCAM/LWIP/backend  unittest discover -s tests  # 1 fail,     29 pass
```

The 8 backend and 1 LWIP failures are the SAME pre-existing ones documented
above. Any other number is yours.

### Decisions worth not re-litigating

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
  camera crop, replays `effective_ops`, writes the lossless TIFF. Rotation is
  Lanczos through OpenCV (`opencv-python-headless`, in the wheels), sized and
  placed exactly as Pillow's `rotate(expand=True)` so the rects align; Pillow
  bicubic is the fallback if cv2 is missing. A page with no ops is
  pixel-identical to the camera decode.
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
  making the capture PC write UNC paths and pay SMB on its own writes.
- `Deploy\Taiping All Saints Church\SETUP-LAN-DB.bat` configures the hosting PC
  end to end (static IP on the cable, `pg_hba`, firewall, restart), idempotent
  and self-healing. `SHOW-DB-PASSWORD.bat` prints the password from both places
  it can live and says which one actually logs in.

**The PostgreSQL password changes whenever the server is reinstalled**, and
`postgres-password.txt` can go stale by itself: when setup reinstalls over an
existing data directory the cluster keeps its OLD password while the file may
record a freshly invented one. `lwcam_node_config.json`'s `pgPassword` is the
value the station actually connects with. This cost real time twice - run
`SHOW-DB-PASSWORD.bat` before debugging anything else.

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

### Verified on a station, and not

Exercised end to end on this PC: install (both the two-file split and the
missing-file guard), Station Setup, capture, LWIP, QC review with the deferred
edits, approve, export, the Completed list and its search, capture rework, and
the missing-page repair.

**Not yet exercised.** The client-rework republish end to end - revert, correct,
approve, then confirm the SAME Group ID replaced the package in the bucket AND
in 4.Uploaded. And the two-PC site beyond the database connection itself: the
image remap, and a QC/export run driven from the second PC.

## State of play (2026-09-02)

Committed as `ec0b943` (the work) and `9bd6020` (this file). Per-app
`CHANGELOG.txt` files carry the detail; this is the map.

`LWSuite.exe` at the workspace root is built from that state, so a fresh install
has everything below. Rebuild it after any change (see **Deploying**) — the app
you install is only as current as the last compile.

**Done and verified**

- **Nav restructure** — branded landing with role-gated cards, one Projects list
  for every role, per-project cards driven by `AppUser.rolesForProjectKey`.
- **LWIP reports to PostgreSQL itself** (`LWIP/backend/deskew_crop_tool/cloud_report.py`)
  so a folder reaches QC with LWCAM closed. Proven end to end on the station.
- **Auto-export** — `ExportAutoScheduler` exports approved folders on a timer,
  with a durable failure ledger (`.lwcam-export/failures.json`) and an admin
  **Exports** screen offering per-folder and batch retry.
- **QC review parity** — three-column layout, lazy thumbnails, adjustable crop,
  replace-image, collapsible AI panel, read-only completed folders.
- **Crop padding** is a Station Setup field (`processingCropPadding`, default 200).
- **QC page selection and keyboard paging.** Thumbnails in the review rail carry
  tickboxes (ctrl-click toggles, shift-click takes a range, neither moves the
  page on screen); rotate, deskew, luminance and delete act on the ticked set,
  falling back to the page on screen when nothing is ticked. The old all-or-one
  `applyToAll` toggle is gone — "All pages" is now that selection's select-all,
  at the top of the rail rather than the far end of the scrolling toolbar.
  Deskew and delete gained `deskew-batch` / `delete-batch` in the QC engine to
  match the rotate and luminance pair; a batch delete validates the whole list
  before removing anything, so it can never empty a folder. Left/right arrows
  page the viewer — the handler is scoped to the rail-and-viewer subtree, NOT
  the Scaffold, because Flutter's text-editing shortcuts sit above the page and
  a page-level handler eats the caret's arrow keys in the metadata form (proven
  by `qc_review_page_test.dart`, which fails if it is moved back up). Fixed
  metadata fields render greyed with a lock icon, and "Send back" is now a red
  **Rework** button — label only, the wire value was always `REWORK`.
- **A swap recapture now refreshes the durable `box_images` copy**
  (`BoxSessionController.replaceDurableImage`). It previously updated only the
  gallery cache, so reopening a box showed the superseded photo — and
  `stageBoxFiles`, which reuses that copy when its size matches the device's,
  could have transferred it.

**Open**

- **Zoom is blurry in QC**, but less than it was. The 512px half is fixed: the
  preview route's `draft_image_path` returns None until a page is first edited,
  so a **claimed** folder was serving LWIP's 512px thumbnail for every untouched
  page — a rotate silently sharpened it, which is what made this look like a
  zoom problem rather than a source problem. A folder claimed by the caller now
  renders from the capture; read-only viewers keep the thumbnail. What remains
  is the single 1600px max edge (`previews.py`): pages are ~3566×5206, so deep
  zoom still softens. A full-resolution branch on the preview route is still
  wanted; the web console has the same limitation.
- **Admin cannot sign in to the QC engine.** `auth_controller.dart` now signs in
  admins, and the engine accepts the role — but a real admin login still failed.
  Everything structural was ruled out (build, backend, account, role gate, route
  table, payload shape). Remaining suspect: the account's password differs
  between the **local snapshot** (`lwcam_users.json`, which LWCAM authenticates
  against) and **PostgreSQL** (which the engine uses). The failure now reports its
  reason at login and in the message, so the next attempt should say which.
- The QC platform's **export UI** is ported; its **stats/user-management** views
  are not.
- **Auto-export has not been observed end to end on a station.** The code is
  deployed and its ledger is unit-tested, but the "approve, wait 30s, find a ZIP
  in `3.Export`" run has never been completed — the earlier attempt predated the
  backend reaching Program Files. Worth doing first next session, along with the
  deliberate-failure path (a stale same-named ZIP forces `zipConflict`).

## Station facts

- Config: `%USERPROFILE%\LWCAM_DBs\` — `lwcam_node_config.json` (PG credentials,
  paths), `lwcam_users.json` (the snapshot LWCAM authenticates against),
  `lwcam_stats_<deviceId>.db`, `lwip/` runtime + journal.
- Data lives **inside the install tree**: `C:\Program Files\LW Suite\LWCam Capture\`
  (`1.Images`, `2.Batches`, `3.Export`, `4.Uploaded`), plus
  `C:\Program Files\LW Suite\Upload Reports\Upload_Summary.db3` (one row per
  uploaded package). **Back it up before uninstalling.**
- PostgreSQL is a separate install and survives an LW Suite uninstall — but the
  installer reinstalls it if absent, with a new password. Since 2026-09-06 its
  359 MB setup exe is **not inside `LWSuite.exe`** (150 MB): it ships beside it
  and `[Run]` launches it from `{src}`. `PrepareToInstall` aborts by name when
  the PC needs a server and the file is not there. `build-installer.ps1` copies
  it next to the built installer; ship both.
- Never run the installed LWCAM and a dev build at once: they share the per-device
  SQLite DB and the transfer lock.

## Working habits that paid off here

- **Prove a regression test fails without the fix.** Several times a test passed
  either way until checked; twice the "fix" was in the wrong place.
- **Baseline before blaming.** Stash, run, pop.
- **A misleading comment is worse than none.** Two bugs this session survived
  because a comment claimed the case was handled — `"Replacement slots are always
  re-pulled"` was true of the branch above it and false of the one below.
