English | [简体中文](INSTALL.zh-CN.md)

# Install LWCam at a site

This guide is for the person who sets up a site. It covers the five installers, the order to run them, the questions each one asks, and how to check, upgrade, back up and remove the system. For building the installers, see [RELEASING.md](RELEASING.md). For terms, see [GLOSSARY.md](GLOSSARY.md).

The most detailed reference is [installer/README.md](../installer/README.md).

## 1. What you install

| Installer | Installs | Runs on |
| --- | --- | --- |
| `LWCamDatabaseSetup.exe` | PostgreSQL 18 (or uses an existing server), the LWCam schema, the shared database login, the nightly backup | The database PC (once per site) |
| `QCPlatformSetup.exe` | QC server and web console (review, approve, reject, export) | The QC PC |
| `LWIPSetup.exe` | LWIP: deskew, crop and thumbnails, as a Windows service | The LWIP PC |
| `LWCamUploadSetup.exe` | Upload service: sends exported packages to S3 | The Upload PC |
| `LWCamSetup.exe` | LWCAM (capture) and LWCam Admin | Every capture PC |

`LWCamDatabaseSetup.exe` needs the PostgreSQL installer file (`postgresql-18.*-windows-x64.exe`) in the same folder. Ship the two files together. A PC that already has PostgreSQL, or a site that uses a server on another PC, needs only the setup file.

You can put all parts on one PC. You can also put each part on its own PC, at its own site. Any part can be off without stopping the others. Each part queues its work and retries.

## 2. Requirements

| Item | Requirement |
| --- | --- |
| Operating system | 64-bit Windows. The installers need administrator rights. |
| Network | The parts reach each other by TCP. Default ports: database 5432, QC 8080, LWIP console 8090, Upload console 8091. |
| Firewall | Each installer adds its own rule. The rule admits the local subnet and Tailscale only. |
| Several sites | Use Tailscale, or add a `hostssl` line to `pg_hba.conf` by hand for each remote address. MagicDNS names work as host names. |
| Shared folders | Use UNC paths (`\\server\share`) or local fixed drives. A mapped drive letter (`Z:`) is refused. The services run as SYSTEM and cannot see mapped drives. |
| S3 | A bucket, a region, an access key and a secret key, for the Upload PC. |
| Capture | An Android phone with USB debugging on, and a USB cable. LWCAM uses adb and scrcpy; both ship in `LWCamSetup.exe`. |
| Browser | Chrome or Edge. Firefox needs a manual step (section 8). |

The installers contain their own Python runtime and offline packages. The PCs need no internet access and no Python.

## 3. Install order

1. **Database PC.** Run `LWCamDatabaseSetup.exe`. Write down the values on the finish page.
2. **QC, LWIP and Upload PCs.** Run each installer on its PC, in any order. Each one asks for the database login.
3. **Every capture PC.** Run `LWCamSetup.exe`. Then open LWCam Admin and complete Station Setup (section 7).

Some values come from other installers:

- QC needs LWIP's output folder (`qcInputRoot`). The `LWIPSetup.exe` finish page shows it.
- Upload needs QC's export output folder (`qcOutputRoot`). The `QCPlatformSetup.exe` finish page shows it.

## 4. One-PC setup

Use this for a test or a small site. Run the installers on the same PC in this order: Database, LWIP, QC, Upload, LWCam. Use `localhost` as the database host. Use local folders, for example:

- `C:\LWCam\1.Images`: LWIP input (where LWCAM copies captures)
- `C:\LWCam\2.Batches`: LWIP output and QC input
- `C:\LWCam\3.Export`: QC output and Upload watch folder

## 5. Multi-PC setup

1. Choose the PCs: one database PC, one or more of QC, LWIP and Upload, and the capture PCs.
2. Create the shared folders on a file server or on one of the PCs. Give the service PCs access (see "SYSTEM account and UNC shares" in [installer/README.md](../installer/README.md)).
3. Run the installers in the order in section 3. Use the database PC's name or address as the database host.
4. On the database installer, tick "Allow other PCs on this network (and Tailscale) to connect".
5. Do the HTTPS trust step (section 8) on each PC that opens a console.

## 6. What each wizard asks

### LWCamDatabaseSetup

