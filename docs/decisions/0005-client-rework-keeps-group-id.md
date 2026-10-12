# 0005. Client rework republishes under the same Group ID

- **Status:** Accepted

## Context

When a client asks for changes to a delivered package, the client's rule (FamilySearch) is that the corrected package replaces the old one under the same Group ID. A new ID would leave two packages for the same folder.

## Decision

- `revert` returns a finished folder to PENDING with `client_rework = true`. It clears `is_exported` and keeps `group_id`. It claims the folder for the reviewer who reverted it.
- Approval then sends the folder through the normal export sweep. The package is replaced in place, and the CSV's Rework column is `TRUE`.
- Four guards stop double publishing, and each has a rework-only exception: the export's adopt branch, `publish_zip` and `publish_folder`, the Upload ledger's "already uploaded" skip, and `move_to_done`.
- Upload detects the change through a content fingerprint and uploads again. It replaces the bucket copy and the `done_root` copy.
- `revert` checks the one-task-per-person rule before it changes anything.

## Consequences

- The rework-only exceptions look like bugs ("why republish a finished package?"). They are the feature.
- The CSV values `TRUE` and `FALSE` are text. In Python `bool("FALSE")` is true. Compare to the string.

## Don't change this unless

The client changes its rule. Test the full loop: revert, edit, approve, republish, upload again.
