LWIP Standalone Deskew/Crop Tool
================================

This backend-only utility watches an incoming root for folders of images. It
processes one folder at a time. Within that folder, a multiprocessing pool
decodes each image once, MEASURES its skew and crops it in memory, then writes
the staged output. It never rotates a pixel itself: a page tilted past
deskew_min_degrees gets its correction recorded as a small `qc_ops` op list in
the output manifest for the QC engine to replay (once, at preview and export
time) instead. The source folder is verified unchanged before the staged
output is published.

It does not use the FastAPI server, the LWIP task queue, orientation
prediction, separator detection, batching, or source cleanup.

It is a standalone Windows install (`{autopf}\LWCam LWIP`, installed by
LWIPSetup.exe), not something another app supervises. A scheduled task named
"LWCam LWIP" runs `START_LWIP.bat` as SYSTEM at boot (`/SC ONSTART`), which
starts the orchestrator against `config\deskew_crop_config.json` — the
installer writes this file once (input/output folders, and its own
`db_host`/`db_port`/`db_name`/`db_user`/`db_password`/`db_use_ssl`); it is not
overwritten on upgrade. Logs go to `logs\service.log`. A finished folder is
reported directly to PostgreSQL with those credentials (`cloud_report.py`) so
it reaches the QC queue with no other process needing to be running — see
"cloud_report" below. Stopping it gracefully (installer uninstall, or by hand)
means dropping `%ProgramData%\LWCAM\lwip.stop`; the running orchestrator exits
after finishing the folder it is publishing, within about 90 seconds.

For development or manual runs off the installed layout, `SETUP_DESKEW_CROP.bat`
then `START_DESKEW_CROP.bat` still work unchanged, reading the same
`config\deskew_crop_config.json`.


Configuration
-------------

Edit config\deskew_crop_config.json in this tool directory after setup.

input_root
    Each incoming job is a folder of images. With folder_depth=1 (default) that
    is each immediate child of input_root; with folder_depth=2 it is each
    grandchild (e.g. YYYYMMDD/<folder>) — see folder_depth below. Images below
    the job folder are included recursively when "recursive" is true.

output_root
    Completed images are written to a folder mirroring the job folder's position
    under input_root (so YYYYMMDD/<folder> at depth 2). Publication is staged on
    the output volume and the whole completed folder is switched into place,
    including when output_root is a NAS path. The input images are never modified
    or deleted. output_root must not be the same as, or inside, input_root.

folder_depth
    1 (default) = each child of input_root is a job — the original contract.
    2 = each grandchild is a job, for watching LWCAM's transfer layout
    (<destination>/YYYYMMDD/<folder>) directly; day-root siblings (CSV/log
    files, a logs\ folder) carry no marker and no images, so they are skipped.

thumbnail_width / thumbnail_quality / thumbnail_dirname
    thumbnail_width 0 (default) disables thumbnails. When > 0, after deskew/crop
    each processed image also gets a max-width JPEG thumbnail (aspect-preserving,
    only shrinks) written into <output folder>\<thumbnail_dirname> (default
    "thumbs"), named after the source image with a .jpg extension (page1.png ->
    thumbs\page1.jpg — not page1.png.jpg — to keep paths short), at
    thumbnail_quality (default 85). A thumbnail-stage failure does
    not fail the folder — the manifest's thumbnails.created flag records whether
    it succeeded. Thumbnails are part of the integrity manifest and audits.

jpeg_quality
    Quality of the written JPEG, default 100 with 4:4:4 chroma. Do not lower it
    for archival work. At 100 libjpeg emits quantization tables of all 1s, which
    is what a phone camera writes, so the processed page carries no more
    compression than the capture it came from; at the previous default of 90 the
    tables were four times coarser and the output was measurably a second
    compression generation. Files are roughly four times larger as a result.

deskew_min_degrees
    Skew below this is reported as 0.0 and no correction is recorded, default
    0.5. This tool never rotates a pixel itself — a page tilted past this
    threshold gets its measured angle turned into a `qc_ops` entry
    (`[{"op":"deskew","degrees":D},{"op":"crop","rect":[...]}]`) in the output
    manifest, which the QC engine replays with Pillow once, at preview and
    export time. A tilt nobody can see is not worth QC paying for that
    resample either, which is why the threshold exists at all.

mat_fill
    true (default) or false. A tilted page keeps its full `crop_padding` on
    every side except one the page itself runs off (its outline lies along the
    photo's edge for a quarter of the page or more); only that side is trimmed
    clear of the rotation corners. Whatever rotation void is left inside the
    crop is recorded as a trailing `{"op":"matfill"}` op, which QC paints with
    the surrounding background at preview and export time. false trims every
    side clear of the void, shortening the padding instead.
    Upgrade the QC server BEFORE turning this on at a site: an older QC
    ignores the matfill op and shows the void as black corners.
    The manifest's files[] entries also carry angle_source ("sides",
    "min_area_rect" or "none"), page_found, off_frame (side names) and
    mat_fill (a matfill op was recorded).

