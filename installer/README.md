# LWCam installers

English | [简体中文](README.zh-CN.md)

This folder builds the five Windows installers (Inno Setup 6) from the source
tree. This file is the reference for the installers: what each contains, what
the wizard asks, the silent parameters, what each one changes on the PC, and how
upgrade and uninstall behave.

| Need | Read |
| --- | --- |
| Install LWCam at a site, step by step | [../docs/INSTALL.md](../docs/INSTALL.md) |
| Cut a release, stage the build inputs, publish | [../docs/RELEASING.md](../docs/RELEASING.md) |
| Set up a development PC | [../docs/DEV-SETUP.md](../docs/DEV-SETUP.md) |

## The five installers

| Installer | Installs | Runs as |
| --- | --- | --- |
| `LWCamDatabaseSetup.exe` | PostgreSQL 18 (or uses an existing server), the LWCam schema, the shared login, LAN access, nightly backup | PostgreSQL service, task "LWCam Database Backup" |
| `QCPlatformSetup.exe` | QC server (FastAPI) and the built Vue console | Task "LWCam QC Server" (SYSTEM, at boot), port 8080 |
| `LWIPSetup.exe` | LWIP image processing and its console | Task "LWCam LWIP" (SYSTEM, at boot), port 8090 |
| `LWCamUploadSetup.exe` | Upload service (S3) and its console | Task "LWCam Upload" (SYSTEM, at boot), port 8091 |
| `LWCamSetup.exe` | LWCAM capture app and LWCam Admin, for capture PCs | Desktop apps |

Default install folders: `%ProgramFiles%\LWCam Database`, `LWCam QC Platform`,
`LWCam LWIP`, `LWCam Upload`, `LWCam`.

Install order: the database first (once), then QC, LWIP and Upload (once each,
any order, on their own PCs), then `LWCamSetup` on every capture PC. Every part
needs the database host, port, name, user and password (one shared login, see
below). QC and LWCam Admin also need LWIP's output folder. Upload needs QC's
export folder. The parts do not need to share a PC. Any one of them can be off
without stopping the others.

Each part checks the schema level (the highest number in the database's
`schema_migrations` table) and refuses to work against an older database.
Required level: 8 for the QC server, 7 for LWCAM, LWIP and Upload. So on an
upgrade, run `LWCamDatabaseSetup` on the database PC before any other part.

The PostgreSQL installer is a separate file. Keep `postgresql-18.*-windows-x64.exe`
beside `LWCamDatabaseSetup.exe`. A PC that already has PostgreSQL needs only the
setup executable.

## Build

You need Inno Setup 6, the Flutter Windows release builds of LWCAM and
LWCam Admin, Node.js with npm, and the build inputs listed below. The inputs are
not in git. [../docs/RELEASING.md](../docs/RELEASING.md) says where to get them.

```powershell
cd ..\LWCAM      ; flutter build windows --release
cd ..\LWCamAdmin ; flutter build windows --release
cd ..\installer
.\build-installer.ps1 -Target All        # or Database, QC, LWIP, Upload, LWCam
```

`build-installer.ps1` options:

| Option | Meaning |
| --- | --- |
| `-Target` | `Database`, `QC`, `LWIP`, `Upload`, `LWCam` or `All` (default) |
| `-ResolveOnly` | Print the selected `ISCC` and `scrcpy` paths. Build nothing. |
| `-ScrcpyDir <path>` | Use this scrcpy build for the LWCam target. By default it uses `LWCAM\scrcpy` when that has `scrcpy.exe`, else an installed scrcpy package. |
| `-UpdateChecksums` | Rewrite `SHA256SUMS.txt` for all targets, then exit |

The QC target runs `npm ci` (when `package-lock.json` exists) and `npm run build`
in `LWCam_QC_Platform\frontend` first. The Database target copies the newest
staged `postgresql-18.*-windows-x64.exe` beside `LWCamDatabaseSetup.exe`.
Outputs land in the repository root. The script does not run an installer.

