English | [简体中文](DEV-SETUP.zh-CN.md)

# Developer setup

This guide gets you from a fresh Windows PC to every module running from source. For tests, see [TESTING.md](TESTING.md). For the installers, see [RELEASING.md](RELEASING.md). For terms, see [GLOSSARY.md](GLOSSARY.md).

## 1. Toolchains

| Tool | Version | Used for |
| --- | --- | --- |
| Windows | 64-bit Windows 10 or 11 | Everything. LWCAM, LWCam Admin and the installers are Windows only. |
| Git | Any recent version | Source |
| Flutter / Dart | Dart `^3.8.1` or newer is required (both `pubspec.yaml` files). The last verified toolchain is Flutter 3.47.0 with Dart 3.13.0. | LWCAM, LWCam Admin |
| Visual Studio 2022 | The "Desktop development with C++" workload | `flutter build windows` |
| Python | 3.14.8 (64-bit). The installers bundle the 3.14.8 embeddable zip. | QC backend, LWIP, Upload, setup scripts |
| Node.js and npm | A current release. The last verified version is Node 26.1.0. | QC frontend (Vue 3, Vite 6, TypeScript 5.6) |
| Inno Setup | 6 | Build installers (`ISCC.exe`) |
| PostgreSQL | 18 (the bundled installer is `postgresql-18.*-windows-x64.exe`) | The database |

Python packages (all modules): see `LWCam_QC_Platform/backend/requirements.txt`, `LWIP/requirements.txt` and `LWCam_Upload/requirements.txt`. The two newer files pin exact versions (for example `psycopg[binary]==3.3.4`, `bcrypt==5.0.0`, `cryptography==50.0.1`, `boto3==1.43.88`). The QC backend file uses minimum versions.

The test suites use `unittest`. You do not need pytest.

## 2. Get the source

```
git clone https://github.com/djchoy-LW/LWCAM-Suite.git
cd LWCAM-Suite
```

The default branch is `lwcam-module`. For the all-in-one edition, run `git switch lwcam-all-in-one`. That edition has a different folder layout. This guide describes the module edition.

## 3. Get the build inputs

Some files are too big for git. They are in the private GitHub Release named `build-inputs`. Download the assets and run the unpack script that comes with the release. Then check that these paths exist (all are ignored by git):

| Path | Content |
| --- | --- |
| `installer/vendor/python-3.14.8-embed-amd64.zip` | Python embeddable zip |
| `installer/vendor/vcruntime/` | Visual C++ runtime DLLs (`msvcp140.dll`, `vcruntime140.dll`, `vcruntime140_1.dll`) |
| `installer/vendor/adb/` | `adb.exe`, `AdbWinApi.dll`, `AdbWinUsbApi.dll` |
| `installer/vendor/postgresql/` | The PostgreSQL 18 installer |
| `LWCAM/scrcpy/` | A scrcpy Windows build (contains `scrcpy.exe`) |
| `LWIP/tools/` | `jpegtran.exe` |
| `LWIP/wheels/` | Offline wheels for LWIP (also used by the Database installer) |
| `LWCam_QC_Platform/backend/wheels/` | Offline wheels for the QC backend |
| `LWCam_Upload/wheels/` | Offline wheels for Upload |

You need these only to build installers, and (for adb and scrcpy) to run LWCAM. To run the Python modules or the tests, `pip install -r requirements.txt` is enough.

Sample images are not in the repository. Ask the project lead (Jackson Choy, jackson.choy@lifewood.com).

## 4. Local PostgreSQL and the schema

1. Install PostgreSQL 18 (run the bundled installer, or use an existing server). Note the `postgres` password.
2. Make a small file `setup.txt` for the schema script (keep it out of git). It holds the PostgreSQL administrator login, one `key = value` per line:

```
dbHost = localhost
dbPort = 5432
dbName = lwcam
dbUser = postgres
dbPassword = <the postgres password>
```