Encode once: only a JPEG with a page found is re-written (a lossless jpegtran
trim). Every other file - PNG, TIFF, BMP, JPEG XL, and a JPEG in which no page
was found - is delivered as the source's own bytes; its crop (and deskew,
matfill) is recorded in `qc_ops` against the full, deskew-expanded source frame
instead. A file whose EXIF orientation is not 1 is still decoded and re-encoded.
.jxl needs the optional pillow-jxl-plugin package; without it that file fails
with a message saying so.

Page detection thresholds with OpenCV's TRIANGLE method (since 2026-10-06; it
was Otsu). Otsu files a bound volume's dark cover board with the backdrop,
which cost margin and skew accuracy; on the 99 Control pages the residual tilt
after replay fell from p90 1.0 to 0.6 degrees (22 to 14 pages above 0.5).

For a tilted page, `crop_padding` is measured around the page after it has
been straightened, at the final QC crop. LWIP maps that padded rectangle back
into the camera frame before making its lossless JPEG crop, so rotation does
not consume the background margin as empty corner wedges. If the camera frame
ends before a full margin is available, only the affected side is shortened.

workers
    Number of image worker processes. The default, zero, selects logical CPU
    count minus one (up to the Windows limit of 61); on a 12-thread PC that was
    3.5 images/s at 11 workers against 2.4 at four. Each worker decodes a whole
    scan: measured peak is about 410 MB per worker for a 6144x8192 JPEG (plan
    for 0.5 GB). On a PC with little RAM set a smaller number: roughly
    (RAM in GB - 4) x 2.

stable_seconds / minimum_file_age_seconds
    Without a completion marker, the full list of image paths, sizes, and
    modified times must remain unchanged for stable_seconds, every image must be
    readable, and the newest image must be at least minimum_file_age_seconds old.
    Any change during processing discards staged work and returns the folder to
    the stability wait.

completion_marker
    For deterministic transfer completion, configure a file name such as
    "TRANSFER.COMPLETE" and have the sender create that file only after all
    images have been closed. When configured, a folder is eligible only when the
    marker exists; image readability and unchanged-snapshot checks still apply.
    A producer-written marker is the only way to distinguish a finished transfer
    from a long pause between files with certainty. LWCAM's marker also carries
    "image_count", the number of images it copied into the folder: a folder
    holding fewer image files than that is treated as still arriving (logged
    once) and is not processed. A marker without the field behaves as before. The installed config sets
    the marker to "lwcam_capture_marker.json", matching what LWCAM's own
    `processing_marker_service.dart` still writes (carrying the folder's DB
    identity) into each folder once a box's transfer fully verifies; that
    identity is copied into the output manifest's "source_identity", which is
    what lets this tool resolve and report the folder itself (see
    cloud_report below). A folder still awaiting its marker never blocks the
    idle integrity audits.

state_file
    Persistent journal of completed folder fingerprints. Unchanged folders are
    not processed again after restart. Changing, adding, or removing an image
    changes the fingerprint and makes the folder eligible again.

presence_check_interval_seconds
    While no input folder is waiting or processing, the watcher checks one
    completed output folder at a time for missing, extra, or incorrectly sized
    images. The default is every 300 seconds per folder.

checksum_check_interval_seconds
    While idle, the watcher periodically reads completed output images and
    compares their SHA-256 checksums with the durable publication manifest. The
    default is once every 86400 seconds (daily) per folder. A missing or corrupt
    image schedules immediate full-folder reprocessing from the preserved source.

cloud_report / db_host / db_port / db_name / db_user / db_password / db_use_ssl
    When cloud_report is true (the installed default), a finished folder with a
    completion marker identity is reported straight to PostgreSQL
    (`deskew_crop_tool/cloud_report.py`) using this station's own db_* settings
    — LWIP keeps no other copy of a database login. db_port defaults to 5432,
    db_name to "lwcam", db_use_ssl to false (sslmode "prefer"; true means
    "require"). Loading a config with cloud_report true and db_host, db_user or
    db_password missing or blank fails immediately, naming which key is
    missing, rather than starting a watcher that can never reach QC.


Crash And Corruption Recovery
-----------------------------

Every output file is written to a temporary file, flushed to stable storage,
and atomically renamed. During the required publication copy, the tool records
each output path, exact size, and SHA-256 checksum without adding another read
pass. The manifest itself is checksummed in the atomic state journal.