| Question | Notes |
| --- | --- |
| Use an existing PostgreSQL server instead of installing one | Unticked by default. Tick it to use a server on another PC. Then it asks for the host, the PostgreSQL administrator user and its password. |
| Allow other PCs on this network (and Tailscale) to connect | Ticked by default. It opens PostgreSQL to the network and adds the firewall rule "LWCam Database". Unticking it on a later run closes the access again. |
| Database name | Default `lwcam`. |
| Port | Default `5432`. Range 1024 to 65535. A port that is in use is refused. On an existing server, give the port the server really uses. |
| User | Default `lwcam_user`. Pattern `[a-z_][a-z0-9_]{0,62}`. `postgres` and `lwcam_app` are refused. |
| Password | At least 12 characters. Type it twice. |
| Backup folder and number to keep | Default folder `D:\LWCam Backups` if the PC has a D: disk, else `C:\ProgramData\LWCam\Backups`. Default keep: 14. Use a new, empty folder, on another drive than PostgreSQL. |

One shared login serves every part. Write down the host, port, database, user and password. You enter them in QC, LWIP, Upload and LWCam Admin. The finish page shows them. The PostgreSQL administrator password stays in `config\database.txt` (Administrators and SYSTEM only).

### QCPlatformSetup

Asks for the database host, port (default 5432), name (default `lwcam`), user (default `lwcam_user`) and password. On a fresh install it writes `<install>\config\config.txt`. The console listens on port 8080. To change the port or the folders, edit `config.txt` or use the console's Settings page. On a split site, set `qcInputRoot` to LWIP's output folder (a UNC path).

### LWIPSetup

Asks for the input folder (where LWCAM copies finished captures), the output folder (what QC reads), and the database login. It skips these pages on an upgrade. The console is on port 8090.

### LWCamUploadSetup

