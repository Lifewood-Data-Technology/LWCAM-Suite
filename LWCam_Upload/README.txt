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

By default at http://localhost:8091/. Sign in with an Admin or SuperAdmin
account from the shared PostgreSQL users table (the same one LWCAM/LWCam
Admin/QC/LWIP use). If the database cannot be reached at all, a browser open
on THIS machine still gets full access so the settings can be fixed from
there; a browser anywhere else gets read-only status and log viewing until
the database comes back.


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
