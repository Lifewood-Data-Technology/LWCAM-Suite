# LWIP: deskew, crop and thumbnail service

English | [简体中文](README.zh-CN.md)

LWIP is a Python service for Windows. It watches an input folder for folders of
camera images. For each folder it measures every page's skew, crops the page
in memory, and writes the staged output. It never rotates a pixel itself. A page
tilted past `deskew_min_degrees` gets its correction recorded as a small list
of operations (`qc_ops`) in the output manifest. The QC Platform replays that
list once, at preview and export time. LWIP checks that the source folder did
not change, then publishes the output folder.

It is a stand-alone install (`LWIPSetup.exe`). No other app starts or watches it.

The same service also consumes immutable colour-chart tasks in
`input_root/.calibration` independently of document work. One owned child process
analyses at a time (120-second execution limit), using the bundled ColorCal
algorithm. The existing console exposes read-only queue status. Capture polls
files and requires operator confirmation; no capture-side Python or HTTP call.
The reserved directory is excluded at both document folder depths.
See [protocol](../docs/CALIBRATION-PROTOCOL.md) and
[deployment](../docs/COLOR-CALIBRATION.zh-CN.md). Start
`python -m deskew_crop_tool.service --config <path>` to test both queues from source;
the document-only `--once` entry does not run calibration.

Completed calibration tasks keep lightweight request/ready and photo metadata checks on each scan.
The photo is fully revalidated on the first scan after restart, when its metadata changes,
or every five minutes. Missing results and interrupted publication still require full validation
before republishing; analysis is not repeated for completed tasks. Invalid-request failures
remain failures and can be republished without trying to validate the already-rejected photo.

## Where it sits in the pipeline

```
LWCAM -> input folder -> LWIP -> output folder -> QC Platform
                          |
                          +-> reports each finished folder to PostgreSQL
```

- Input: folders that LWCAM copied. LWCAM writes `lwcam_capture_marker.json`
  into a folder when its transfer is complete. The marker carries the folder's
  database identity and the number of images (`image_count`). LWIP waits for
  the marker, and for that many images.