Asks for the watch folder (QC's export output), the Uploaded folder, the Upload Reports folder, the S3 destination (`s3://bucket/prefix`, region, access key, secret key) and the database login. The console is on port 8091. You can change the S3 settings later in the Upload console.

### LWCamSetup

Asks nothing about the database or folders. After the install, open LWCam Admin and complete Station Setup.

## 7. First sign-in, users and projects

1. Open **LWCam Admin** on a PC that can reach the database. Only the SuperAdmin signs in. Ask the project lead for the factory SuperAdmin password.
2. Open **Station Setup**. Enter the database host, port, name, user and password. Set the image destination folder. Leave capture sync on. Press **Save**. Save tests the connection.
3. Open **User Management** and create the user accounts. Open **Projects** and create the projects.
4. The QC, LWIP and Upload consoles accept the Admin and SuperAdmin accounts from the database.
5. Do Station Setup on **every capture PC**. Install or upgrade `LWCamSetup.exe` first, then enter the login.

## 8. Trust the HTTPS consoles

Each server PC makes its own certificate when QC, LWIP or Upload is installed. The consoles use `https://`. Plain `http://` does not answer.

| Console | Address |
| --- | --- |
| QC | `https://<pc-name>:8080/` |
| LWIP | `https://<pc-name>:8090/` |
| Upload | `https://<pc-name>:8091/` |

Until you do the trust step, the browser shows a certificate warning. The page still works. To remove the warning, do this on each PC that opens a console, for each server PC:

1. Copy `Trust this LWCam server.cmd` and `LWCam server certificate.crt` from the server's install folder to that PC. Keep them together.
2. Double-click the `.cmd` file. No administrator rights are needed.
3. Close and reopen the browser.

Chrome and Edge use the Windows store that the `.cmd` file fills. Firefox has its own store: open Settings, Privacy and Security, Certificates, View Certificates, Authorities, Import. Choose `LWCam server certificate.crt` and tick "Trust this CA to identify websites".

## 9. Check that it works

1. Open the QC console, then **System status**. It lists QC, QC export, LWIP, Upload, backup and each capture PC.
   - Green: the part reported recently and has no problem.
   - Red: silent for more than 5 minutes (Upload: 15), or it has an error or a backlog.
   - Grey: a capture PC that is off. This is not a fault.
   - "Never reported": the part is not installed, not set up, or cannot reach the database.
2. Wait up to 5 minutes (Upload: 15). Fix every red row.
3. Run a test folder end to end:
   1. Capture a small folder with LWCAM.
   2. Wait for LWIP to process it. The LWIP console shows it.
   3. The folder appears in the QC queue. Review it and approve it.
   4. QC exports a package to the output folder.
   5. Upload sends the package to S3 and moves it to the Uploaded folder.
4. Optional: reject a page, recapture it, and approve the folder again. This tests the rework path.

If a part says "The database is older than this program", run `LWCamDatabaseSetup.exe` again (section 11).

## 10. Silent install

Every installer accepts Inno Setup's standard switches:

```
Setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\install-logs\x.log" /NAME=value ...
```

A missing or invalid value stops setup before any file is written (exit code 7). Parameter names are not case-sensitive. A page that the wizard would skip (an upgrade, or a fresh local database) is skipped too, and its parameters are ignored.

| Installer | Parameters (default) |
| --- | --- |
| `LWCamDatabaseSetup.exe` | PostgreSQL administrator: `DBHOST` (localhost), `DBUSER` (postgres), `DBPASSWORD` (empty). Shared login: `APPDB` (lwcam), `DBPORT` (5432), `APPUSER` (lwcam_user), `APPPASSWORD` (no default; 12 characters or more). Backups: `BACKUPDIR`, `BACKUPKEEP` (14; 1 to 365). Tasks: `/TASKS="openlan"` (default), `"remotedb"`, or `"openlan,remotedb"`. |
| `QCPlatformSetup.exe` | `DBHOST` (localhost), `DBPORT` (5432), `DBNAME` (lwcam), `DBUSER` (lwcam_user), `DBPASSWORD` (empty) |
| `LWIPSetup.exe` | `INPUTROOT`, `OUTPUTROOT` (both empty), `DBHOST` (empty), `DBPORT` (5432), `DBNAME` (lwcam), `DBUSER` (lwcam_user), `DBPASSWORD` (empty) |
| `LWCamUploadSetup.exe` | `WATCHROOT`, `DONEROOT`, `SUMMARYROOT` (all three required), `S3PATH`, `S3REGION`, `S3ACCESSKEY`, `S3SECRET` (empty), `DBHOST` (empty), `DBPORT` (5432), `DBNAME` (lwcam), `DBUSER` (lwcam_user), `DBPASSWORD` (empty) |
| `LWCamSetup.exe` | No product parameters. Standard switches, and `/DIR=` for another install folder. |

Examples:

```
LWCamDatabaseSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\install-logs\db.log" /TASKS="openlan" /APPUSER=lwcam_user /APPPASSWORD=<password>

QCPlatformSetup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\install-logs\qc.log" /DBHOST=<db-host> /DBPORT=5432 /DBNAME=lwcam /DBUSER=lwcam_user /DBPASSWORD=<password>
```

Warning: other processes on the PC can read a password on the command line, and Inno writes the whole command line into the `/LOG` file. Run silent installs from a script that only administrators can read. Delete or protect the log afterwards.

## 11. Upgrade

The database schema has a level: the highest number in the `schema_migrations` table. Every part refuses to work against an older schema. So the order matters.

1. **Back up.** On the database PC, run `BACKUP_DATABASE.bat` (or wait for the 02:00 task). Check that the newest `lwcam-*.dump` and `lwcam-globals-*.sql` are in the backup folder. Keep the old installers.
2. **Database PC:** run the new `LWCamDatabaseSetup.exe` with "Allow other PCs" ticked. Do this before you upgrade any other part. Run it again before any QC upgrade that adds a migration. The old `postgres` access rule stays while any part still uses it, so no part is cut off. The finish page then shows a `[NOTE]`.
3. Write down the login you typed on the "LWCam database login" page (or the values on the finish page). Pass it on only through a channel that administrators alone can read, not by e-mail or chat. Then run one backup, so the roles are also in a globals file.
4. **QC, LWIP and Upload PCs:** run each new installer over the old one. Enter the shared login (database, user, password) when asked. A part that still uses an older per-part login (`lwcam_qc`, `lwcam_lwip` or `lwcam_upload`) keeps working until you switch it to the shared login.
5. Open the QC System status page. QC, QC export, LWIP, Upload and backup must all be green. Allow five minutes (Upload: fifteen).
6. **Each capture PC, one at a time:** upgrade `LWCamSetup.exe` first. Then enter the shared login in LWCam Admin, Station Setup. Never enter the new login on a capture PC that still runs an old LWCAM. The old program does not know the new grants and fails.
7. Check that a new capture reaches the QC queue. Check that the capture PC shows on the status page with no "held" records.
8. When every part uses the shared login, run `LWCamDatabaseSetup.exe` once more. It removes the old open database rule. If a part still uses another login, setup keeps the rule and names the logins in a `[NOTE]`.
9. Do the HTTPS trust step (section 8) again on each PC that opens a console. Run `Trust this LWCam server.cmd` once for each server PC's certificate.
10. Keep the old installers and the pre-upgrade backup until one full working day has run without problems. That day must include a rework round trip (reject, recapture, approve) and one night's backup.

## 12. Uninstall

Use "Apps" in Windows Settings. Each installer stops its service first. PostgreSQL and its data are never removed.

These stay on purpose, so a reinstall does not lose work:

| Kept | Owner |
| --- | --- |
| `runtime\state.json` (the list of folders already processed) | LWIP |
| `runtime\uploads.json` (the list of packages already sent) | Upload |
| `config\database.txt` | Database installer |
| Exported delivery packages | QC |
| Backup files | Database installer |
| Network folder logins in `%ProgramData%\LWCAM\network-logins` | All services |

To start clean, delete the install folder by hand.

## 13. Backups and restore

The Database installer registers the task **LWCam Database Backup**. It runs every day at 02:00 as SYSTEM. It writes two files to the backup folder and deletes the oldest ones beyond the keep count:

- `lwcam-YYYYMMDD-HHMM.dump`: the database (PostgreSQL custom format)
- `lwcam-globals-YYYYMMDD-HHMM.sql`: the database roles, with their password hashes

The log is `logs\backup.log`. The settings are in `config\backup.txt`. Backups are not encrypted. Keep the folder private.

To restore on the same PC (a restore replaces the current database):

1. Stop the capture apps. Stop the QC, LWIP and Upload services that run on other PCs.
2. Open Command Prompt as administrator on the database PC.
3. Run `"C:\Program Files\LWCam Database\RESTORE_DATABASE.bat" "D:\LWCam Backups\lwcam-20260930-0200.dump"`. Use your install folder and file name.
4. Type `YES` when asked.
5. Start the services on the other PCs.

The script first saves a safety dump of the current database. It restores in one transaction. If the old PC is gone, see the next subsection.

### Rebuild the database PC on new hardware

Use this when the old database PC is gone.

Before the old PC fails, keep these items on another PC or drive:

- The backup folder: the newest `.dump` file and its `lwcam-globals-*.sql` file.
- The old PC's `config\database.txt`. It holds the LWCam login.

Then do these steps on the new PC:

1. Run `LWCamDatabaseSetup.exe` (with the PostgreSQL installer file beside it). Give the new PC the same name or address that the other PCs use. If you cannot, edit the database host in each part afterwards. Tick "Allow other PCs on this network (and Tailscale) to connect". On the "LWCam database login" page, type the same database name, port, user and password as before (they are in the old `database.txt`). Then no part needs a new setting. This run creates an empty schema.
2. If you do not have the old login, apply the globals file. It brings back the roles with their old password hashes. Open Command Prompt as administrator and run:

   ```
   "C:\Program Files\PostgreSQL\18\bin\psql.exe" -h localhost -U postgres -d postgres -f "D:\LWCam Backups\lwcam-globals-YYYYMMDD-HHMM.sql"
   ```

   Messages that a role "already exists" are harmless.
3. Restore the data. Run `RESTORE_DATABASE.bat` with the newest `.dump` file, as described above.
4. Run `LWCamDatabaseSetup.exe` again. It brings the schema and the grants to the current level. With "Allow other PCs" ticked, it also reopens the network access.
5. Open the QC console, System status. Every part turns green within a few minutes as it reconnects. If a part cannot sign in, the login was not restored. Enter the login from the old `database.txt` in that part.

## 14. Prove a site on separate PCs

One PC cannot prove these points. Tick them off on the real machines.

- [ ] **Saved network login for SYSTEM.** On each service PC, the saved network login works for the SYSTEM account. Test it with a scheduled task or with `psexec -s`. Error 1219 appears when QC, LWIP and Upload share one PC and reach the same peer with different accounts. Use one account per peer.
- [ ] **Peer reboot.** Restart the PC that holds a share. The service PC must reach the share again without anyone logging on. The status sentence about the unreachable folder must clear.
- [ ] **Capture at another site.** Send a real batch from a capture PC at another site to LWIP's input folder over Tailscale. Measure the copy speed. Run `cmdkey` for the Windows user who runs LWCAM on the capture PC. Check that the copy timeout is long enough for your link.
- [ ] **QC reads LWIP's output over a share.** Set `qcInputRoot` to LWIP's UNC share. Review and approve a normal folder. Review and approve a split folder (one batch that LWIP wrote in parts).
- [ ] **Database PC power cut.** Cut the power hard in the middle of a batch, an export and an upload. Every part must turn red and then recover alone. Nothing may be lost or duplicated.
- [ ] **QC PC power cut during an export.** The folder must be exportable again within about 2 to 3 minutes. The database drops the dead session and its lock after the TCP keepalive time. `LWCamDatabaseSetup.exe` sets it when you tick "Allow other PCs": 60 s idle, 10 s interval, 6 tries.
- [ ] **Console names.** Browsers reach every console by its MagicDNS name, even when Tailscale starts after the services. The certificate must still match the name.
- [ ] **Real S3 upload.** Upload to a real bucket. Include a client-rework re-upload of a package that was uploaded before.

Note: when Upload's `done_root` is on another volume than the export share, Upload copies a finished package and then deletes it over SMB. This is slower. The Upload login needs delete rights on the export share.
