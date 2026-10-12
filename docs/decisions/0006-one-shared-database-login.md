# 0006. One shared database login for every part

- **Status:** Accepted (2026-10-01; replaces five per-part logins)

## Context

Every part first signed in as `postgres`. Five per-part logins followed (`lwcam_qc`, `lwcam_lwip`, `lwcam_upload`, `lwcam_capture`, `lwcam_admin`). A site then had to enter and rotate five passwords on many PCs.

## Decision

- `LWCamDatabaseSetup.exe` asks for one database name, port, user (default `lwcam_user`) and password (12 characters or more).
- The user is a member of the NOLOGIN group role `lwcam_app`. Migration `006` gives that role exactly what the parts need: column-level UPDATE, no CREATE on `public`, no superuser, createdb, createrole or replication, and USAGE only on the export sequences.
- Migration `008` adds `lwcam_next_export_number` and `lwcam_change_own_password`. Both are SECURITY DEFINER functions with a fixed `search_path`.
- The old five logins become members of `lwcam_app` when they exist, so older installs keep working.
- `pg_hba.conf` admits only members of `lwcam_app`, over TLS, from the local subnet and Tailscale.

## Consequences

- A leaked password can read and edit the LWCam tables. It cannot run programs on the database PC, create tables or drop the database.
- To change the password, run `LWCamDatabaseSetup.exe` again, then update every part.
- Row-level security on `app_settings` was removed, because one login cannot tell the parts apart.
- Secrets in config files are stored as `dpapi:...`. See [ARCHITECTURE.md](../ARCHITECTURE.md), section 8.

## Don't change this unless

You also change the grants in `006` and `008`, the installers, and every part's login page. Never give the shared login more rights to make a feature work. Add the one grant it needs, column by column.