Completed folders are switched into place only after every staged file and the
manifest pass a presence/size verification. Scheduled integrity audits run only
when there is no incoming work, so they do not reduce processing throughput.
Any missing, extra, truncated, or checksum-mismatched output triggers automatic
reprocessing. The input images remain read-only throughout recovery.


Running
-------

Installed (the normal case): the scheduled task "LWCam LWIP" runs
START_LWIP.bat as SYSTEM at boot; there is nothing to start by hand. Logs go
to logs\service.log. To stop it gracefully, drop %ProgramData%\LWCAM\lwip.stop
and wait about 90 seconds.

First-time setup for a source checkout or a manual run (installs the bundled
Python and offline dependencies locally):

    SETUP_DESKEW_CROP.bat

Then run:

    START_DESKEW_CROP.bat

The watcher runs until Ctrl+C. Logs are written to the configured log_file.

To process currently ready folders and exit:

    START_DESKEW_CROP.bat --once

To wait for all folders currently present to become stable, process them, and
then exit:

    START_DESKEW_CROP.bat --once --wait

Only one orchestrator can use a work_root at a time. Folder ordering is oldest
modified folder first; a later folder cannot run concurrently with it.


Console
-------

START_LWIP.bat now runs deskew_crop_tool.service, a supervisor that starts
the watcher above as a child process and also serves a small web console
beside it - by default at https://<this PC's name>:8090/ (ui_port / ui_bind in the
config). It stays reachable even if the watcher's config is bad enough that
the watcher itself cannot start, so that is something an operator can see and
fix from a browser instead of only from logs\service.log.

Sign in with an Admin or SuperAdmin account from the shared PostgreSQL users
table (the same one LWCAM/LWCam Admin/QC use) - a plain qc-only account has
no console access. If the database cannot be reached the console is
read-only: a browser open on THIS machine sees status and the log without
signing in, and an admin who has signed in before can sign in from the saved
admin list (admin_cache.json beside the config, refreshed every ten minutes
while the database answers). Nobody changes settings from a remote browser
until the database comes back. Saving Settings restarts the watcher with the
new values.

"Network folder logins" saves the account this PC signs in with to reach a
folder on another PC - needed outside a domain, where the other PC refuses
this PC's own SYSTEM account. The list is shared by every LWCam service on
this PC; installer\README.txt ("SYSTEM account and UNC shares") has the rest.

Passwords at rest
-----------------
db_password is stored encrypted ("dpapi:...") in config\deskew_crop_config.json: Windows DPAPI
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
reached the database). While the database or the QC PC is off, LWIP keeps working from its
input folder and reports finished folders when the database returns; a finished folder
waits for QC in the database queue. The status page shows folders waiting or failed.

Schema gate: if the database is older than this program, the service says so
("The database is older than this program (needs level N, has M). Run
LWCamDatabaseSetup on the database PC.") and does no database work until the
database PC has been upgraded - upgrade the database PC first. The whole-site
upgrade order, backups, restore and rebuild-on-new-hardware recipes are in
installer\README.txt ("Upgrading a multi-PC site").


Package Contents
----------------

backend\                 standalone Python source (no tests in the installed copy)
config\                  tool configuration; deskew_crop_config.json is written
                         by the installer on a fresh install and left alone on
                         an upgrade
requirements.txt         pinned dependency versions
SETUP_DESKEW_CROP.bat    one-time offline setup
START_LWIP.bat           the scheduled task's target; logs to logs\service.log
START_DESKEW_CROP.bat    manual/dev watcher launcher (source checkouts)
RUN_TESTS.bat            end-to-end verification (source checkouts)

Created by setup or at run time, not present in a source checkout:

tools\                   jpegtran.exe + jpeg8.dll (libjpeg-turbo): lossless crop,
                         used for every eligible page regardless of measured
                         skew (this tool never rotates, so a tilted page's
                         pixels are as croppable as a straight one). Missing =
                         pages are re-encoded instead.
runtime\                 the private Python runtime, plus local state and
                         work data
logs\                    service.log (START_LWIP.bat) and whatever log_file
                         in the config points at

Present only in the deployed package, not in a source checkout:

wheels\                  offline NumPy, OpenCV, Pillow and pip packages

SETUP_DESKEW_CROP.bat needs runtime\ and wheels\. From a source checkout, create the
virtual environment yourself instead; the .bat files then work unchanged,
because they invoke runtime\python\python.exe:

    python -m venv venv
    runtime\python\python.exe -m pip install -r requirements.txt
    runtime\python\python.exe -m unittest discover -s backend/tests -v