3. From `LWCam_QC_Platform`, run:

```
python scripts\setup_qc_db.py --server-config setup.txt --app-login lwcam_user
```

The script creates the database if it is missing, loads the unified schema on an empty database, applies every file in `database/migrations/` in name order, and records each one in `schema_migrations`. It is safe to run again.

`--app-login <name>` creates the one shared login that every part uses. The script reads its password from the environment variable `LWCAM_APP_PASSWORD` (never from the command line). The password needs 12 characters or more. On a dev PC, set it first:

```
set LWCAM_APP_PASSWORD=<a-password-of-12-or-more-characters>
```

Then put the same login into each module's config file (section 5). The installed Database installer runs the same script. Run `python scripts\setup_qc_db.py --help` for the other options (`--open-lan`, `--close-lan`, `--database-dir`).

## 5. Config files

Each module has an `*.example` file. Copy it, remove `.example`, and fill it in. The real files are ignored by git. Never commit them.

| Copy | To | Fill in |
| --- | --- | --- |
| `LWCam_QC_Platform/config.example.txt` | `LWCam_QC_Platform/config.txt` | `dbHost`, `dbPort`, `dbName`, `dbUser`, `dbPassword`. `jwtSecret`: 32 or more random characters (make one with `python -c "import secrets; print(secrets.token_urlsafe(48))"`). `qcInputRoot`, `exportWorkRoot`, `qcOutputRoot`: three separate local folders. `bindHost = 127.0.0.1` and `port = 8080` are good for dev. |
| `LWIP/config/deskew_crop_config.example.json` | `LWIP/config/deskew_crop_config.json` | `input_root`, `output_root`. For database reports: `cloud_report: true` and the `db_*` keys. |
| `LWCam_Upload/config/upload_config.example.json` | `LWCam_Upload/config/upload_config.json` | `watch_root`, `done_root`, `summary_root`, `s3_*` keys, `db_*` keys. |
| `LWCAM/lwcam_node_config.example.json` | `lwcam_node_config.json` in `%USERPROFILE%\LWCAM_DBs` (or use LWCam Admin, Station Setup) | `pg*` keys, `destinationPath`. |

Notes:

- Use real folder paths. Use UNC paths or local drives, never a mapped drive letter.
- Passwords may be plain text in a dev config. A running service encrypts them the first time it starts (`dpapi:` values). Those values work only on that PC.
- The QC server finds its config in `LWCam_QC_Platform/config.txt`, or in the file named by the environment variable `LWCAM_QC_SERVER_CONFIG`. It does not read LWCAM's `lwcam_node_config.json`.
- LWCAM and LWCam Admin share the same `lwcam_node_config.json`. LWCam Admin's Station Setup page is the simplest way to write it.
- The `db_*` and `pg*` keys use the shared login from section 4.

## 6. Run each module from source

### QC backend

```
cd LWCam_QC_Platform\backend
pip install -r requirements.txt
python run_server.py
```

Use `run_server.py`. Do **not** use `python -m app.main` (see "Known traps"). The server reads `config.txt` and listens on its `port` (8080). `run_server.py` prints which tree it serves.

### QC frontend

```
cd LWCam_QC_Platform\frontend
npm ci
npm run dev        # Vite dev server on port 5174, proxies /api to http://localhost:8080
npm run build      # vue-tsc --noEmit && vite build, output in dist/
```

Set `VITE_API_TARGET` to proxy to another backend. The backend serves `frontend/dist`, so run `npm run build` once to use the console at the backend's own address (an `https://` address when TLS is set up).

Sign in with an Admin or SuperAdmin account that exists in the database. Create the accounts in LWCam Admin.

### LWIP

```
cd LWIP\backend
python -m deskew_crop_tool.service --config ..\config\deskew_crop_config.json
```

This runs the supervisor and the console (port 8090, from `ui_port`). Install the packages first: `pip install -r LWIP\requirements.txt`. `LWIP\README.md` has the details.

