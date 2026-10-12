# 0007. Parts share only the database and folders

- **Status:** Accepted (2026-09-23 for QC; 2026-09-25 for LWIP and Upload)

## Context

LWCam must work when every part is on a separate PC or at a separate site. The first versions had QC read the capture app's config file, and LWCAM supervised LWIP. Both assumed one PC.

## Decision

- QC owns its settings in its own `config.txt`. It reads nothing from LWCam Admin or from `lwcam_node_config.json`.
- LWIP is its own service. It reports each finished folder to the database itself (`cloud_report.py`). LWCAM does not start, stop or read LWIP.
- Upload is its own service. QC does not upload. It only exports.
- Only `LWCamDatabaseSetup.exe` creates or upgrades the schema. A part never provisions the database.
- Every part writes a heartbeat. The QC System status page shows them.
- Each part reads the schema level and refuses to work against an older database.

## Consequences

- A QC release that adds a migration needs a new `LWCamDatabaseSetup` run on the database PC first, not a QC reinstall.
- Any part can be off. The others queue and retry.
- Do not add a shortcut such as a shared config file or a direct call between parts. It breaks the split-site case.

## Don't change this unless

You are deliberately building a single-PC product. Then say so in the docs.