**Version.** The one-line `VERSION` file at the repository root (for example
`1.1.0`) plus the short git commit give `<version>+<commit>`. A build from an
uncommitted tree appends `-dirty`. The script passes them to every `ISCC` run
as `/DAppVer` and `/DBuildId`. Each installer writes `VERSION.txt` into its
install folder. Change `VERSION` by hand for a release. The script writes
`installer\vendor\VERSION.txt` for this. If you compile an `.iss` file directly
with `ISCC`, that file must exist.

### Build inputs (not in git)

```
installer\vendor\python-3.14.8-embed-amd64.zip   embeddable Python
installer\vendor\vcruntime\                      Visual C++ runtime DLLs
installer\vendor\adb\                            adb.exe and its two support DLLs
installer\vendor\postgresql\                     PostgreSQL 18 installer
LWCAM\scrcpy\                                    scrcpy Windows build
LWIP\tools\                                      jpegtran.exe, jpeg8.dll
LWIP\wheels\                                     offline LWIP dependencies (also
                                                 pip, psycopg and tzdata for the Database installer)
LWCam_QC_Platform\backend\wheels\                offline QC dependencies
LWCam_QC_Platform\frontend\dist\                 built by the QC target
LWCam_Upload\wheels\                             offline Upload dependencies
```

Each service installs its private Python runtime from the embeddable zip and
its wheel folder with `--no-index`. A missing wheel fails the install. It does
not fall back to a download.

`installer\SHA256SUMS.txt` pins every input that is not built from our source:
the Python zip, `vcruntime`, `adb`, the PostgreSQL installer, scrcpy,
`LWIP\tools` and the three wheel folders. One line per file:
`<sha256>  <path from the repo root>`, sorted, LF. `build-installer.ps1`
hashes the inputs of the chosen target before it builds. It stops with exit 1
if one changed, is missing, or is not listed. After an intended change (new
wheel, new `adb`) run `.\build-installer.ps1 -UpdateChecksums` and commit the
file. Flutter builds, `frontend\dist` and `vendor\VERSION.txt` are not listed.

### Installer sources