- Output: the processed images, `thumbs\` (optional), and a manifest with the
  `qc_ops`. The manifest also carries `source_identity`, copied from the marker.
- Report: LWIP writes the folder's result straight to PostgreSQL
  (`cloud_report.py`). The folder then appears in the QC queue even when LWCAM is
  closed.

## Folder map

| Path | Content |
| --- | --- |
| `backend/deskew_crop_tool/orchestrator.py` | The watcher: stability checks, journal, publishing, integrity audits |
| `backend/deskew_crop_tool/image_ops.py` | Page detection, deskew angle, lossless crop |
| `backend/deskew_crop_tool/geometry_replay.py` | Replays `qc_ops` (shared with the QC Platform) |
| `backend/deskew_crop_tool/service.py` | Supervisor: starts the watcher and the web console (default port 8090) |
| `backend/deskew_crop_tool/cloud_report.py` | Reports finished folders to PostgreSQL |
| `backend/deskew_crop_tool/web/` | The console (HTML) |
| `backend/deskew_crop_tool/{tls,netlogin,lwcam_secrets,health}.py` | HTTPS certificates, network folder logins, DPAPI secrets, status heartbeat |
| `backend/tests/` | Unit tests |
| `config/deskew_crop_config.example.json` | Example configuration |
| `START_LWIP.bat` | What the scheduled task runs (supervisor and console) |
| `SETUP_DESKEW_CROP.bat`, `START_DESKEW_CROP.bat`, `RUN_TESTS.bat` | Source checkout helpers (see below) |

## Run, build, test

LWIP needs Python 3.14 and the packages in `requirements.txt` (OpenCV, NumPy,
Pillow, and others). Lossless crop uses `jpegtran.exe` from `LWIP\tools`
(not in git; see [docs/DEV-SETUP.md](../docs/DEV-SETUP.md)). Without it, pages
are re-encoded instead.

From a source checkout, with your own Python:

```bash
cd LWIP
python -m venv venv
venv\Scripts\python -m pip install -r requirements.txt
cd backend
..\venv\Scripts\python -m unittest discover -s tests -v
..\venv\Scripts\python -m deskew_crop_tool --config ..\config\deskew_crop_config.json --once
```

`__main__` options: `--config <file>`, `--once` (process what is ready, then exit),
`--wait` (with `--once`: wait for folders to become stable first), `--verbose`.

The `.bat` files expect a private runtime in `runtime\python`, built by
`SETUP_DESKEW_CROP.bat` from the embeddable Python zip and the offline `wheels\`
folder (both come with the build inputs). With that runtime,
`RUN_TESTS.bat` runs the tests and `START_DESKEW_CROP.bat` starts the watcher
(`--once`, `--once --wait` pass through).

Two long-path tests fail on some PCs. See [docs/TESTING.md](../docs/TESTING.md)
for the known failures and the baseline.

Only one orchestrator can use a `work_root`. Folders are processed one at a
time, oldest first.

## Configuration

Copy `config/deskew_crop_config.example.json` to `config/deskew_crop_config.json`
and edit it. The installer writes this file once and does not overwrite it on an
upgrade. `backend/deskew_crop_tool/config.py` has every key, default and check.

| Key | Meaning |
| --- | --- |
| `input_root` | Folder that holds the jobs. With `folder_depth` 1 (default), each child is a job. With 2, each grandchild is a job (`YYYYMMDD/<folder>`, LWCAM's layout). |
| `output_root` | Where finished folders go, mirroring the input layout. Must not be the input folder or inside it. Output is staged on the output volume, then switched in whole. The input is never changed or deleted. |
| `completion_marker` | Marker file name, for example `lwcam_capture_marker.json` (the installer sets it). A folder is ready only when the marker exists and its `image_count` is met. Blank = no marker. |
| `stable_seconds`, `minimum_file_age_seconds` | Without a marker: the file list must stay unchanged this long, and the newest file must be this old. |
| `rework_settle_seconds` | Wait after a rework folder changes (default 30). |
| `crop_padding` | Pixels of background kept around the page (default 200). For a tilted page it is measured after straightening. LWIP maps the padded box back to the camera frame, so rotation does not eat the margin. A side the page runs off is shortened. |
| `deskew_min_degrees` | Below this, skew is reported as 0 and no op is recorded (default 0.5). |
| `mat_fill` | `true` (default): a trailing `matfill` op paints rotation corners with the background colour at preview and export. Needs a QC Platform that knows the op. Upgrade QC first. |
| `jpeg_quality` | Default 100 (4:4:4). Do not lower it for archive work. |
| `thumbnail_width`, `thumbnail_quality`, `thumbnail_dirname` | `thumbnail_width` 0 = no thumbnails. Otherwise a JPEG thumbnail goes to `<output>\thumbs\`. |
| `workers` | Image worker processes. 0 = logical CPUs minus one (max 61). Each worker can use about 0.5 GB for a 6144x8192 JPEG. |
| `state_file` | Journal of finished folder fingerprints. A changed fingerprint makes the folder eligible again. |
| `presence_check_interval_seconds`, `checksum_check_interval_seconds` | Idle audits: missing or extra files (default 300 s per folder), SHA-256 of outputs (default daily). A bad file triggers reprocessing from the source. |
| `cloud_report`, `db_host`, `db_port`, `db_name`, `db_user`, `db_password`, `db_use_ssl` | PostgreSQL connection for reporting. The installer sets `cloud_report` to true. With it on, a missing host, user or password stops start-up with a clear message. |
| `ui_bind`, `ui_port`, `tls_cert_file`, `tls_key_file` | Console address (port 8090). The installer fills in the certificate files. |

How output is written:

- A JPEG with a page found is re-written by a lossless `jpegtran` trim. Every
  other file (PNG, TIFF, BMP, JPEG XL, or a JPEG with no page found) is delivered
  as the source's own bytes. Its crop, deskew and matfill are recorded in `qc_ops`
  against the full source frame. A file with an EXIF orientation other than 1 is
  decoded and re-encoded. `.jxl` needs the optional `pillow-jxl-plugin` package.
- Page detection uses the OpenCV Triangle threshold. Otsu put a bound volume's
  dark cover board in the backdrop and cost margin and angle accuracy.
- Each output file is written to a temporary file, flushed, then renamed. The
  manifest holds the path, size and SHA-256 of every output.
- A folder is published only after every file and the manifest pass a size
  check. The input stays read-only during recovery.

## Console

`START_LWIP.bat` runs `deskew_crop_tool.service`. It starts the watcher as a
child process and serves a small web console at `https://<pc-name>:8090/`
(`ui_port`, `ui_bind`). The console stays up when the watcher's config is bad,
so you can fix it in a browser.

- Sign in with an Admin or SuperAdmin account from the shared PostgreSQL `users`
  table. A QC-only account cannot sign in.
- When the database is unreachable, the console is read-only. A browser on the
  same PC sees status and log. An admin who signed in before can sign in from a
  saved list (`admin_cache.json` beside the config).
- Saving Settings restarts the watcher with the new values.
- "Network folder logins" saves the account this PC uses to reach a share on
  another PC. See [installer/README.md](../installer/README.md).
- `db_password` is stored encrypted (`dpapi:...`, Windows DPAPI, tied to the
  PC). Enter it again if you copy the file to another PC.
- The console is HTTPS only. See "HTTPS" in [installer/README.md](../installer/README.md).

The service reports to the QC console's System status page. If the database or
the QC PC is off, LWIP keeps processing and reports later. If the database
schema is older than this program needs, LWIP does no database work and says
so. Upgrade the database PC first.

## Installed layout and stopping

`LWIPSetup.exe` installs to `%ProgramFiles%\LWCam LWIP`. The scheduled task
"LWCam LWIP" runs `START_LWIP.bat` as SYSTEM at boot. Logs go to
`logs\service.log`. To stop the service cleanly, create the file
`%ProgramData%\LWCAM\lwip.stop`. LWIP exits after the folder it is publishing,
within about 90 seconds. What the installer changes on the PC is in
[installer/README.md](../installer/README.md).

## Read next

- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md): how LWIP fits with the other parts.
- [../installer/README.md](../installer/README.md): the LWIP installer and its parameters.
- [../LWCam_QC_Platform/README.md](../LWCam_QC_Platform/README.md): the app that reads LWIP's output.
- There is no `AGENTS.md` for LWIP. The workspace guide is [../AGENTS.md](../AGENTS.md).
