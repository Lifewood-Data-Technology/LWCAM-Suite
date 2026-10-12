# LWCam Upload

English | [简体中文](README.zh-CN.md)

LWCam Upload is a Python service for Windows. It watches a folder of export
packages (one folder or ZIP per Group ID) and sends each package to an S3
bucket. It checks the size of every uploaded file. It then records the package
in `Upload_Summary.db3` (when `summary_root` is set) and moves it to
`done_root`. So `watch_root` holds only what has not reached the bucket yet.

A package that QC republishes under the same Group ID (client rework) is
detected by a content fingerprint. It is uploaded again and replaces the earlier
copy in the bucket and in `done_root`.

A package is uploaded only after its content stays unchanged for 10 seconds
(`SETTLE_SECONDS` in `engine.py`). A package copied in by hand is not sent half
finished.

It runs by itself. It was split out of the QC server so it can run on its own PC
and schedule, whether or not QC or LWIP are installed there.

## Where it sits in the pipeline

```
QC Platform -> export folder (qcOutputRoot) -> LWCam Upload -> S3 bucket
```

`watch_root` is QC's `qcOutputRoot`. Upload needs the database only for console
sign-in and for its status report. Uploading itself does not need it.

## Folder map

| Path | Content |
| --- | --- |
| `backend/lwcam_upload/engine.py` | The scan, upload, retry and re-upload logic |
| `backend/lwcam_upload/config.py` | Every config key, default and check |
| `backend/lwcam_upload/ledger.py` | `uploads.json`, the list of packages already sent |
| `backend/lwcam_upload/summary.py` | `Upload_Summary.db3` |
| `backend/lwcam_upload/console.py`, `web/` | The web console (port 8091) |
| `backend/lwcam_upload/{health,tls,netlogin,lwcam_secrets}.py` | Status heartbeat, HTTPS certificates, network folder logins, DPAPI secrets |
| `backend/tests/` | Unit tests |
| `config/upload_config.example.json` | Example configuration |
| `SETUP_UPLOAD.bat`, `START_UPLOAD.bat` | Build the private runtime. Start the service (the scheduled task runs this). |

## Run, build, test

You need Python 3.14 and the packages in `requirements.txt` (`boto3`,
`psycopg`, `bcrypt`, `cryptography`). Details: [docs/DEV-SETUP.md](../docs/DEV-SETUP.md).
Test baselines: [docs/TESTING.md](../docs/TESTING.md).

```bash
cd LWCam_Upload
python -m venv venv
venv\Scripts\python -m pip install -r requirements.txt
cd backend
..\venv\Scripts\python -m unittest discover -s tests -v
..\venv\Scripts\python -m lwcam_upload --config ..\config\upload_config.json
```

Copy `config/upload_config.example.json` to `config/upload_config.json` first.
Do not commit your copy: it holds the S3 keys.

## Configuration

`config/upload_config.json` (JSON). `backend/lwcam_upload/config.py` has every
key, default and validation rule.

| Key | Meaning |
| --- | --- |
| `watch_root` | Required. The folder QC publishes packages into. |
| `done_root` | Where a sent package is moved. Blank = leave it in place. |
| `summary_root` | Where `Upload_Summary.db3` is written. Blank = no summary. |
| `enabled` | `true` (default). `false` pauses uploading. The console stays up. |
| `s3_path` | `s3://bucket/optional/prefix`. Required while enabled. |
| `s3_region`, `s3_access_key`, `s3_secret_key` | Required while enabled. |
| `https_proxy` | Optional proxy for S3 traffic. |
| `interval_seconds` | Scan interval. Default 60. The code accepts 10 to 3600. |
| `db_host`, `db_port`, `db_name`, `db_user`, `db_password`, `db_use_ssl` | PostgreSQL login. Used for console sign-in and the status report. |
| `ui_bind`, `ui_port`, `tls_cert_file`, `tls_key_file` | Console address (port 8091). The installer fills in the certificate files. |

The service re-reads the settings at the start of every scan. A console save
applies on the next scan, with no restart. An invalid config logs one `[CONFIG]`
line and uploads nothing until it is fixed.

`db_password` and `s3_secret_key` are stored encrypted (`dpapi:...`, Windows
DPAPI, tied to the PC). A copy of the file on another PC cannot decrypt them.
Enter them again in the console there.

## Console

The console is at `https://<pc-name>:8091/`. It is HTTPS only.

- Sign in with an Admin or SuperAdmin account from the shared PostgreSQL `users`
  table.
- When the database is unreachable, the console is read-only. A browser on the
  same PC sees status and log. An admin who signed in before can sign in from a
  saved list (`admin_cache.json` beside the config).
- "Network folder logins" saves the account this PC uses to reach a share on
  another PC (needed outside a domain). See [installer/README.md](../installer/README.md).
- HTTPS certificates and the one-time browser trust step: see "HTTPS" in
  [installer/README.md](../installer/README.md).

## Failures and retries

- A package that fails stays where it is. It is retried with back-off and shows
  red on the QC console's System status page until it goes through.
- If the share that holds `watch_root` is off, Upload retries every two minutes.
- While the database or the QC PC is off, Upload keeps scanning and uploading.
  It sends the status report later.
- If the database schema is older than this program needs, Upload does no
  database work and says so. Upgrade the database PC first.

## Logs and installed layout

`LWCamUploadSetup.exe` installs to `%ProgramFiles%\LWCam Upload`. The scheduled
task "LWCam Upload" runs `START_UPLOAD.bat` as SYSTEM at boot.
`logs\service.log` holds what `START_UPLOAD.bat` prints. Every scan, upload,
retry and error also goes to `log_file` (default `logs\upload.log`, rotated at
10 MB x 5) and shows live in the console. `runtime\` holds the private Python
and `uploads.json`. What the installer changes on the PC is in
[installer/README.md](../installer/README.md).

## Read next

- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md): how Upload fits with the other parts.
- [../LWCam_QC_Platform/README.md](../LWCam_QC_Platform/README.md): the app that writes the packages.
- [../installer/README.md](../installer/README.md): the Upload installer and its parameters.
- There is no `AGENTS.md` for Upload. The workspace guide is [../AGENTS.md](../AGENTS.md).
