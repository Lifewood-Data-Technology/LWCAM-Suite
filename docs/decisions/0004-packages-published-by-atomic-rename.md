# 0004. Delivery packages are published by atomic rename

- **Status:** Accepted

## Context

Upload and the client's ingest team watch the QC output folder. They must never see a half-written package. A client rework also replaces a package that already exists there under the same name.

## Decision

- QC builds the package in a staging folder, verifies it, and then moves it into place with one `os.replace` (`publish_folder` and `publish_zip` in `services/export.py`).
- Staging lives inside the output folder, because `os.replace` is atomic only within one volume. The long copy from the work folder can cross volumes. The final rename never does.
- When a package already exists (client rework), QC renames it aside into staging first, and then moves the new one in. If that fails, it renames the old one back. It never deletes first.
- Upload waits until a package is unchanged for 10 seconds before it sends it.

## Consequences

- Input, work and output folders can be on different drives.
- Do not move staging under the work root. That makes "same drive" a hard rule.
- A package in the output folder is always complete.

## Don't change this unless

You have a replacement that is also atomic for the reader and keeps the old package deliverable until the new one is in place.