### Upload

```
cd LWCam_Upload\backend
python -m lwcam_upload --config ..\config\upload_config.json
```

The console is on port 8091 (`ui_port`). Install the packages first: `pip install -r LWCam_Upload\requirements.txt`.

### LWCAM and LWCam Admin

```
cd LWCamAdmin
flutter pub get
flutter run -d windows

cd ..\LWCAM
flutter pub get
flutter run -d windows
```

A dev build of LWCAM does not find its tools beside the built exe. Provide them like this:

| Tool | How |
| --- | --- |
| `adb.exe`, `AdbWinApi.dll`, `AdbWinUsbApi.dll` | Copy them into `LWCAM\build\windows\x64\runner\Debug\` (or the Release folder), or put `adb` on PATH. |
| scrcpy | Put a Windows build in `LWCAM\scrcpy` (the app looks up to 7 folders above the exe for `scrcpy\scrcpy.exe`). |

Without adb, capture does not work (no crop, no shutter, no images). `flutter clean` deletes the copied files.

## 7. Make a test folder without a camera

`LWCam_QC_Platform/scripts/reset_test_folder.py <folder_id>` puts an approved or exported folder back to PENDING in the QC queue. It rebuilds the database row from LWCAM's local SQLite file (`%USERPROFILE%\LWCAM_DBs\lwcam_stats_<device>.db`) and re-runs LWIP on `1.Images`.

Without a camera or `1.Images`, copy a finished LWIP output folder into `qcInputRoot`, then run:

```
python scripts\reset_test_folder.py <folder_id> --skip-lwip --yes --batch-dir "<folder under qcInputRoot>"
```

`--skip-lwip` keeps the batch output as it is and rebuilds the database rows only. `--batch-dir` names the folder when the database records another path. The last line, "every row resolves to a file", shows that the folder is usable. This needs one folder row that exists already (made by an earlier capture). Run `python scripts\reset_test_folder.py --help` for the rest.

For sample images, ask the project lead.

## 8. Known traps

| Trap | What to do |
| --- | --- |
| **The `._pth` trap.** The shipped (embeddable) runtime has `python314._pth`. It fixes `sys.path` to the installed backend, ignores `PYTHONPATH`, and does not add the current folder. On a PC with an installed QC server, `python -m app.main` silently starts the installed copy, or exits with no output. | Start QC with `python run_server.py`. In any ad-hoc script, run `sys.path.insert(0, ".")` first, and `print(module.__file__)` to confirm which copy loaded. `python -m unittest discover -s tests -t .` is safe. |
| **User site-packages leak.** A private runtime can import the packages of the Python of the user who runs setup. pip then skips packages, and the runtime breaks. | Every script that runs a private runtime sets `PYTHONNOUSERSITE=1`. Set it too when you run those runtimes by hand. |
| **Mixed line endings.** `.gitattributes` sets `* -text`. Git converts nothing. Some files are CRLF and some are LF. A tool that rewrites a whole file can change every line. | Check the style before you edit (`file <path>`). Keep each file's style. Use an editor, not `sed -i`, on CRLF files. Check `git diff --stat` before you commit. |
| **Long paths.** Folder names come from operator input and can be long. Past 260 characters, Windows fails with a plain "file not found". LWIP uses the `\\?\` prefix (`fs_path`) for this. | Keep your clone path short. Use `fs_path` in new LWIP file code. Long-path support on the PC changes the result of two LWIP tests (see [TESTING.md](TESTING.md)). |
| **Stale builds in installers.** The installer packs the Release builds of LWCAM and LWCam Admin. | Rebuild both with `flutter build windows --release` before you build an installer. |
| **Mapped drive letters.** Services run as SYSTEM. | Use UNC paths or local drives in every folder setting. |
| **Debug build timestamps.** After a Dart-only change, the debug exe keeps its old time. | Check `data/flutter_assets/kernel_blob.bin` instead. |
