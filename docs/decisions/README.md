# Decision records

Short records of choices that a newcomer could break by "fixing" them. Each record has Status, Context, Decision, Consequences and "Don't change this unless". Records are in English only.

To add one, copy the last file, use the next number, and add a line here.

| No. | Decision |
| --- | --- |
| [0001](0001-geometry-is-data-until-export.md) | Geometry is data until export. Nothing re-encodes a page before the TIFF. |
| [0002](0002-lwip-crops-losslessly.md) | LWIP crops JPEGs losslessly with `jpegtran` and never rotates. |
| [0003](0003-mixed-line-endings-no-text-conversion.md) | Mixed line endings; `* -text`; git converts nothing. |
| [0004](0004-packages-published-by-atomic-rename.md) | Delivery packages are published by atomic rename. |
| [0005](0005-client-rework-keeps-group-id.md) | Client rework republishes under the same Group ID. |
| [0006](0006-one-shared-database-login.md) | One shared database login for every part. |
| [0007](0007-parts-talk-through-the-database-and-folders.md) | Parts share only the database and folders. |
| [0008](0008-services-use-unc-paths-not-drive-letters.md) | Services run as SYSTEM and refuse mapped drive letters. |
| [0009](0009-approved-folders-export-on-a-sweep.md) | Approved folders export on a sweep, not on approve. |
| [0010](0010-separated-children-cannot-be-rejected.md) | A separated child folder cannot be rejected for recapture. |
| [0011](0011-schema-upgrades-only-through-database-setup.md) | Migrations are applied only by LWCamDatabaseSetup, and parts gate on schema level. |

Background: [FAMILYSEARCH-FIX.md](../FAMILYSEARCH-FIX.md) explains why records 0001 and 0002 exist.
