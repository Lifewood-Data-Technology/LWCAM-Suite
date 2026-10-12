# 0010. A separated child folder cannot be rejected for recapture

- **Status:** Accepted (2026-09-21)

## Context

Separation splits one capture folder into several children. Capture rework resolves paths back through the original capture folder. A child never existed there.

## Decision

`reject_task` refuses a child (`separated_from_folder_id`, migration `005`). A richer fix would resolve the rework through that column back to the parent. It was offered and declined, because a path-rewriting rework is neither cheap nor easy to understand.

Related rules:

- Separation page 1 is an implicit start. `PUT .../separation-markers` takes only the extra start ids, and the split needs at least one.
- Each child gets its own `qc_ops.json` and a copy of LWIP's manifest narrowed to its pages. Without the manifest, children lose deskew and crop in preview and export.
- Pages that QC added or replaced cannot be rejected for recapture either (HTTP 400). Replace the page again.

## Consequences

- A user who needs a recapture of a child page must handle it outside QC.
- `backend/repair_split_manifests.py` repairs children that were split before the manifest fix.

## Don't change this unless

You build and test the parent-resolving rework path from start to end.
