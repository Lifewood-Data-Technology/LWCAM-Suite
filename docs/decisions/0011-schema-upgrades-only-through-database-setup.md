# 0011. Migrations are applied only by LWCamDatabaseSetup, and parts gate on schema level

- **Status:** Accepted (2026-09-23, 2026-09-25)

## Context

`setup_qc_db.py` once named migrations `001` to `003` by hand. Migrations `004` and `005` therefore reached no site. Fresh installs lacked `qc_reviewed_by` and `separated_from_folder_id`, and every QC tab answered "Internal Server Error". Writing a migration does not apply it.

## Decision

- `setup_qc_db.py` applies every `database/migrations/*.sql` file in name order, on new and existing databases. Each migration is safe to run again. The unified dump loads only into an empty database.
- Migrations `006` to `008` run in one transaction with a 30 second lock timeout.
- Only `LWCamDatabaseSetup.exe` runs the script. Every part checks `schema_migrations` and refuses to work against a database below its required level (QC 8, the others 7).

## Consequences

- When you add a migration, add the file and raise the required level in each part that needs it. Nothing else lists it.
- On an upgrade, run `LWCamDatabaseSetup.exe` on the database PC before you upgrade any other part.
- After you write a migration, apply it and check the result.

## Don't change this unless

You replace the whole mechanism (for example with Alembic) and keep the schema-level gate.
