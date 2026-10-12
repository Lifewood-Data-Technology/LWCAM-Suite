# Handover

English | [简体中文](HANDOVER.zh-CN.md)

For the team lead who receives LWCam. It says what you get, what is proven,
what is not, and what to do in the first week. Terms are in `GLOSSARY.md`.

## What is handed over

| Item | Where |
| --- | --- |
| Source code, both editions | Private GitHub repository `djchoy-LW/LWCAM-Suite` |
| Module edition (new work goes here) | Branch `lwcam-module` (default) |
| All-In-One edition (older, for existing sites) | Branch `lwcam-all-in-one` |
| Read-only history | Branches `archive/github-main`, `archive/fsi-demo` |
| Installers | GitHub Releases: tag `v1.1.0` (five module installers) and `v1.1.0-all-in-one`, with SHA256 checksums. Installers are not in git. |
| Build inputs too large for git (Python embeddable zip, VC runtime, adb, PostgreSQL installer, wheels, scrcpy, LWIP tools) | Private GitHub Release named `build-inputs`, with an unpack script. See `RELEASING.md`. |
| Sample test images | Not in the repository. Ask the project lead. |
| Documentation | `README.md`, `docs/`, one `AGENTS.md` per module, `docs/decisions/` |

## Status of each module

"Tested" means the automated test suites (`TESTING.md`). Installed-on-a-PC
checks were done by the original developer on a small test setup. Only
statements the repository documents are listed here.

| Module | Works | How it was tested | Not yet proven |
| --- | --- | --- | --- |
| LWCAM (capture) | Capture over adb, Box Mode and Normal Mode, transfer with retry, offline queue with sync, rework recapture list | Unit tests; used end to end with the other parts on one PC | Many capture PCs at a real site; a flaky long-distance link |
| LWCam Admin | Users, projects, devices, settings, Station Setup | Unit tests; used end to end | A real multi-site setup |
| LWIP | Deskew, lossless crop, thumbnails, manifest, report to the database, https console | Unit tests; run on a test PC with real photos | A database or share on another PC at a real site (the SMB machine account and login, latency, clock differences) |
| QC Platform | Review, approve, reject, separation, client rework, export, status page | Unit tests; used end to end through the console | The Revert and Approve buttons of client rework were exercised through the API only |
| Upload | Verified upload with ledger, retry, back-off, write-back of the result | Unit tests; run against a fake S3 bucket | **A real S3 bucket**, including the upload of a client-rework republish |
| Database setup | PostgreSQL install or reuse, schema, shared login, LAN access, TLS, nightly backup, restore script | Install-tested on one PC | **A reboot of the database PC**; restore on new hardware at a site |
| Installers | All five build; install and uninstall were tested on one PC | Build script with checksum check | **An upgrade from an All-In-One station**; whether the Python 3.14 builds upgrade over an older Python 3.13 runtime on a real PC (it was proven only by running the builders on a copy of a 3.13 runtime) |

Whole-pipeline rule (the core objective): capture, LWIP, QC, export and upload,
including rework, must work with every part on its own PC. The design follows
it (everything queues and retries, nothing waits on a remote host without a
timeout, and the QC status page shows each stall). It is proven on one PC with
role logins over the network, not on separate machines. The checklist for
proving a site on real separate PCs is in [INSTALL.md](INSTALL.md#14-prove-a-site-on-separate-pcs).

## Known issues and open work

Create these as GitHub Issues (labels in `CONTRIBUTING.md`).

### Feature

- **Color Calibration integration into the Module edition** (`enhancement`).
  Daily colour calibration, AI-review reliability work and volume carry-over
  pre-fill exist only in the All-In-One edition (`lwcam-all-in-one`). Decide
  what to port, and where it belongs in the five-module layout.

### Refactors (`refactor`, one issue per item)

The files below are the largest and highest-risk. Split them only with tests
that prove the behaviour does not change.

| File | Note |
| --- | --- |
| `LWCAM/lib/pages/gallery_page.dart` (~6300 lines) | ADB/transfer half is the riskiest part; do not touch it without need |
| `LWCam_QC_Platform/frontend/src/views/qc/QcIndexView.vue` | Review desk |
| `LWCam_QC_Platform/backend/app/routers/qc.py` (~3400 lines) | |
| `LWCAM/lib/db/upload_stats_db.dart` (~3200 lines) | |
| `LWCam_QC_Platform/backend/app/services/ai_review.py` (~2600 lines) | |
| `LWCam_QC_Platform/backend/app/services/export.py` (~2200 lines) | |
| `LWIP/backend/deskew_crop_tool/orchestrator.py` (~1900 lines) | |
| `LWCAM/lib/controllers/transfer_controller.dart` (~1900 lines) | |
| `build_handler` in `LWIP/backend/deskew_crop_tool/service.py` | One very long function |
| `build_handler` in `LWCam_Upload/backend/lwcam_upload/console.py` | One very long function |
| `load_config` in `LWIP/backend/deskew_crop_tool/config.py` | |
| `_scan` in `LWCam_Upload/backend/lwcam_upload/engine.py` | |

### Known test baseline

Two LWIP tests (`test_long_paths.py`) fail on a PC where Windows long paths are
enabled. They are negative controls. See `TESTING.md`.

## Suggested first week

1. Read `README.md`, then `ARCHITECTURE.md`, then `GLOSSARY.md`.
2. Read the root `AGENTS.md`: the traps and the design decisions. Skim
   `docs/decisions/`.
3. Set up the dev environment (`DEV-SETUP.md`): Flutter, Python 3.14, Node.
4. Run every test suite (`TESTING.md`). Write down your counts. They are your
   baseline.
5. Install all five parts on one PC (`INSTALL.md`). Use the build inputs.
6. Push a test folder through the whole pipeline: capture (or a hand-made folder
   with the marker file), LWIP, QC review and approve, export, upload to a test
   bucket. `LWCam_QC_Platform/scripts/reset_test_folder.py` helps when you have no
   camera.
7. Pick a starter issue (label `good first issue` on GitHub) and open your first
   pull request (`CONTRIBUTING.md`).

## Contacts

Project lead: Jackson Choy, jackson.choy@lifewood.com. Ask the project lead
for sample images, the `build-inputs` release access, and answers about the pipeline's
history. Report security problems privately (see `SECURITY.md`).
