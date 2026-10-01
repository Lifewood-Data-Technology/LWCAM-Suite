LWCam Upload
============

Sweeps QC's published export packages (a folder or a ZIP per Group ID) out of
watch_root and into an S3 bucket, size-verified PUT by PUT. An uploaded
package gets a row in Upload_Summary.db3 (if summary_root is set) and is then
moved into done_root, so watch_root only ever holds what has not reached the
bucket yet. A client rework republished under the same Group ID is detected
by content fingerprint and uploaded again, replacing the earlier copy in both
the bucket and done_root.

Split out of the QC server so upload can run on its own PC, on its own
schedule, whether or not QC or LWIP are even installed there.


Configuration
-------------

Edit config\upload_config.json (JSON; see backend\lwcam_upload\config.py for
every key, default and validation rule). The essentials:

watch_root       required - the folder QC publishes packages into.
done_root        "" (default) leaves uploaded packages where they are.
summary_root     "" (default) skips the Upload_Summary.db3 row.
enabled          true (default) - false pauses uploading; the console stays up.
s3_path          s3://bucket/optional/prefix - required while enabled.
s3_region, s3_access_key, s3_secret_key - required while enabled.
interval_seconds how often to scan watch_root, minimum 5, default 60.
db_host/db_port/db_name/db_user/db_password/db_use_ssl - console sign-in only.
ui_port          8091 by default; ui_bind 0.0.0.0 (LAN) by default.

Settings are re-read at the start of every scan, so a console save applies on
the next scan - no restart. An invalid config logs a [CONFIG] line once (not
every scan) and does nothing until it is fixed.


Console
-------

By default at https://<this PC's name>:8091/. Sign in with an Admin or SuperAdmin
account from the shared PostgreSQL users table (the same one LWCAM/LWCam
Admin/QC/LWIP use). If the database cannot be reached the console is
read-only: a browser open on THIS machine sees status and the log without
signing in, and an admin who has signed in before can sign in from the saved
admin list (admin_cache.json beside the config, refreshed every ten minutes
while the database answers). Nobody changes settings from a remote browser
until the database comes back.

"Network folder logins" saves the account this PC signs in with to reach a
folder on another PC - needed outside a domain, where the other PC refuses
this PC's own SYSTEM account. The list is shared by every LWCam service on
this PC; installer\README.txt ("SYSTEM account and UNC shares") has the rest.

Passwords at rest
-----------------
db_password and s3_secret_key are stored encrypted ("dpapi:...") in config\upload_config.json: Windows DPAPI
tied to this PC, written by the installer and by the console, and encrypted at
start-up if an older install left it plain. A copy of the file on another PC
cannot be decrypted (enter the password again in the console). It does not
protect against an administrator on this PC. See installer\README.txt.

HTTPS and other PCs
-------------------

The console is https:// only: plain http on the same port no longer answers.
The certificate is made by the installer (C:\ProgramData\LWCAM\tls, shared by
the QC, LWIP and Upload services on one PC, renewed by the service on every
start). On every PC whose browser opens the page, copy "Trust this LWCam
server.cmd" and "LWCam server certificate.crt" from the install folder, keep
them together and double-click the .cmd once, then reopen the browser. Firefox
has its own certificate store: Settings > Privacy & Security > Certificates >
View Certificates > Authorities > Import the .crt and tick "Trust this CA to
identify websites". Details: installer\README.txt ("HTTPS").

The database may be on another PC or another site (LAN or Tailscale). This
service uses the one shared LWCam database login (the one LWCamDatabaseSetup shows) and reports to the QC console's
System status page (green / red / grey; "never reported" when it has not yet
reached the database). While the database or the QC PC is off, Upload keeps scanning QC's output folder and
sends packages to S3 (nothing here needs the database except the console sign-in
and the status report, which are retried). A package that fails stays where it is,
is retried with back-off, and shows on the status page as failed (red) until it goes
through. If the QC PC's share is off, the folder is retried every two minutes.

Schema gate: if the database is older than this program, the service says so
("The database is older than this program (needs level N, has M). Run
LWCamDatabaseSetup on the database PC.") and does no database work until the
database PC has been upgraded - upgrade the database PC first. The whole-site
upgrade order, backups, restore and rebuild-on-new-hardware recipes are in
installer\README.txt ("Upgrading a multi-PC site").


Logs
----

logs\service.log is what START_UPLOAD.bat redirects this process's own
stdout/stderr into (its own pre-checks, and anything printed before the
config's own log_file is known). Once running, every console log line -
scans, uploads, retries, errors - also goes to log_file (default
logs\upload.log), rotated at 10 MB x 5, and is visible live from the console.


Package Contents
-----------------

backend\                 lwcam_upload source (no tests in the installed copy)
config\                  upload_config.json; written by the installer on a
                          fresh install and left alone on an upgrade
requirements.txt         pinned dependency versions
SETUP_UPLOAD.bat         one-time offline setup
START_UPLOAD.bat         the scheduled task's target; logs to logs\service.log

Created by setup or at run time, not present in a source checkout:

runtime\                 the private Python runtime, plus uploads.json and
                          any stop.request
logs\                    service.log and upload.log

Present only in the deployed package, not in a source checkout:

wheels\                  offline boto3, psycopg, bcrypt and pip packages
