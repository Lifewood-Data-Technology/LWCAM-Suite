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

It does not use the FastAPI server, PostgreSQL, the LWIP task queue, orientation
prediction, separator detection, batching, or source cleanup.

It runs in two ways: standalone (START_DESKEW_CROP.bat, edit the config by hand)
or SUPERVISED BY LWCAM as the pipeline's image-processing phase. In supervised
mode LWCAM generates the config (folder_depth 2, the capture marker as the
completion gate, 512px thumbnails), starts/restarts this tool, and reads the
output manifests + state.json to update the database — this tool itself still
touches no database. See LWCAM's AGENTS.md ("Image-processing phase").


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

For a tilted page, `crop_padding` is measured around the page after it has
been straightened, at the final QC crop. LWIP maps that padded rectangle back
into the camera frame before making its lossless JPEG crop, so rotation does
not consume the background margin as empty corner wedges. If the camera frame
ends before a full margin is available, only the affected side is shortened.

workers
    Number of image worker processes. The conservative default is four because
    high-resolution scans consume substantial memory. Zero selects logical CPU
    count minus one (up to the Windows limit of 61).

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
    from a long pause between files with certainty. When LWCAM supervises this
    tool it configures the marker as "lwcam_capture_marker.json" and writes one
    (carrying the folder's DB identity) into each folder after a box's transfer
    fully verifies; that identity is copied into the output manifest's
    "source_identity" so LWCAM can report results to the database. A folder
    still awaiting its marker never blocks the idle integrity audits.

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

First-time setup (installs the bundled Python and offline dependencies locally):

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


Package Contents
----------------

backend\                 standalone Python source and tests
config\                  tool configuration
requirements.txt         pinned dependency versions
SETUP_DESKEW_CROP.bat    one-time offline setup
START_DESKEW_CROP.bat    continuous watcher launcher
RUN_TESTS.bat            end-to-end verification

Created by setup or at run time, not present in a source checkout:

tools\                   jpegtran.exe + jpeg8.dll (libjpeg-turbo): lossless crop,
                         used for every eligible page regardless of measured
                         skew (this tool never rotates, so a tilted page's
                         pixels are as croppable as a straight one). Missing =
                         pages are re-encoded instead.
runtime\                 the private Python runtime, plus local state,
                         work data, output and logs

Present only in the deployed package, not in a source checkout:

wheels\                  offline NumPy, OpenCV, Pillow and pip packages

SETUP_DESKEW_CROP.bat needs those last two. From a source checkout, create the
virtual environment yourself instead; the .bat files then work unchanged,
because they invoke runtime\python\python.exe:

    python -m venv venv
    runtime\python\python.exe -m pip install -r requirements.txt
    runtime\python\python.exe -m unittest discover -s backend/tests -v
