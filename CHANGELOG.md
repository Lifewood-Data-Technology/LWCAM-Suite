# Changelog

All notable changes to the LWCam **Module edition** (branch `lwcam-module`).
Newest first. The All-In-One edition keeps its own changelog on branch
`lwcam-all-in-one`. Older, file-level history of the two Flutter apps is in
`LWCAM/CHANGELOG.txt` and `LWCamAdmin/CHANGELOG.txt`.

## [Unreleased]

## [1.1.0] - 2026-10-12

First release on GitHub. Five installers: `LWCamDatabaseSetup.exe`,
`LWCamSetup.exe` (LWCAM + LWCam Admin), `LWIPSetup.exe`,
`QCPlatformSetup.exe` and `LWCamUploadSetup.exe`.

### Handover

- Documentation for a new team, in English and Simplified Chinese: front page,
  architecture, glossary, install, development setup, testing, releasing,
  handover status, contributing, security, and decision records.
- Every source file has a header that says what it does; the largest files
  have section labels.
- Example configuration files for every part (`*.example.*`). Real
  configuration is never committed.
- `upload_contoller.dart` renamed to `upload_controller.dart`.

### Added

- **Five modules, five installers.** The database, LWIP, the QC Platform and
  LWCam Upload each install on their own PC; the capture PCs get LWCAM and
  LWCam Admin.
- **QC Platform as a server.** Review, approval, rejection, separation, client
  rework and export run in a web console (Vue) served by the QC server, which
  owns its settings in `config.txt`. The QC screens left the capture app.
- **LWCam Upload**, a standalone S3 uploader with its own console, ledger and
  retry with back-off. Results are written back to the database.
- **LWIP as a service**, with its own settings, database login and web console.
- **System status page** in the QC console: every part reports a heartbeat;
  stalls (unreachable shares, waiting folders, failed uploads) show in plain
  words.
- **Security:** one shared database login chosen at install, TLS for the
  database and the consoles (per-PC certificate authority), passwords and keys
  encrypted at rest with DPAPI, admin-only program and config folders, one live
  sign-in per account, sign-in guess limits.
- **Operations:** nightly database backup and a restore script, network folder
  logins for SYSTEM services, unattended (silent) installs, one suite version
  stamped into every install, checksums for every bundled third-party file.
- **QC:** pages added or edited in QC survive a capture rework; separation has
  an explicit Apply/Cancel step; split folders keep LWIP's deskew and crop.
- **LWIP:** v2 deskew features with a shared geometry replay (mat fill); worker
  count set automatically.

### Changed

- Bundled Python is 3.14.8 in every installer.
- Export zips store images uncompressed (faster; images are already
  compressed).
- LWCam Upload sends a package only after it has been unchanged for 10 seconds.
- Capture sync is on by default; captures made while it was off are sent once.

### Fixed

- LWIP never prunes its journal while the input folder is unreachable.
- A rework package is swapped in, not deleted first.
- The export and upload sweeps read their on/off switch on every run, not only
  at start.
- Many multi-PC stalls: no capture UI freeze on a dead share, dead database
  sessions dropped in about two minutes, flaky links do not hold records.
- Three gallery labels in LWCAM showed a mis-encoded character instead of `·`.

## [1.0] - 2026-09-24

The All-In-One baseline shared with the All-In-One edition: one installer,
QC review inside LWCAM, and the image-fidelity fix for delivery packages
(geometry kept as data until export, lossless LWIP crop, luminance correction
off by default, TIFF predictor 2). See `docs/FAMILYSEARCH-FIX.md`.

[Unreleased]: https://github.com/djchoy-LW/LWCAM-Suite/compare/v1.1.0...lwcam-module
[1.1.0]: https://github.com/djchoy-LW/LWCAM-Suite/releases/tag/v1.1.0
