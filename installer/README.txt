LWCam installers
================

This folder builds five Windows installers from the source tree:

  LWCamDatabaseSetup.exe  PostgreSQL (installed here, or an existing server),
                          the LWCam schema, opened to the LAN
  QCPlatformSetup.exe     Standalone QC server, Vue console, review and export
  LWIPSetup.exe           LWIP: deskew/crop image processing, as a SYSTEM service
  LWCamUploadSetup.exe    Upload: sends QC's exported packages to S3, as a
                          SYSTEM service
  LWCamSetup.exe          LWCam Capture and LWCam Admin, for capture PCs

Site install order: LWCamDatabaseSetup first (once, on the database PC), then
QCPlatformSetup, LWIPSetup and LWCamUploadSetup (once each, on their own PCs,
in any order), then LWCamSetup on every capture PC. Each of the other four
needs the database's host, port, database name, user and password (ONE login
shared by every part - see "Database login"), which LWCamDatabaseSetup's
finish page shows; LWCamSetup and QCPlatformSetup also
need LWIP's output folder, which LWIPSetup's finish page shows; and Upload
needs the QC server's export output folder, which QCPlatformSetup's finish
page shows. QC no longer uploads anything itself - it only reviews and
exports; Upload is the only app that talks to S3.

Every part checks the database's schema level (the highest number in its
schema_migrations table: 8 for QC, 7 for the others) and refuses to work
against an older database. So on an UPGRADE the database PC's
LWCamDatabaseSetup always runs BEFORE any other part is upgraded - see
"Upgrading a multi-PC site" below. Nothing here assumes the parts share a PC:
each can be on its own machine, at its own site, reached over the LAN or
Tailscale (MagicDNS names work as hosts), and any one of them can be off
without stopping the others (see "What happens when another PC is off").

Only LWCamDatabaseSetup installs PostgreSQL, when a local server is needed, or
uses an existing server on another PC. The PostgreSQL installer is a separate
file beside LWCamDatabaseSetup.exe. Ship them together; a PC that already has
PostgreSQL needs only the setup executable.

Build
-----

Prerequisites:

  Inno Setup 6
  Flutter release build output for LWCAM and LWCamAdmin
  Node.js and npm
  The staged, gitignored inputs listed below

Build the Flutter apps:

  cd ..\LWCAM      && flutter build windows --release
  cd ..\LWCamAdmin && flutter build windows --release

Compile one installer or all five:

  .\build-installer.ps1 -Target Database
  .\build-installer.ps1 -Target QC
  .\build-installer.ps1 -Target LWIP
  .\build-installer.ps1 -Target Upload
  .\build-installer.ps1 -Target LWCam
  .\build-installer.ps1 -Target All

The QC target runs npm ci (when package-lock.json exists, so the console is built
from the locked versions) and npm run build in LWCam_QC_Platform\frontend before
compiling.
Outputs land at the repository root, beside LWCAM\ and installer\. The script
checks each target's release/build inputs, and for Database copies the newest
staged postgresql-18.*-windows-x64.exe beside LWCamDatabaseSetup.exe. It does
not run an installer.

Version: the one-line VERSION file at the repository root (1.1.0) plus the short
git commit (with "-dirty" appended when the working tree has uncommitted changes,
so a build that is not exactly a commit says so) are passed to every ISCC run as /DAppVer and /DBuildId, and every
installer writes "<version>+<commit>" to VERSION.txt in its install folder (for
LWCam: beside lwcam.exe and lwcam_admin.exe, and in the root). Bump VERSION by
hand for a release. The script writes installer\vendor\VERSION.txt for this;
compiling an .iss directly with ISCC needs that file to exist.

Use -ResolveOnly to print the selected ISCC and scrcpy paths without building.
The LWCam target uses LWCAM\scrcpy when it contains scrcpy.exe, or resolves the
installed scrcpy package. Pass -ScrcpyDir to select another Windows build.

Products
--------