| File | Purpose |
| --- | --- |
| `Database.iss`, `QCPlatform.iss`, `LWIP.iss`, `Upload.iss`, `LWCam.iss` | One script per installer |
| `common.iss` | Helpers shared by all (`PythonProcessesUnder`, `RestrictToAdmins`) |
| `postgres.iss` | PostgreSQL detection, install and recovery. Included by `Database.iss` only. |
| `build-installer.ps1` | Input checks, frontend build, `ISCC` compile, copy of side files |
| `db\` | `SETUP_DB_RUNTIME.bat`, `SETUP_DATABASE.bat` (schema from `config\database.txt`), `BACKUP_DATABASE.bat`, `RESTORE_DATABASE.bat`, `backup_db.py` |
| `qc\` | `SETUP_QC.bat` (QC runtime), `START_QC_SERVER.bat`, `OPEN_QC_LOG.bat` |
| `Trust this LWCam server.cmd` | Copied to each server's install folder, for the browser trust step |

`START_QC_SERVER.bat` takes no arguments, on purpose. The host comes from
`config.txt`.

## What each installer contains and changes

### LWCamDatabaseSetup.exe

- Installs PostgreSQL 18, unless a server is present or the task "Use an existing
  PostgreSQL server" is ticked.
- Creates or upgrades the schema (`scripts/setup_qc_db.py` with every migration
  in `database\migrations`).
- Creates the one shared login (see "Database login").
- With the task "Allow other PCs on this network (and Tailscale) to connect" ticked
  and the database on this PC: sets `listen_addresses`, adds `pg_hba.conf` entries
  and a "LWCam Database" firewall rule for every network type, limited to the local
  subnet and Tailscale. It sets TCP keepalives (60 s idle, 10 s interval, 6 tries)
  so the database drops a dead client session and its lock in 2 to 3 minutes.
  Unticking the task on a later run removes the entries and the rule.
- `pg_hba.conf` is copied to `pg_hba.conf.bak-<time>` before any change. Only the
  PostgreSQL service that owns that data folder is restarted, and only when
  `listen_addresses` changed.
- Writes `config\database.txt` (PostgreSQL administrator login for setup and
  backups, plus the shared login). The folder is private to SYSTEM and
  Administrators. A kept `database.txt` from an earlier uninstall is reused,
  unless PostgreSQL itself was reinstalled in this run. Then the old file is
  renamed `database.txt.bak-<time>` and a new one is written.
- Locks the program folder (Administrators and SYSTEM write, others read), then
  registers the backup task. If locking fails, the task is not registered and the
  finish page says so.
- Shows host, port, database, user and the password you typed on the finish page.
- When `setup_qc_db.py` refuses something, the finish page shows the message and
  setup ends "needs attention". The same text is the last `[ERROR]` line of
  `logs\database-setup.log`. Nothing is changed by a refusal. Typical causes: an
  `--app-login` the rules refuse (choose another user or password and run again),
  or a "lock timeout" because the site was busy (run again).
- On uninstall it never removes PostgreSQL or its data. Other apps may use it.

**Backups.** A wizard page asks for the backup folder and how many backups to
keep (default 14). The folder defaults to `D:\LWCam Backups` when the PC has a D:
hard disk, else `C:\ProgramData\LWCam\Backups`. Setup refuses a drive root,
`C:\Windows`, Program Files, ProgramData, `C:\Users` and any folder that holds
other files. It warns when the folder is on the same drive as PostgreSQL. A
network share is written `\\server\share`. The task runs as SYSTEM, so it reaches
the share as the PC's computer account (`DOMAIN\PCNAME$`). Give that account
write access. A mapped drive letter is refused. A local backup folder is locked
to SYSTEM and Administrators, because a backup holds every login hash. The task
"LWCam Database Backup" runs `BACKUP_DATABASE.bat` every day at 02:00 as SYSTEM.
It writes `lwcam-YYYYMMDD-HHMM.dump` (PostgreSQL custom format) and
`lwcam-globals-YYYYMMDD-HHMM.sql` (`pg_dumpall --globals-only`: the roles with
their password hashes), and deletes the oldest of both beyond the keep count. A
failed night is retried 3 times, 10 minutes apart. The result goes to
`logs\backup.log` and to the `service_heartbeat` table (part `backup`).
Settings are in `config\backup.txt` (`backupDir`, `backupKeep`). Restore and
rebuild procedures are in [../docs/INSTALL.md](../docs/INSTALL.md) (backups and
restore). Backups are not encrypted. Keep the folder private.

**Database login.** Every part connects with one login. The "LWCam database login"
page asks for the database name (default `lwcam`), the port (default 5432, or the
saved or existing server's port; 1024 to 65535), the user (default `lwcam_user`)
and a password of at least 12 characters, typed twice. Names follow
`[a-z_][a-z0-9_]{0,62}`. `postgres` and `lwcam_app` are refused. The user is an
ordinary member of the group role `lwcam_app`. Migrations 006 and 008 give that
group exactly the grants the parts need (column-level `UPDATE`; no `CREATE`; no
superuser, `CREATEDB` or `CREATEROLE`; export sequences `USAGE` only). Enter the
same values in `QCPlatformSetup`, `LWIPSetup`, `LWCamUploadSetup`, and in
LWCam Admin's Station Setup on every capture PC.

Trade-off: one password serves every part, so a leaked password can read and edit
the LWCam tables from any network the database admits. It cannot run programs on
the database PC, create tables or drop the database. To change it, run
`LWCamDatabaseSetup` again with the new password, then update every part. On a
re-run the page is prefilled from `database.txt`. Leave both password boxes blank
to keep the saved password. Changing the port on an existing server does not move
PostgreSQL. It only changes what the firewall rule and the parts are told.

The password never goes on a command line. The installer puts it in the
environment variable `LWCAM_APP_PASSWORD` of its own process while it runs
`SETUP_DATABASE.bat`, then clears it. (A silent install takes `/APPPASSWORD=`
on its command line. See "Unattended install".)

From other PCs, only members of `lwcam_app` can connect (`pg_hba.conf`). They
connect to the configured database over TLS (`hostssl`), from the local subnet
and the Tailscale ranges (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`). A PC on another
network that is not on Tailscale is not admitted. Put it on Tailscale, or add a
`hostssl <database> +lwcam_app <address>/32 scram-sha-256` line by hand.

