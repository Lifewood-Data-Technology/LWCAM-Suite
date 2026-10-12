# LWCam QC Platform

English | [简体中文](README.zh-CN.md)

The QC Platform is the review and export part of the LWCam suite. It is a
FastAPI server with a Vue 3 web console. Several reviewers open the console in
a browser over the network. They check each folder of processed pages, approve
it or send pages back, and the server exports approved folders as delivery
packages.

It has no link to the capture PC. It talks to the other parts only through the
shared PostgreSQL database and through folders on disk.

## What it does

- Review: show a folder's pages, change the page geometry, replace or insert a
  page, split a folder with separation markers, approve, or reject for recapture.
- Client rework: reopen a delivered folder, change it, and republish it under the
  same Group ID.
- Export: build TIFF or JPEG delivery packages (optional ZIP) in a work folder and
  publish them to the output folder.
- Admin: statistics, QC task management, export management, settings, and a
  System status page that shows every part of the site.
- Optional AI metadata review through OpenRouter (off by default).

It does not capture, process images (LWIP does), upload to S3 (LWCam Upload does),
or manage users and projects (LWCam Admin does).

## Where it sits in the pipeline

```
LWCAM -> LWIP -> output folder (qcInputRoot) -> QC Platform -> export folder (qcOutputRoot) -> Upload
                                                     ^
                                   PostgreSQL: folders, pages, QC state, users
```

LWIP records page geometry as data (`qc_ops`). The QC server keeps it as data
until export. At export it replays the chain once, on the original pixels. The
reasons are in [../docs/FAMILYSEARCH-FIX.md](../docs/FAMILYSEARCH-FIX.md) and
[../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Folder map

| Path | Content |
| --- | --- |
| `backend/` | The FastAPI server |
| `backend/run_server.py` | Start script (use this, see "Run from source") |
| `backend/app/main.py` | App start-up. Also serves the built console. |
| `backend/app/routers/` | HTTP routes: `auth`, `qc`, `export`, `admin` |
| `backend/app/services/` | Previews, geometry replay, separation, drafts, export, AI review, sweeps, status heartbeat, schema check |
| `backend/app/core/` | Settings (`server_settings.py`), security, TLS, secrets |
| `backend/app/models/`, `schemas/`, `db/` | Database models, API schemas, session |
| `backend/tests/` | Unit tests |
| `backend/repair_split_manifests.py` | One-off repair for folders split before a fix |
| `frontend/` | Vue 3 + TypeScript + Vite + Element Plus console |
| `database/` | The unified schema dump and `migrations/` (001 to 008) |
| `scripts/` | `setup_qc_db.py` (create or upgrade the schema), `check_role_grants.py`, `reset_test_folder.py` |
| `config.example.txt` | Example settings file |

The database schema is applied by `LWCamDatabaseSetup.exe`, which runs
`scripts/setup_qc_db.py`. The server refuses to work if the schema level is
lower than `REQUIRED_SCHEMA` in `backend/app/services/schema_check.py`.

## Run from source

Short version. The full setup (Python, PostgreSQL, Node) is in
[../docs/DEV-SETUP.md](../docs/DEV-SETUP.md).

```bash
# 1. Settings: copy the example, then fill in the database login and jwtSecret
copy config.example.txt config.txt

# 2. Build the console (the server serves frontend/dist)
cd frontend
npm ci
npm run build          # vue-tsc --noEmit && vite build

# 3. Start the server
cd ..\backend
python -m pip install -r requirements.txt
python run_server.py   # port from config.txt, default 8080
```

For console work, run `npm run dev` in `frontend/`. Vite listens on port 5174 and
proxies `/api` to `http://localhost:8080` (set `VITE_API_TARGET` to change it).

Always use `run_server.py`. Do not start the server with `python -m app.main`
from `backend/`. On a PC where the installed QC server's embeddable Python runs
the command, that runtime's `._pth` file puts the installed backend first on the
path, so you start the wrong server and it exits with no message.
`run_server.py` puts this folder first and prints which tree it serves.

Test: [../docs/TESTING.md](../docs/TESTING.md) has the baseline and the known failures.

```bash
cd backend
python -m unittest discover -s tests -t .
```

Tests are `unittest.TestCase` classes. Pytest can collect them, but it is not
required. One test file creates and drops scratch databases on a local
PostgreSQL, using the login in `config.txt`. It skips when no server answers.

To get a pending folder without a camera, see `scripts/reset_test_folder.py`
(its docstring explains the steps) and the "Test data without a camera" section
of [AGENTS.md](AGENTS.md).

## Configuration: `config.txt`

The server reads plain `key = value` lines from `config.txt` in this folder.
An installed server keeps it in `<install folder>\config\config.txt`.
`LWCAM_QC_SERVER_CONFIG` can point to another file. The console's Settings page
also edits this file. `config.example.txt` lists every key with comments. The
full list and the defaults are in `backend/app/core/server_settings.py`
(`SETTINGS_BY_KEY`).

| Group | Keys |
| --- | --- |
| Database | `dbHost`, `dbPort`, `dbName`, `dbUser`, `dbPassword`, `dbUseSsl` |
| Login | `jwtSecret` (at least 32 random characters), `jwtExpireMinutes` |
| Web console | `bindHost`, `port`, `tlsCertFile`, `tlsKeyFile` |
| Folders | `qcInputRoot` (LWIP's output), `exportWorkRoot` (scratch, local), `qcOutputRoot` (delivery packages). Use a local path or a UNC share. Never a mapped drive letter. |
| Export | `exportZipOutput`, `exportTiffOutput`, `exportAutoEnabled`, `exportWorkerCount`, `exportTempRetentionHours`, `luminanceEnabled`, `previewCacheMaxMb` |
| AI review | `aiReviewEnabled`, `aiPreanalysisEnabled`, `openrouterApiKey`, `openrouterExtractModel`, `openrouterCompareModel` |

Secrets (`dbPassword`, `jwtSecret`, `openrouterApiKey`) can be typed in plain
text. On Windows the server encrypts them at first start (`dpapi:...`, tied to the
PC). `config.txt` is git-ignored. Never commit it.

## The console

Open `https://<pc-name>:8080/` (plain `http` when `tlsCertFile` is blank).
Accounts are created in LWCam Admin. One account has one live sign-in at a time.

| Role | Screens |
| --- | --- |
| QC reviewer | Pending tasks (`/qc/tasks`), My tasks (`/qc/my-tasks`), Completed (`/qc/completed`), Review (`/qc/review/:id`) |
| Admin / SuperAdmin | Statistics, QC task management, Exports, Settings, System status (`/admin/...`) |

The System status page lists every part that has reported to the database
(QC, QC export, LWIP, Upload, backup, each capture PC) in green, red or grey. A
banner links to it from every screen. The meaning of each signal is in
[../installer/README.md](../installer/README.md) ("System status page").

## Read next

- [AGENTS.md](AGENTS.md): how to run the server, decisions not to re-litigate,
  test data, and open items. Start here for QC work.
- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md): the whole pipeline.
- [../installer/README.md](../installer/README.md): the QC installer and the HTTPS trust step.
- [../LWIP/README.md](../LWIP/README.md) and [../LWCam_Upload/README.md](../LWCam_Upload/README.md): the neighbours of the QC server.