LWCamDatabaseSetup.exe

  Installs PostgreSQL 18 (unless a server is already present or the "use an
  existing server" choice is made), then creates or upgrades the LWCam schema,
  creates the one shared LWCam database login you choose (see "Database login"
  below) and, when the "Allow other PCs on this network (and Tailscale) to connect" task is
  ticked and the database is on this PC, opens PostgreSQL to the network
  (listen_addresses, pg_hba.conf, and a "LWCam Database" firewall rule on every
  network type, limited to the local subnet and Tailscale). Unticking that task
  on a later run closes it again: the pg_hba.conf entries and the firewall rule
  are removed. Both the PostgreSQL administrator connection (setup and backups
  only) and the shared LWCam login are written to config\database.txt (private
  folder, SYSTEM and Administrators only). The finish page shows the host,
  port, database name, user and the password you typed, to be entered in
  QCPlatformSetup, LWIPSetup, LWCamUploadSetup and LWCam Admin's Station Setup
  on every capture PC; it says only where the PostgreSQL administrator
  password is kept. config\logins.txt is no longer written or shown; the installer
  deletes an old one.
  It never removes PostgreSQL or its data on uninstall: other stations and apps
  may still depend on it. The program folder is locked (Administrators and
  SYSTEM write, ordinary users read only) before the nightly SYSTEM backup task
  is registered; if it cannot be locked the task is NOT registered and the finish
  page says so.

  When setup_qc_db.py refuses something (below) the finish page shows its own
  message and setup ends "needs attention"; the same text is the last [ERROR]
  line of logs\database-setup.log. Nothing is changed by a refusal.
    - a refused --app-login (a user or password the rules do not allow, or a
      name that is already a superuser): choose another on the "LWCam database
      login" page and run the installer again.
    - "lock timeout": the site was busy while the migrations ran; nothing was
      changed. Run the installer again.
  A kept config\database.txt from an earlier uninstall is reused - unless
  PostgreSQL itself was reinstalled in this run (a fresh cluster has a NEW
  password): then the old file is renamed database.txt.bak-<time> and a new one
  is written. On any other re-run the "LWCam database login" page is prefilled
  from database.txt; leave both password boxes blank to keep the saved
  password. Changing the port there on a server that already exists does NOT
  move PostgreSQL: it only changes what the firewall rule and every part are
  told, so set it to the port the server really listens on.

Database backups (LWCamDatabaseSetup)

  A wizard page asks for the backup folder and how many backups to keep
  (default: the newest 14). The folder defaults to D:\LWCam Backups when the PC
  has a D: hard disk, else C:\ProgramData\LWCam\Backups. A trailing backslash is
  ignored. The folder is locked to Administrators, so setup REFUSES a drive
  root (D:\), C:\Windows, Program Files, ProgramData, C:\Users and any folder that
  already holds other files - pick a new folder of its own, or one that already
  holds lwcam-*.dump files from an earlier run. Use another drive or
  a network share, not the drive PostgreSQL is on: the installer warns when
  they are the same (it assumes PostgreSQL's data is on the Program Files
  drive). A network share is written \\server\share; the backup runs as SYSTEM,
  which reaches the share as THIS PC's computer account (DOMAIN\PCNAME$), so
  give that account write access on the share. A mapped drive letter (Z:) is
  refused. A local backup folder is locked to SYSTEM and Administrators (a
  backup contains every login hash); a share is not touched.

  Setup registers the task "LWCam Database Backup": every day at 02:00 as
  SYSTEM, it runs BACKUP_DATABASE.bat, which writes lwcam-YYYYMMDD-HHMM.dump
  (PostgreSQL custom format) AND lwcam-globals-YYYYMMDD-HHMM.sql (pg_dumpall
  --globals-only: the database roles with their password hashes - the LWCam
  login) to the folder and deletes the oldest of both beyond the keep count.
  The .dump alone does not contain the logins; the globals file is what lets a
  rebuilt database PC accept the same login the other PCs already use. If a night's backup fails the task retries 3 times, 10 minutes
  apart; either way the result is in logs\backup.log (rolled at 10 MB) and in
  the database's service_heartbeat table (part "backup"), which the consoles
  read. Settings are in config\backup.txt (backupDir, backupKeep); the database
  password for pg_dump comes from database.txt (decrypted, handed to pg_dump through its
  environment only; the old config\pgpass.conf is deleted).
  Both are kept on uninstall together with database.txt; the task is removed.
  "Run a backup now" on the finish page is ticked by default: leave it, it
  proves the folder and the pg_dump login work before you walk away.
  Silent: /BACKUPDIR="D:\LWCam Backups" /BACKUPKEEP=14 (on a re-run, whatever
  is not on the command line keeps its saved value).

  Restoring on the SAME PC (plain English): a restore REPLACES the current
  database with the one in the backup file, so anything saved since that backup
  is lost.
    0. Stop or pause everything that uses the database on OTHER PCs: close the
       capture apps, and stop the QC, LWIP and Upload services if they run
       elsewhere. This script can only stop the ones on this PC; a restore under
       a running service fails on open connections or corrupts its work.
    1. On the database PC, open Start, type cmd, right-click "Command Prompt",
       Run as administrator.
    2. Run:  "C:\Program Files\LWCam Database\RESTORE_DATABASE.bat" "D:\LWCam Backups\lwcam-20260930-0200.dump"
       (use the real install folder and the file you want).
    3. Type YES when asked (add /y after the file name to skip the question).
    The script first takes a safety dump of the CURRENT database
    (pre-restore-YYYYMMDD-HHMM.dump in the backup folder) and stops if that fails;
    stops only the LWCam QC Server / LWIP / Upload tasks that exist AND are
    running on this PC, and starts only those again; restores in ONE transaction
    (a failed restore changes nothing); and uses the newest PostgreSQL client
    tools installed. Messages such as "does not exist, skipping" are normal.
    Then start the services on the other PCs.

  Rebuilding the database PC on NEW hardware (the old PC is gone). Keep a copy
  of the backup folder (the newest .dump AND its lwcam-globals-*.sql) and of the
  old PC's config\database.txt (it holds the LWCam login) somewhere other than
  the old PC.
    1. Install PostgreSQL by running LWCamDatabaseSetup.exe on the new PC (with
       the PostgreSQL installer beside it). Give it the SAME PC name or address
       the other PCs use, or edit each part's database host afterwards. Tick
       "Allow other PCs". On the "LWCam database login" page type the SAME database
       name, port, user and password as before (from the old database.txt): then
       nothing else needs editing. (Run it once, then continue; it creates an
       empty schema.)
    2. If you do not have the old login: apply the globals file so the roles come
       back with their old password hashes. On the new PC, as administrator:
         "C:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U postgres -d postgres -f "D:\...\lwcam-globals-YYYYMMDD-HHMM.sql"
       Messages that a role "already exists" are harmless.
    3. Restore the data with RESTORE_DATABASE.bat as above (the newest .dump).
    4. Run LWCamDatabaseSetup.exe again: it brings the schema and grants to the
       current level and (with "Allow other PCs") reopens the network access.
    5. Check the QC console's System status page: every part goes green within
       a few minutes as it reconnects. If a part cannot sign in, its login was
       not restored: enter the login from the old database.txt in that part.

Database login (LWCamDatabaseSetup)

  Every part connects with ONE login, chosen on the "LWCam database login"
  page: the database name (default lwcam), the port (default 5432, or the
  saved / existing server's port; 1024-65535; a fresh PostgreSQL is installed
  on it and a port already in use is refused), the user (default lwcam_user)
  and a password of at least 12 characters, typed twice. The user is an
  ordinary member of the group role lwcam_app, which the migrations grant
  exactly what the parts need (column-level for UPDATE; no CREATE, no
  superuser/createdb/createrole, export sequences USAGE only). The same values
  go into every part, so note them:

    QCPlatformSetup            (the QC server's config\config.txt)
    LWIPSetup                  (or the LWIP console, port 8090)
    LWCamUploadSetup           (or the Upload console, 8091)
    LWCam Admin > Station Setup on every capture PC (used by LWCAM and by
      LWCam Admin; saved encrypted for that Windows account, not as plain text)

  The finish page shows Host, Port, Database, User and the password you typed,
  and where the PostgreSQL administrator password is kept (config\database.txt,
  SYSTEM and Administrators only: appUser / appPassword / dbName / dbPort
  beside the administrator login that only setup and backups use). Trade-off:
  one password for every part, so a leaked password can read and edit the
  LWCam tables from anywhere the network admits it; it still cannot run
  programs on the database PC, create tables or drop the database. Change it by
  running LWCamDatabaseSetup again with the new password, then update every
  part.

  How the password travels: setup_qc_db.py never takes it on a command line.
  LWCamDatabaseSetup puts it in the LWCAM_APP_PASSWORD environment variable of
  its own process just before it runs SETUP_DATABASE.bat, and clears it again
  afterwards; the batch file and Python inherit it, so it is never on a command
  line, in a temp file or in the setup log. (Run SETUP_DATABASE.bat by hand
  and it reads the password from config\database.txt instead.) One caveat: a
  SILENT install takes /APPPASSWORD= on its own command line, and Inno's /LOG
  writes that command line - delete or protect the log file.

  Earlier installs used five logins (lwcam_qc, lwcam_lwip, lwcam_upload,
  lwcam_capture, lwcam_admin). Any that exist are made members of lwcam_app, so
  a part that still uses one keeps working. Move each part to the shared login
  at your own pace; config\logins.txt from those installs is no longer written
  or shown, and the Database installer deletes it.

  From other PCs only members of lwcam_app may connect (pg_hba.conf), to the
  configured database, from the local subnet and the Tailscale ranges
  (100.64.0.0/10 and fd7a:115c:a1e0::/48). The same three networks are allowed by every installer's
  firewall rule (Database: the chosen port, QC 8080, LWIP 8090, Upload 8091), on every
  Windows network type - Tailscale's adapter is often labelled "Public".
  pg_hba.conf is backed up to pg_hba.conf.bak-<time> before any change, and
  only the PostgreSQL service that owns that data folder is restarted (and only
  when listen_addresses changed).

  Upgrading an existing site: see "Upgrading a multi-PC site" below. In short,
  the login is created and the old "host all all samenet" pg_hba.conf line is
  KEPT, so every part keeps working on postgres (or its old login) until you
  enter the shared login in that part.

  Networks: a PC at another site that is NOT on Tailscale and NOT on the same
  subnet is not admitted: either put it on Tailscale (the recommended setup for
  several sites) or add a "hostssl <database> +lwcam_app <address>/32
  scram-sha-256" line to pg_hba.conf by hand.

  Old-rule clean-up (automatic, whenever "Allow other PCs" is ticked): setup
  removes the old "host all all samenet" line itself, so postgres and every
  login outside lwcam_app are refused from other PCs - unless such a login is
  still connected from another PC. Then the line is KEPT, setup still succeeds,
  and the finish page (and logs\database-setup.log) shows one [NOTE] line naming
  who, e.g. "Kept the old rule that lets 'postgres' in from other PCs, because
  these are still connected that way: postgres@100.90.100.64." Switch those
  parts to the shared login, then run LWCamDatabaseSetup again. Another, broader
  non-TLS pg_hba.conf line only gets a WARNING in the log. There is no
  strictlogins task any more (an old /TASKS list that still names it is
  ignored by Inno Setup); --force-strict (setup_qc_db.py by hand) removes the
  line even while such logins are connected, and cuts those PCs off. On the
  database PC itself postgres still works, for setup and migrations.

Passwords at rest
-----------------
The passwords and keys in the service config files are stored encrypted
("dpapi:..." instead of the text), each installer encrypts them right after it
writes the file, and the consoles encrypt what they save:
  QC        config\config.txt              dbPassword, jwtSecret, openrouterApiKey
  LWIP      config\deskew_crop_config.json db_password
  Upload    config\upload_config.json      db_password, s3_secret_key
  Database  config\database.txt            dbPassword, appPassword
The encryption is Windows DPAPI tied to THIS PC (the installer, an administrator,
and the SYSTEM service can all read it). It protects a COPY of the program folder
or of a config file taken to another PC: the values cannot be decrypted there (the
service says so and asks for the password to be entered again in its console, or
setup to be run again). It does not protect against an administrator signed in
on the same PC, who can always run the program and read what it reads. A service
that finds a plain value in its file (an older install) encrypts it when it
starts. If an installer cannot encrypt the file it says so on its finish page;
run setup again as Administrator.
Backups (the .dump and globals files) are NOT encrypted: they hold every login
hash. Keep the backup folder private.

Schema level and what the parts say about it
--------------------------------------------

Each part reads schema_migrations at start-up and on every reconnect.
  - QC console (System status page and banner), LWIP and Upload: "The database
    is older than this program (needs level N, has M). Run LWCamDatabaseSetup on
    the database PC." The part does no database work until it is fixed and
    checks again by itself - no restart.
  - LWCAM (capture): the same sentence appears where it syncs; capture itself
    keeps working and everything waits in the PC's own queue (below).
  - LWCam Admin: Station Setup says the database needs re-running the setup.
  - "has 0": the database has no schema_migrations table yet - run
    LWCamDatabaseSetup.

System status page (QC console)
-------------------------------

QC console > System status (a banner "Something needs attention" on every
screen links to it) lists every part that has reported to the database: QC, the
QC export sweep, LWIP, Upload, the nightly backup, and each capture PC. Times
are the database's own clock, so PCs with different clocks are compared fairly.
  - Green: the part reported recently and has nothing wrong.
  - Red: silent for more than 5 minutes (Upload: 15), or its newest error is
    newer than its last success, or it has a backlog problem (export failures,
    LWIP failed folders or folders waiting over 2 hours, Upload failed
    packages). A capture PC is red only for held records, records unsent for
    over an hour, or an error.
  - Grey: a capture PC that is simply off ("offline since ..."). Not a fault.
  - "Never reported": QC, QC export, LWIP, Upload and backup always have a row;
    one that has never reported shows red with that text - the part is not
    installed, not configured, or cannot reach the database.
  - "Forget this PC" removes a row for a PC that was retired or renamed; it
    comes back by itself if that PC reports again. Rows not seen for over 7
    days are hidden unless "Show PCs not seen for over 7 days" is ticked.
The page also shows each part's version (<version>+<commit>) and the database
level against what this QC needs. The database PC itself sends no heartbeat
except the backup task's; if the database is down every part turns red or grey
at once and the page itself cannot load - see the next section.

What each status-page signal means
  Each part also says, in one plain sentence, when a folder it needs cannot be
  reached (for example "Input folder \\LWIP-PC\input is unreachable"); the
  sentence clears by itself when the folder answers again.

  Part     Signal (backlog key)                     Red when
  -------  ---------------------------------------  -------------------------------
  LWIP     unreported, oldest_unreported_minutes    oldest_unreported_minutes > 120
           (finished folders not yet in the         (database down, schema too old,
           database)                                or folder not yet registered)
  Upload   last_scan_minutes_ago,                   last_scan_minutes_ago > the larger
           scan_interval_minutes                    of 15 and 3 x scan_interval_minutes
           db_pending (uploaded, result not yet     never red by itself: the database
           written back)                            was unreachable after the upload
  Capture  transfers_waiting,                       oldest_transfer_wait_minutes > 60
           oldest_transfer_wait_minutes (jobs       (a capture row is otherwise only
           waiting for the LWIP share)              informational)
  QC       approved_not_exported,                   approved_not_exported > 0 and
           oldest_approved_minutes                  oldest_approved_minutes > 30
           exports_busy (folders skipped because    never red by itself: another export
           another export holds their lock)         is working on them
           input_unreachable                        true (QC cannot see LWIP's output)
  QC       last_error = the export preflight error  an error newer than the last success
  export

Proving a site on real separate PCs
-----------------------------------
Tick these off on the real machines; one PC cannot prove them.
  [ ] SYSTEM SMB login to a real peer: on each service PC, the saved network
      login works for the SYSTEM account (test with a scheduled task or psexec
      -s). Error 1219 appears when QC, LWIP and Upload share one PC and reach
      the same peer with different accounts - use one account per peer.
  [ ] Keeper after the peer reboots: reboot the peer; the service PC reaches
      the share again without anyone logging on, and the status sentence clears.
  [ ] Capture at another site -> LWIP input over Tailscale: measure the copy
      throughput for a real batch; run cmdkey for the interactive Windows user
      on the capture PC; check the copy timeout is long enough for your link.
  [ ] QC with qcInputRoot = LWIP's UNC share: review and approve a normal
      folder and a split folder (one batch that LWIP wrote in parts).
  [ ] Database PC hard power-cycle mid-batch, mid-export and mid-upload: every
      part goes red, then recovers alone, and nothing is lost or duplicated.
  [ ] QC PC power cut mid-export: the folder is exportable again within about
      2-3 minutes (the database drops the dead session and its lock after
      the TCP keepalives that the LAN-access step of LWCamDatabaseSetup sets:
      60 s idle, 10 s interval, 6 tries).
  [ ] Browsers reach every console by MagicDNS name, with Tailscale started
      AFTER the services (the certificate must still match the name).
  [ ] A real S3 bucket upload, including a client-rework re-upload of an
      already-uploaded package.
  Note: when Upload's done_root is on another volume than the export share, a
  finished package is copied and then deleted over SMB. That is slower and the
  Upload login needs delete rights on the export share.

What happens when another PC is off
-----------------------------------

Every part queues and retries; none blocks capture.
  - Database down: capture PCs keep capturing and save every record and image
    on the PC; the records sync when the database returns (attempts back off).
    The QC, LWIP and Upload consoles show status read-only: only a browser on
    that PC sees status without signing in, and an Admin/SuperAdmin who has
    signed in before can sign in from a saved admin list (admin_cache.json,
    refreshed every ten minutes while the database answers). Nobody can change
    settings from a remote browser while the database is down.
  - Held records (capture PCs): a record the database keeps refusing
    (20 failed attempts, e.g. a value the database rejects) is HELD, not
    deleted; it stays on the capture PC and shows on the status page as
    "held". Fix the cause, then press "Try again" in LWCAM for held records.
  - LWIP or QC PC off: finished captures wait in the input folder or the
    database queue and are processed when it returns; the status page shows
    them as waiting. Upload off: exported packages stay in QC's output folder.
  - A share on another PC that is off: the service retries every two minutes
    and the folder comes back on its own ("Network folder logins" below).

Upgrading a multi-PC site
-------------------------

Do these in order. Take your time on 1 and 10: they are the way back.
  1. Back up. On the database PC run BACKUP_DATABASE.bat (or wait for the
     02:00 task) and check the newest lwcam-*.dump and lwcam-globals-*.sql are
     in the backup folder. Keep the OLD installers of every part.
  2. Database PC: run the new LWCamDatabaseSetup with "Allow other PCs" ticked.
     The old postgres line stays while anything still uses it (the finish
     page shows a [NOTE] then), so no part is cut off. Schema level goes to 8.
  3. Note the login you typed on the "LWCam database login" page (or the
     finish page's values; use an administrator-only channel, not e-mail or
     chat), and run one backup so the roles are in a globals file too.
  4. QC PC, LWIP PC and Upload PC: run each new installer over the old one.
     On each, enter the shared login (database, user, password) when the
     installer asks. A part left on an earlier lwcam_qc / lwcam_lwip /
     lwcam_upload login keeps working until you switch it.
  5. Open the QC console's System status page: QC, QC export, LWIP, Upload and
     backup are all green (allow five minutes; Upload fifteen).
  6. Each capture PC, one at a time: upgrade LWCamSetup FIRST, then open LWCam
     Admin > Station Setup and enter the shared login. Never enter the new login
     into a capture PC that still runs an old LWCAM: the old program does not
     know the new grants and will fail.
  7. Check rows: a new capture on an upgraded PC arrives in the QC queue, and
     the capture PC appears on the status page with no "held" records.
  8. Once every part uses the shared login, re-run LWCamDatabaseSetup once; it
     removes the old rule itself (it keeps it and names the logins in a [NOTE]
     if something is still connected).
  9. On every PC that OPENS the web pages (QC, LWIP, Upload consoles): run
     "Trust this LWCam server.cmd" once for each server PC's certificate (see
     "HTTPS" at the end). Addresses are https:// now.
 10. Keep the old installers and the pre-upgrade dump until a full working day
     has run clean, including a rework round trip and a night's backup.

QCPlatformSetup.exe

  Installs the FastAPI backend, built Vue console, and an offline Python
  runtime. It writes config\config.txt only on a fresh install, always asking
  for the database connection (the database must already exist, from
  LWCamDatabaseSetup - this installer no longer creates one). The config folder
  is restricted to SYSTEM and Administrators on every install - it holds the
  database password and the login secret, and a console save replaces the file
  with a new one that takes the folder's permissions; the rest of the install
  keeps Program Files' defaults. It creates the "LWCam QC Server" task to run
  at system startup, replaces the "LWCam QC Server" firewall rule for the port
  set in config\config.txt (8080 unless changed) on every network type, for the
  local subnet and Tailscale only, and starts the task. Its database page asks
  for host, port (autofilled 5432, editable), database name (lwcam), user
  (lwcam_user) and password: the shared LWCam login.

  Open the console at https://<this PC's name>:8080/ (https://localhost:8080/ on
  the PC itself; see "HTTPS" at the end). The first account must be created
  in LWCam Admin User Management. On a split site, set qcInputRoot in
  config\config.txt (or the console's Settings) to the same UNC path LWIPSetup
  writes its output to. QC no longer uploads anything to S3 - that moved to
  LWCamUploadSetup, which watches QC's own export output (qcOutputRoot).

LWIPSetup.exe

  Installs LWIP - the deskew/crop image-processing tool - as its own offline
  Python runtime, run by the "LWCam LWIP" scheduled task (SYSTEM, at system
  startup). The wizard asks for the input folder (where LWCAM copies finished
  captures) and the output folder (LWIP's result, what the QC server reads
  from), then the database connection; both wizard pages are skipped on an
  upgrade, once config\deskew_crop_config.json exists. A mapped network drive
  letter is refused for either folder - SYSTEM cannot see a drive mapped in a
  user's logon session - use a UNC path (\\server\share) or a local fixed
  drive. LWIP reports each finished folder to the database itself, so a batch
  reaches the QC queue even while LWCAM is closed.

  It also serves a small console over HTTPS, on port 8090 by default
  (config\deskew_crop_config.json's ui_port) - a "LWIP Console" Start-menu
  shortcut opens it, and the "LWCam LWIP" firewall rule opens that port on
  every network type, for the local subnet and Tailscale only. Its database
  login is the shared LWCam login (database lwcam, user lwcam_user by
  default; port autofilled 5432 and editable). Sign in with an Admin or SuperAdmin database
  account (the same accounts the QC console uses). If the database cannot be
  reached the console is read-only: a browser on this PC sees status and log
  without signing in, and an admin who signed in before can sign in from the
  saved admin list; nobody else gets in until the database returns.

  Taking over folders an older LWIP already processed: stop the new service,
  copy the old journal (%USERPROFILE%\LWCAM_DBs\lwip\runtime\state.json on an
  all-in-one station) to {app}\runtime\state.json, then start it again. It
  only matches when input_root is the SAME path string as before. Without it,
  LWIP re-adopts every finished folder whose pages still match its manifest,
  which is safe; but a folder whose page files were replaced since, for
  example by a QC page replacement, fails that check and is processed again
  from the originals.

LWCamUploadSetup.exe

  Installs Upload - the S3 upload service - as its own offline Python
  runtime, run by the "LWCam Upload" scheduled task (SYSTEM, at system
  startup). The wizard asks for the watch folder (QC's export output -
  qcOutputRoot), the Uploaded folder (where a sent package is moved to) and
  the Upload Reports folder (where Upload_Summary.db3 is written) - all three
  required by the wizard, since Inno's folder page refuses a blank path; either
  of the last two can be cleared later in the console (blank = leave packages
  in place / write no summary), then the S3
  destination (s3://bucket/prefix, region, access key, secret key), then the
  database connection; all three wizard pages are skipped on an upgrade, once
  config\upload_config.json exists. A mapped network drive letter is refused
  for the watch, Uploaded or Upload Reports folders - SYSTEM cannot see a
  drive mapped in a user's logon session - use a UNC path (\\server\share) or
  a local fixed drive. Rework republished under the same Group ID is
  detected by a content fingerprint and uploaded again, replacing what is
  already in the bucket.

  It also serves a small console over HTTPS, on port 8091 by default
  (config\upload_config.json's ui_port) - an "Upload Console" Start-menu
  shortcut opens it, and the "LWCam Upload" firewall rule opens that port on
  every network type, for the local subnet and Tailscale only. Its database
  login is the shared LWCam login (database lwcam, user lwcam_user by
  default; port autofilled 5432 and editable). Sign in with an Admin or SuperAdmin database
  account (the same accounts the QC console and LWIP console use); this
  login is only for the console, Upload's PUTs to S3 use the access key and
  secret entered in the wizard (or later, in Settings). Settings are re-read
  at the start of every scan, so a console save applies without a restart.

LWCamSetup.exe

  Installs LWCam Capture and LWCam Admin only - no LWIP, no PostgreSQL. It
  keeps the shipped AppId so an existing LW Suite (or split-era LWCam) install
  upgrades in place; an old copy of LWIP under {app}\LWCAM\LWIP and a former
  all-in-one {app}\QC engine are both stopped and removed during upgrade
  (existing capture data is left in place), and the old per-user LWIP logon
  entry is deleted. This station connects to the database and to LWIP over the
  LAN - open LWCam Admin, complete Station Setup with the values
  LWCamDatabaseSetup and LWIPSetup show, and press Save.

  Every installer that runs a background process stops it before any file is
  replaced (LWCamSetup: an old all-in-one QC engine and any old LWIP;
  QCPlatformSetup: the QC server; LWIPSetup: LWIP; LWCamUploadSetup: Upload)
  and aborts with a message if one will not stop.

Unattended install
------------------

Every installer above accepts Inno Setup's standard silent switches, so mass
deployment and automated tests can run it with no one watching:

  Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\path\to\x.log" /PARAM=value ...

/VERYSILENT hides both the wizard and the progress window; /SUPPRESSMSGBOXES
answers every suppressible message box the way the docs say it would if a
person clicked through (Yes to continue, the recommended choice, etc.);
/NORESTART stops Setup rebooting the PC on its own; /LOG writes a detailed
log, which is the only way to see what an unattended run actually did.
Parameter names below (/DBHOST, /INPUTROOT, and so on) are case-insensitive,
as Inno treats every /NAME=value pair.

A silent run gets each custom wizard page's values from these parameters
instead of typed input, validated the SAME WAY and with the SAME WORDING the
wizard would show - a missing or invalid value fails setup before a single
file is written, with that wording appearing in the log (Setup exit code 7 =
"Preparing to Install decided Setup cannot proceed", the same code a
validation failure of Inno's own would return). A page that the wizard would
skip anyway (an upgrade, once its config file already exists; the Database
page, on a fresh LOCAL PostgreSQL install with no /TASKS=remotedb - Setup
invents its own password there) is skipped unattended too, so its parameters
are simply ignored.

LWCamDatabaseSetup.exe (fresh local server, opened to the LAN):

  LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\db.log" /TASKS="openlan" ^
    /APPUSER=lwcam_user /APPPASSWORD=CorrectHorseBattery1

LWCamDatabaseSetup.exe (an existing server elsewhere):

  LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\db.log" /TASKS="remotedb" ^
    /DBHOST=10.0.0.5 /DBUSER=postgres /DBPASSWORD=CorrectHorseBattery1 ^
    /APPDB=lwcam /DBPORT=5432 /APPUSER=lwcam_user /APPPASSWORD=AnotherLongPassword2

  Parameters: DBHOST (default localhost), DBUSER (default postgres) and
  DBPASSWORD (default empty - must be supplied whenever the connection page
  would not be skipped) are the PostgreSQL ADMINISTRATOR login. The shared
  LWCam login: APPDB (default lwcam), DBPORT (default 5432; on a fresh install
  PostgreSQL is installed on it, and a port in use fails the install), APPUSER
  (default lwcam_user) and APPPASSWORD (no default: a silent install without
  it, or with one shorter than 12 characters, fails before anything is
  written; on a re-run it may be left out to keep the saved one). Names follow
  [a-z_][a-z0-9_]{0,62}; postgres and lwcam_app are refused. /TASKS names: openlan (checked by
  default - "Allow other PCs on this network (and Tailscale) to connect"; drop
  it from /TASKS and the run CLOSES access an earlier run opened: pg_hba.conf
  entries and firewall rule removed) and remotedb (unchecked by
  default - "Use an existing PostgreSQL server instead of installing one";
  /TASKS replaces the whole selection, so pass "openlan,remotedb" to keep
  both). A fresh local install with neither task also needs the PostgreSQL
  18 installer beside LWCamDatabaseSetup.exe, exactly as an attended run does.
  Backups: BACKUPDIR (default D:\LWCam Backups if D: is a hard disk, else
  C:\ProgramData\LWCam\Backups) and BACKUPKEEP (default 14, 1-365). An invalid
  value fails the install before any file is written; a backup folder on the
  same drive as PostgreSQL only logs a warning.

QCPlatformSetup.exe:

  QCPlatformSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\qc.log" ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=AnotherLongPassword2

  Parameters: DBHOST, DBPORT (default 5432), DBNAME (default lwcam), DBUSER
  (default lwcam_user), DBPASSWORD (default empty) - the shared LWCam login
  LWCamDatabaseSetup's finish page shows. (postgres still works from other
  PCs until LWCamDatabaseSetup removes the old rule.)

LWIPSetup.exe:

  LWIPSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\lwip.log" ^
    /INPUTROOT="\\FILESERVER\lwcam-input" /OUTPUTROOT="\\FILESERVER\lwcam-output" ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=AnotherLongPassword2

  Parameters: INPUTROOT, OUTPUTROOT (both default empty - the same "neither
  folder can be on a mapped drive letter" rule applies), plus DBHOST, DBPORT
  (default 5432), DBNAME (default lwcam), DBUSER (default lwcam_user),
  DBPASSWORD (default empty).

LWCamUploadSetup.exe:

  LWCamUploadSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
    /LOG="C:\install-logs\upload.log" ^
    /WATCHROOT="\\FILESERVER\lwcam-output" /DONEROOT="\\FILESERVER\lwcam-uploaded" ^
    /SUMMARYROOT="\\FILESERVER\lwcam-reports" ^
    /S3PATH="s3://my-bucket/lwcam" /S3REGION=us-east-1 ^
    /S3ACCESSKEY=AKIAEXAMPLE /S3SECRET=ExampleSecretKey ^
    /DBHOST=10.0.0.5 /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=AnotherLongPassword2

  Parameters: WATCHROOT, DONEROOT and SUMMARYROOT (all three required - a
  blank one fails with Inno's "You must enter a full path" before anything is
  installed, exactly as in the wizard; clear them afterwards in the console),
  S3PATH, S3REGION, S3ACCESSKEY, S3SECRET (all default empty), plus DBHOST,
  DBPORT (default 5432), DBNAME (default lwcam), DBUSER (default lwcam_user),
  DBPASSWORD (default empty).

LWCamSetup.exe takes no product-specific parameters - it has no database or
folder page any more, just the standard silent switches (and /DIR= if the
default install location is wrong for the fleet).

Command-line values are not private. While Setup runs, any other process on
the same PC can read its full command line (Task Manager's Command line
column, WMI, Get-CimInstance Win32_Process, and so on) - a password or S3 key
passed this way is exposed for as long as that install takes. Inno also
writes Setup's ENTIRE command line, verbatim, as the first few lines of a
/LOG file ("Setup command line: ...") - confirmed by running a test build
with a dummy secret parameter and reading it back out of the log, so
/DBPASSWORD, /S3ACCESSKEY and /S3SECRET land in the log in plain text too.
([Run] entries are the one thing Inno does NOT log this way when marked
dontlogparameters - see postgres.iss - but that flag has no effect on
Setup's own command line.) Run unattended installs from a script only an
administrator can read, over a connection only an administrator can see, and
delete or otherwise secure the /LOG file afterwards - do not leave it where
an unprivileged account (or a backup of the install folder) can read it.

Inputs staged outside git
-------------------------

  installer\vendor\python-3.13.14-embed-amd64.zip
  installer\vendor\vcruntime\             Visual C++ runtime DLLs
  installer\vendor\adb\                   adb.exe and its two support DLLs
  installer\vendor\postgresql\             PostgreSQL 18 installer
  LWCAM\scrcpy\                            scrcpy Windows build
  LWIP\tools\                              jpegtran
  LWIP\wheels\                             offline LWIP dependencies (also
                                            supplies pip/psycopg/tzdata to
                                            LWCamDatabaseSetup)
  LWCam_QC_Platform\backend\wheels\         offline QC backend dependencies
  LWCam_QC_Platform\frontend\dist\          built by the QC target
  LWCam_Upload\wheels\                      offline Upload dependencies
                                            (boto3, botocore, s3transfer,
                                            psycopg, bcrypt)

The Python runtimes are built from the embeddable zip and the relevant
wheelhouse on the target with --no-index. A missing wheel is a hard install
failure, not a network download fallback.

Bundled-file checksums
----------------------

installer\SHA256SUMS.txt (committed) pins every input above that is NOT built
from our source: the python zip, vcruntime, adb, the PostgreSQL exe, scrcpy,
LWIP\tools and the three wheelhouses. One line per file, "<sha256>  <path
from the repo root>", sorted, LF. Flutter builds, frontend\dist and
vendor\VERSION.txt are not listed.

build-installer.ps1 hashes the inputs of the selected -Target before any
build and stops with exit 1 if one changed, is missing, or is not listed
("Bundled file changed: <path>. If this change is intended, run
build-installer.ps1 -UpdateChecksums and commit SHA256SUMS.txt"). After an
intended change (new wheel, new adb), run:

  powershell -File build-installer.ps1 -UpdateChecksums

which rewrites the list for all targets and exits; commit the result.

SYSTEM account and UNC shares
------------------------------

LWIPSetup, QCPlatformSetup and LWCamUploadSetup all run their service as
SYSTEM, which cannot see a drive mapped in a user's logon session - use UNC
paths (\\server\share) for LWIP's input/output folders, the QC input root,
and Upload's watch/Uploaded/Upload Reports folders, never a mapped drive
letter (all three installers refuse one where they ask for a folder).

Without a login, SYSTEM reaches another PC's share as this PC's computer
account ("<COMPUTERNAME>$"). On a domain, grant that account the share and
NTFS permissions. Outside a domain (a workgroup) the other PC refuses it -
"Access is denied" - so save a login instead: every console (QC 8080, LWIP
8090, Upload 8091) has a "Network folder logins" section. Enter the other
PC's name, a username on that PC (e.g. FILE-PC\lwcam-share) and its password.

- One list per PC, not per service: a login saved in any console on a PC is
  used by every LWCam service on that PC. Windows allows that PC's services
  only one account per remote PC anyway.
- Services on different PCs: save the login once on each PC that reaches the
  share. Each console lists the other PCs its own folders point at, marks the
  ones with no login, and "Test folder access" tries every folder.
- Use an account with access to the LWCam folders only, not an administrator.
- Stored in %ProgramData%\LWCAM\network-logins\ (SYSTEM and Administrators
  only), the password DPAPI-encrypted; never shown or logged. The services
  sign in again every two minutes, so the folders work after a reboot and
  come back when the other PC does. Uninstalling a service leaves the list,
  since the other services on the PC still use it.

Services, folder locks and uninstall
------------------------------------

- The three services (QC, LWIP, Upload) are scheduled tasks with no run-time
  limit; Task Scheduler restarts a failed task every minute, and each START_*.bat
  restarts a crashed program after 30 s (exit code 0 = deliberate stop, no
  restart). Setup ends the task before it stops the program, so an upgrade or
  uninstall is not undone by the restart.
- QC, LWIP and Upload lock their install folder (and LWIP/LWCam lock
  %ProgramData%\LWCAM, which holds the shared stop file): Administrators and
  SYSTEM write, ordinary users only read. config\ keeps its own stricter list.
- Uninstall keeps what cannot be rebuilt: LWIP's runtime\state.json (+ .bak),
  the list of folders already processed, so a reinstall does not reprocess them
  over QC's edits; Upload's runtime\uploads.json, the list of packages already
  sent, so a reinstall does not upload them again; and LWCamDatabaseSetup's
  config\database.txt (still Administrators-only), since the PostgreSQL password
  cannot be read back from the server. A reinstall reuses all three as they
  are. Delete the install folder by hand to start clean.

The finish page of each installer says only that it is installed and where
its console is; this file is the rest.

Installer sources
-----------------

  Database.iss           Database installer: PostgreSQL, schema, LAN access
  QCPlatform.iss          QC server installer
  LWIP.iss                LWIP installer
  Upload.iss               Upload installer
  LWCam.iss                LWCam Capture + LWCam Admin installer
  common.iss               Shared helpers (PythonProcessesUnder, RestrictToAdmins)
                            - included by every installer, directly or (for
                            Database) through postgres.iss
  postgres.iss             PostgreSQL detection, install, and recovery -
                            included by Database.iss only
  build-installer.ps1      Input checks, frontend build, ISCC compile, sidecar copy
  db\SETUP_DB_RUNTIME.bat  Build the Database installer's offline Python runtime
  db\SETUP_DATABASE.bat    Create/upgrade the schema from config\database.txt
  qc\SETUP_QC.bat          Build and verify the offline QC Python runtime
  qc\START_QC_SERVER.bat   Start run_server.py from the installed backend
  qc\OPEN_QC_LOG.bat       Open the server log

The old START_QC_BACKEND.bat, SETUP_QC_DB.bat, and START_QC_FRONTEND.bat
were removed: all three depended on LWCam Admin's node config, and the first
forwarded its arguments past the host that config.txt sets. START_QC_SERVER.bat
takes no arguments for that reason. qc\SETUP_DB.bat (the QC installer's own,
now-unused database setup wrapper) was removed the same way when database
setup moved to its own installer - db\SETUP_DATABASE.bat is its replacement,
run by Database.iss instead.

HTTPS FOR THE WEB PAGES (QC console, LWIP console, Upload console)
------------------------------------------------------------------
Each server PC makes its own certificate the first time QC, LWIP or Upload is
installed there. It lives in C:\ProgramData\LWCAM\tls (SYSTEM and
Administrators only - it holds the private keys) and covers the PC name, its IP
addresses and its Tailscale name. The services renew it on their own at every
start, so a changed IP address needs a restart of that service, not a new
installation, and nobody has to trust it again.

Addresses change from http:// to https://. Old bookmarks stop working:
    https://<pc name>:8080/  (QC)    https://<pc name>:8090/  (LWIP)
    https://<pc name>:8091/  (Upload)

Trust step, once per PC that opens the pages, once per server PC (no
administrator needed): copy "Trust this LWCam server.cmd" and
"LWCam server certificate.crt" from the server's install folder to that PC,
keep them together, double-click the .cmd, then close and reopen the browser.
Until then the browser shows a certificate warning (the page still works).
Plain http on the same ports no longer answers.

Every PC that opens a page needs the trust step for EACH server PC it uses (QC,
LWIP and Upload on one PC share one certificate authority; on different PCs each
has its own). Chrome and Edge use the Windows store the .cmd fills. FIREFOX uses
its own store: in Firefox open Settings > Privacy & Security > Certificates >
View Certificates > Authorities > Import, choose "LWCam server certificate.crt"
and tick "Trust this CA to identify websites".