When "Allow other PCs" is ticked, setup removes the old `host all all samenet`
rule, unless `postgres` or a login outside `lwcam_app` is still connected from
another PC. Then it keeps the rule, still succeeds, and prints one `[NOTE]` line
that names who is connected. Switch those parts to the shared login and run setup
again. A broader non-TLS line only gets a warning in the log. The older five
per-part logins (`lwcam_qc`, `lwcam_lwip`, `lwcam_upload`, `lwcam_capture`,
`lwcam_admin`), where they exist, become members of `lwcam_app`, so parts that
still use one keep working.

### QCPlatformSetup.exe

- Installs the backend, the built Vue console and an offline Python runtime.
- Asks for the database host, port, name, user and password. The database must
  already exist. This installer does not create one.
- Writes `config\config.txt` on a fresh install only. The `config\` folder is
  private to SYSTEM and Administrators. It holds the database password and the
  login secret, and a console save writes a new file that takes the folder's
  permissions. The rest of the install keeps Program Files' defaults.
- Creates the task "LWCam QC Server" (SYSTEM, at boot) and replaces the firewall
  rule "LWCam QC Server" for the configured port (default 8080), on every network
  type, for the local subnet and Tailscale only. Then starts the task.
- The console is at `https://<pc-name>:8080/`. On a split site, set `qcInputRoot`
  (in `config.txt` or the console's Settings) to the same UNC path LWIP writes to.

### LWIPSetup.exe

- Installs LWIP with its own offline Python runtime and the task "LWCam LWIP"
  (SYSTEM, at boot).
- Asks for the input folder (where LWCAM copies finished captures), the output
  folder (what the QC server reads), then the database connection. The folder
  pages and the database page are skipped on an upgrade once
  `config\deskew_crop_config.json` exists.
- A mapped drive letter is refused for either folder. SYSTEM cannot see a drive
  mapped in a user's session. Use a UNC path or a local fixed drive.
- Serves a console over HTTPS on port 8090 (`ui_port`). A "LWIP Console"
  Start-menu shortcut opens it. The "LWCam LWIP" firewall rule opens the port for
  the local subnet and Tailscale. Sign in with an Admin or SuperAdmin account.
  If the database is unreachable, the console is read-only.
- Taking over folders an older LWIP already processed: stop the service, copy the
  old journal to `{app}\runtime\state.json`, then start it. It matches only when
  `input_root` is the same path string as before. Without the journal LWIP
  re-adopts every finished folder whose pages still match its manifest. A folder
  whose page files changed since (for example a QC page replacement) is processed
  again from the originals.
- Stop it with the file `%ProgramData%\LWCAM\lwip.stop`. It exits within about
  90 seconds.

### LWCamUploadSetup.exe

- Installs Upload with its own offline Python runtime and the task "LWCam Upload"
  (SYSTEM, at boot).
- Asks for the watch folder (QC's `qcOutputRoot`), the Uploaded folder, and the
  Upload Reports folder (where `Upload_Summary.db3` goes). The wizard needs all
  three, because Inno's folder page refuses a blank path. You can clear the last
  two later in the console. Then it asks for the S3 destination (`s3://bucket/prefix`,
  region, access key, secret key) and the database connection. The three pages
  are skipped on an upgrade once `config\upload_config.json` exists.
- Mapped drive letters are refused for the three folders.
- Serves a console on port 8091. The "Upload Console" shortcut and the
  "LWCam Upload" firewall rule work as for LWIP. The database login is only for
  console sign-in and status. S3 uploads use the access key and secret.
- Settings are re-read at the start of every scan, so a console save needs no
  restart.

### LWCamSetup.exe

- Installs LWCAM and LWCam Admin only. No LWIP, no PostgreSQL.
- Takes no product-specific parameters. It has no database or folder page. After
  install, open LWCam Admin, complete Station Setup with the values the other
  installers show, and press Save.
- It keeps its original AppId, so an older all-in-one station upgrades in place.
  During such an upgrade it stops and removes an old LWIP under `{app}\LWCAM\LWIP`
  and an old all-in-one QC engine, and deletes the old per-user LWIP logon entry.
  Existing capture data is left in place.

## Services, locks, upgrade and uninstall

- The three services (QC, LWIP, Upload) are scheduled tasks with no run-time
  limit. Task Scheduler restarts a failed task every minute. Each
  `START_*.bat` restarts a crashed program after 30 seconds (exit code 0 means a
  deliberate stop, so no restart).
- Every installer that runs a background process stops it before it replaces any
  file, and aborts with a message if it will not stop. It ends the task first, so
  the restart loop does not undo the stop.
- QC, LWIP and Upload lock their install folder. LWIP and LWCam also lock
  `%ProgramData%\LWCAM`, which holds the shared stop file. Administrators and
  SYSTEM can write. Other users can only read. Each `config\` folder keeps a
  stricter list.
- Uninstall keeps what cannot be rebuilt: LWIP's `runtime\state.json` (and
  `.bak`, the list of folders already processed, so a reinstall does not
  reprocess them over QC's edits), Upload's `runtime\uploads.json` (the list of
  packages already sent, so a reinstall does not send them again), and
  LWCamDatabaseSetup's `config\database.txt`. A reinstall reuses all three.
  Delete the install folder by hand for a clean start.
- Upgrade order, backups and rollback for a multi-PC site:
  [../docs/INSTALL.md](../docs/INSTALL.md) (Upgrade).

## Unattended install

Every installer accepts Inno Setup's standard switches:

```
Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\logs\x.log" /PARAM=value ...
```

`/VERYSILENT` hides the wizard. `/SUPPRESSMSGBOXES` answers message boxes with
the default. `/NORESTART` stops a reboot. `/LOG` writes the only record of what
an unattended run did. Parameter names are not case-sensitive.

A silent run takes each custom page's values from parameters. It validates them
the same way, with the same wording, as the wizard. A missing or invalid value
fails setup before any file is written (Setup exit code 7). A page the wizard
would skip (an upgrade, once its config exists; the database page on a fresh
local PostgreSQL install without `/TASKS=remotedb`) is skipped too. Its
parameters are ignored.

Examples and parameters (use `^` as the line continuation in `cmd`):

```
LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /LOG="C:\logs\db.log" /TASKS="openlan" /APPUSER=lwcam_user /APPPASSWORD=<password>

LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /LOG="C:\logs\db.log" /TASKS="remotedb" ^
  /DBHOST=<db-host> /DBUSER=postgres /DBPASSWORD=<admin password> ^
  /APPDB=lwcam /DBPORT=5432 /APPUSER=lwcam_user /APPPASSWORD=<password>

QCPlatformSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>

LWIPSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /INPUTROOT="\\<server>\lwcam-input" /OUTPUTROOT="\\<server>\lwcam-output" ^
  /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>

LWCamUploadSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /WATCHROOT="\\<server>\lwcam-output" /DONEROOT="\\<server>\lwcam-uploaded" ^
  /SUMMARYROOT="\\<server>\lwcam-reports" ^
  /S3PATH="s3://<bucket>/<prefix>" /S3REGION=<region> ^
  /S3ACCESSKEY=<key id> /S3SECRET=<secret> ^
  /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>
```

| Installer | Parameters |
| --- | --- |
| Database | `DBHOST` (default `localhost`), `DBUSER` (default `postgres`), `DBPASSWORD`: the PostgreSQL administrator login. Needed whenever the connection page would not be skipped. `APPDB` (default `lwcam`), `DBPORT` (default 5432; on a fresh install PostgreSQL is installed on it, and a port in use fails the install), `APPUSER` (default `lwcam_user`), `APPPASSWORD` (no default; a silent install without it, or with fewer than 12 characters, fails before anything is written; on a re-run leave it out to keep the saved one). `BACKUPDIR`, `BACKUPKEEP` (default 14, 1 to 365; an invalid value fails the install; a folder on PostgreSQL's drive only logs a warning). |
| Database `/TASKS` | `openlan` (ticked by default. Dropping it from `/TASKS` closes access an earlier run opened.) and `remotedb` (unticked by default). `/TASKS` replaces the whole selection. Pass `openlan,remotedb` to keep both. A fresh local install with neither task also needs the PostgreSQL 18 installer beside the setup file. |
| QC | `DBHOST`, `DBPORT` (5432), `DBNAME` (`lwcam`), `DBUSER` (`lwcam_user`), `DBPASSWORD` |
| LWIP | `INPUTROOT`, `OUTPUTROOT` (both required, no mapped drive letters), plus the five database parameters |
| Upload | `WATCHROOT`, `DONEROOT`, `SUMMARYROOT` (all three required), `S3PATH`, `S3REGION`, `S3ACCESSKEY`, `S3SECRET`, plus the five database parameters |
| LWCam | None. Optional `/DIR=` for another install folder. |

Command-line values are not private. While Setup runs, any process on the PC can
read its command line. Inno also writes Setup's whole command line at the top of
a `/LOG` file, so `/DBPASSWORD`, `/APPPASSWORD`, `/S3ACCESSKEY` and `/S3SECRET`
land there in plain text. Run unattended installs from a script that only an
administrator can read. Delete or protect the log afterwards.

## Passwords at rest

Installers and consoles store these as `dpapi:...` values (Windows DPAPI, tied to
the PC). The installer encrypts them right after it writes the file. A service
that finds a plain value (an older install) encrypts it at start-up.

| Part | File | Encrypted keys |
| --- | --- | --- |
| QC | `config\config.txt` | `dbPassword`, `jwtSecret`, `openrouterApiKey` |
| LWIP | `config\deskew_crop_config.json` | `db_password` |
| Upload | `config\upload_config.json` | `db_password`, `s3_secret_key` |
| Database | `config\database.txt` | `dbPassword`, `appPassword` |

The installer, an administrator and the SYSTEM service on that PC can read them.
A copy of the file on another PC cannot be decrypted. The part says so and asks
for the password again in its console, or for setup to run again. DPAPI does not
protect against an administrator signed in on the same PC. If an installer cannot
encrypt a file, its finish page says so. Run setup again as Administrator.

## SYSTEM account and UNC shares

QC, LWIP and Upload run as SYSTEM. SYSTEM cannot see a drive mapped in a user's
session. Use UNC paths (`\\server\share`) for LWIP's input and output folders,
QC's input root, and Upload's three folders. Each installer refuses a mapped
drive letter.

SYSTEM reaches another PC's share as `<COMPUTERNAME>$` (the computer account).
On a domain, give that account the share and NTFS permissions. In a workgroup
the other PC refuses it ("Access is denied"). Save a login instead. Every
console (QC 8080, LWIP 8090, Upload 8091) has a "Network folder logins" section.
Enter the other PC's name, a user on that PC and its password.

- The list is per PC, not per service. A login saved in one console is used by
  every LWCam service on that PC. Windows allows one account per remote PC.
- Services on different PCs: save the login once on each PC that reaches the
  share. Each console lists the other PCs its folders point at, marks the ones
  with no login, and "Test folder access" tries every folder.
- Use an account that can reach only the LWCam folders, not an administrator.
- The list is in `%ProgramData%\LWCAM\network-logins\` (SYSTEM and
  Administrators only, passwords DPAPI-encrypted, never shown or logged). The
  services sign in again every two minutes, so shares work after a reboot and come
  back when the other PC does. Uninstalling one service leaves the list.
- When Upload's `done_root` is on another volume than the export share, a finished
  package is copied, then deleted over SMB. That is slower. The Upload login needs
  delete rights on the export share.

## HTTPS for the three consoles

Each server PC makes its own certificate authority and certificate the first time
QC, LWIP or Upload is installed there. They are in `%ProgramData%\LWCAM\tls`
(SYSTEM and Administrators only, because they hold the private keys). The
certificate covers the PC name, its IP addresses and its Tailscale name. The
services renew it at every start. After an IP change, restart the service. No new
install and no new trust step is needed. QC, LWIP and Upload on one PC share one
certificate authority.

The consoles answer on `https://<pc-name>:8080/` (QC), `:8090/` (LWIP) and
`:8091/` (Upload). Plain `http` on those ports does not answer.

**Trust step.** Do this once for each PC that opens the pages, and once for each
server PC it uses. No administrator is needed.

1. Copy `Trust this LWCam server.cmd` and `LWCam server certificate.crt` from the
   server's install folder to the browser PC. Keep them together.
2. Double-click the `.cmd`.
3. Close and reopen the browser.

Chrome and Edge use the Windows store that the `.cmd` fills. Firefox has its own
store: Settings, Privacy & Security, Certificates, View Certificates,
Authorities, Import. Choose `LWCam server certificate.crt` and tick "Trust this
CA to identify websites". Until the trust step is done, the browser shows a
certificate warning. The page still works.

## Schema level messages

Each part reads `schema_migrations` at start-up and on every reconnect.

- QC console (System status page and banner), LWIP and Upload say: "The database
  is older than this program (needs level N, has M). Run LWCamDatabaseSetup on the
  database PC." The part does no database work until the database is upgraded,
  then continues by itself.
- LWCAM says the same where it syncs. Capture keeps working and records wait in
  the PC's own queue.
- LWCam Admin's Station Setup says the database setup must run again.
- "has 0" means there is no `schema_migrations` table yet. Run `LWCamDatabaseSetup`.

## System status page (QC console)

QC console, System status (a banner "Something needs attention" on every screen
links to it) lists every part that has reported to the database: QC, QC export,
LWIP, Upload, the nightly backup, and each capture PC. Times use the database's
clock, so PCs with different clocks compare fairly. It also shows each part's
version (`<version>+<commit>`) and the database level against what QC needs.

| Colour | Meaning |
| --- | --- |
| Green | The part reported recently and has nothing wrong. |
| Red | Silent for more than 5 minutes (Upload: 15), or its newest error is newer than its last success, or it has a backlog problem (see below). A capture PC is red only for held records, records unsent for over an hour, or an error. |
| Grey | A capture PC that is simply off ("offline since ..."). Not a fault. |
| "Never reported" (red) | QC, QC export, LWIP, Upload and backup always have a row. This part is not installed, not configured, or cannot reach the database. |

"Forget this PC" removes a row for a retired or renamed PC. It returns if that PC
reports again. Rows not seen for over 7 days are hidden unless "Show PCs not seen
for over 7 days" is ticked. The database PC sends no heartbeat except the backup
task. If the database is down, every part turns red or grey and the page itself
cannot load.

Each part also says in one sentence when a folder it needs cannot be reached (for
example "Input folder \\server\input is unreachable"). The sentence clears when
the folder answers again.

| Part | Signal (backlog key) | Red when |
| --- | --- | --- |
| LWIP | `unreported`, `oldest_unreported_minutes` (finished folders not yet in the database) | `oldest_unreported_minutes` > 120 |
| Upload | `last_scan_minutes_ago`, `scan_interval_minutes` | `last_scan_minutes_ago` > the larger of 15 and 3 x `scan_interval_minutes` |
| Upload | `db_pending` (uploaded, result not yet written back) | Never red by itself |
| Capture | `transfers_waiting`, `oldest_transfer_wait_minutes` | `oldest_transfer_wait_minutes` > 60 |
| QC | `approved_not_exported`, `oldest_approved_minutes` | `approved_not_exported` > 0 and `oldest_approved_minutes` > 30 |
| QC | `exports_busy` (another export holds the folder's lock) | Never red by itself |
| QC | `input_unreachable` | true (QC cannot see LWIP's output) |
| QC export | `last_error` (the export preflight error) | An error newer than the last success |

## When another PC is off

Every part queues and retries. None blocks capture.

- Database down: capture PCs keep capturing and save every record and image on
  the PC. Records sync when the database returns (attempts back off). The
  consoles show status read-only. Nobody can change settings from a remote
  browser.
- Held records (capture PCs): a record the database keeps refusing (20 failed
  attempts) is held, not deleted. It stays on the capture PC and shows as "held"
  on the status page. Fix the cause, then press "Try again" in LWCAM.
- LWIP or QC PC off: finished captures wait in the input folder or the database
  queue. Upload off: exported packages stay in QC's output folder.
- A share on another PC is off: the service retries every two minutes and the
  folder comes back by itself.

## Read next

- [../docs/INSTALL.md](../docs/INSTALL.md): install, upgrade, backup and restore, step by step.
- [../docs/RELEASING.md](../docs/RELEASING.md): build and publish a release.
- [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md): how the parts connect.
- Module READMEs: [LWCAM](../LWCAM/README.md), [LWCamAdmin](../LWCamAdmin/README.md),
  [LWIP](../LWIP/README.md), [QC Platform](../LWCam_QC_Platform/README.md),
  [Upload](../LWCam_Upload/README.md).
