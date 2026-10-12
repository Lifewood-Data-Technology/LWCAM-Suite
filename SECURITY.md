# Security

English | [简体中文](SECURITY.zh-CN.md)

## Reporting a vulnerability

Do **not** open a public issue for a security problem. Send a private message
to the project lead, Jackson Choy (jackson.choy@lifewood.com). Include what you
found, the module and version, and the steps to reproduce it. Do not put real
passwords, keys or customer data in the message.

## How secrets are stored

| Secret | Where | How it is protected |
| --- | --- | --- |
| Database login (shared) | QC `config\config.txt`, LWIP `config\deskew_crop_config.json`, Upload `config\upload_config.json`, LWCAM/LWCam Admin `lwcam_node_config.json` | Encrypted with Windows DPAPI (see below) |
| QC login-token secret (`jwtSecret`) | QC `config\config.txt` | DPAPI |
| OpenRouter API key | QC `config\config.txt` | DPAPI |
| S3 secret key | Upload `config\upload_config.json` (`s3_secret_key`) | DPAPI |
| PostgreSQL administrator and app login | Database `config\database.txt` | DPAPI |
| Capture PC database password | `lwcam_node_config.json` (`pgPasswordProtected`) | DPAPI, current-user scope |
| Per-PC certificate authority and keys | `%ProgramData%\LWCAM\tls` | Folder for SYSTEM and Administrators only |
| Saved network-share logins | `%ProgramData%\LWCAM\network-logins\` | Folder for SYSTEM and Administrators only |

**DPAPI values.** A protected value is written as `dpapi:<base64>`. The code is
`lwcam_secrets.py`, one file copied byte-for-byte into each module. It uses
Windows DPAPI in the **LOCAL_MACHINE** scope with a fixed entropy string. So the
installers (run by an administrator) and the services (run as SYSTEM) can both
read what the other wrote, and a config file copied to another PC cannot be
decrypted there. What it does **not** do: it does not stop an administrator, or a
process running as SYSTEM, on the same PC; they can decrypt it as the services
do. It keeps secrets out of backups, screenshots, support e-mails and casual
reads. A plain value without the prefix is still accepted (older files, hand
edits); the service rewrites the file protected when it starts. The code has no
command to decrypt on purpose.

(LWCAM and LWCam Admin use a separate DPAPI helper, `lib/services/dpapi.dart`, in
the current-user scope with the entropy `LWCam`, for the capture PC's password.)

**Locked folders.** Each installer writes its `config\` folder so that only SYSTEM
and Administrators can read it (`RestrictToAdmins` in `installer/common.iss`).
The program folder `{app}` and `%ProgramData%\LWCAM` are writable by
administrators only, because SYSTEM tasks run code from them.

**One shared database login.** Every part connects with one login, chosen when
you run `LWCamDatabaseSetup`. It is a member of the group role `lwcam_app`, which
holds exactly the grants the parts need. It has no CREATE, no superuser, no
createdb, no createrole. Trade-off: one leaked password can read and edit the
LWCam tables from anywhere the network admits it. It cannot run programs on the
database PC, create tables or drop the database.

**TLS.** The database connection uses TLS (`hostssl` rules in `pg_hba.conf`).
The QC, LWIP and Upload consoles serve https only. Each server PC makes its own
certificate authority (`tls.py`), limited by NameConstraints to that PC's own
names and addresses. Each console renews its certificate itself, and the CA is
never replaced silently. A browser must trust the CA once (see
`installer/README.md`, HTTPS section).

**Console sign-in.** QC, LWIP and Upload consoles use accounts from the database
(bcrypt hashes), with rate limiting. One live sign-in per account.

**The SuperAdmin recovery account.** LWCam Admin has a built-in SuperAdmin whose
factory password hash is compiled into every build. The same factory password
works on every install until you set your own in LWCam Admin, App Settings →
SuperAdmin password (stored as an override in the database). Change it at every
site.

**Backups are not encrypted.** The dumps and globals files from the nightly backup
hold every login hash. Keep the backup folder private.

## What never goes into git

Real `config.txt`, `upload_config.json`, `deskew_crop_config.json` with a login,
`lwcam_node_config.json`, `database.txt`, certificates and private keys,
PostgreSQL dumps, build outputs, installers (`*.exe`), and customer images.
Commit only the `*.example` files. See `CONTRIBUTING.md`.

## Rotating secrets

After any rotation, check the QC **System status** page: every part must turn
green again.

| Secret | How to change it |
| --- | --- |
| **Database password** | Run `LWCamDatabaseSetup` again on the database PC with the new password (the same user, name and port). Then enter the new password in every part: re-run `QCPlatformSetup`, `LWIPSetup` and `LWCamUploadSetup` (or change it in the LWIP and Upload consoles), and in LWCam Admin → Station Setup on every capture PC. |
| **`jwtSecret` (QC)** | Edit `jwtSecret` in QC `config\config.txt` (at least 32 random characters; the installer generated the first one). Restart the "LWCam QC Server" scheduled task. Everyone is signed out. |
| **S3 keys** | Change them in the Upload console (port 8091), Settings. The service applies the save without a reinstall. Revoke the old key in AWS. |
| **OpenRouter key** | Change it in the QC console, Admin → Settings. The value is write-only there. |
| **SuperAdmin password** | LWCam Admin → App Settings → SuperAdmin password. |
| **User passwords** | LWCam Admin → User Management (reset to the shared temp password; the user must change it at the next login). |
| **Certificates** | Automatic. A changed IP address needs a restart of that service, not a new installation. |

If a secret leaked, rotate it first and tell the project lead second.
