# Contributing

English | [简体中文](CONTRIBUTING.zh-CN.md)

This guide tells you how to change LWCam and get the change merged. For setup
read `docs/DEV-SETUP.md`. For the tests read `docs/TESTING.md`. For the design
rules and traps read `AGENTS.md`.

## Branches

| Branch | Use |
| --- | --- |
| `lwcam-module` (default) | Module edition: five installers. New work goes here. |
| `lwcam-all-in-one` | All-In-One edition: one older installer. Kept for existing sites. |
| `feat/<short-name>` | A new feature, branched from `lwcam-module`. |
| `fix/<short-name>` | A bug fix, branched from `lwcam-module`. |

`archive/*` branches are read-only history. Do not push to them.

Clone the repository the normal way. You do not need git worktrees.

```bash
git clone https://github.com/djchoy-LW/LWCAM-Suite.git
cd LWCAM-Suite
git switch -c fix/short-name
```

## Pull-request flow

The GitHub plan is Free, so GitHub does not enforce reviews or run CI. The team
keeps the rules by hand:

1. Open an issue first for anything bigger than a small fix. Use the module
   label (see "Issues and labels").
2. Branch from `lwcam-module`. Keep the branch small and focused.
3. Run the test suites for the modules you changed. The commands and the
   expected counts are in `docs/TESTING.md`.
4. Open a pull request into `lwcam-module`. Paste the test results into the
   description (command and pass/fail counts).
5. Ask a teammate to review. Do not merge your own pull request without a
   review, even though GitHub allows it.
6. Merge after the review is addressed. Delete the branch.

## Commit messages

Use conventional commits, as in `git log`:

```
type(scope): short summary in the imperative
```

| Type | Use |
| --- | --- |
| `feat` | A new user-visible capability |
| `fix` | A bug fix |
| `docs` | Documentation or comments only |
| `chore` | Renames, cleanup, tooling |
| `build` | Build or packaging changes |
| `perf` | A performance change |
| `refactor` | A change with no behaviour change |

Scopes: `lwcam`, `lwcam-admin`, `lwip`, `qc-platform` (or `qc`), `upload`,
`installer`, `db`. You may combine scopes with a comma (`feat(lwip,qc): ...`).
Examples from the history: `fix(upload): retry a failed package at once when it
changes`, `feat(db): one shared LWCam login chosen at install`.

Write the body for the reader a year from now: say why, not only what.

## Line endings

`.gitattributes` sets `* -text`. Git converts nothing, and the line endings are
**mixed, per file**: some files are CRLF and some are LF. Keep the style a file
already has.

- Check a file before you rewrite it: `file <path>`.
- Do not re-save a whole file with another style. The commit would show every
  line as changed.
- Git Bash `sed -i` turns CRLF into LF. Use an editor that keeps the style.
- Before you commit, run `git diff --stat`. A small change must show a small
  number of lines. If it shows the whole file, you changed the line endings.

## Code style

- **Comments and identifiers are in English.**
- **Dart (LWCAM, LWCam Admin):** `flutter analyze` must not get worse. The
  lints come from `flutter_lints`; `analysis_options.yaml` in each app turns off
  `avoid_print`, `deprecated_member_use` and
  `no_leading_underscores_for_local_identifiers` on purpose. `print` logging is
  the established style. Run `dart format` only on the lines you changed; do not
  reformat a whole file.
- **Python (LWIP, QC backend, Upload):** Python 3.14. Use type hints and
  `from __future__ import annotations`, as the existing files do. Put a short
  docstring at the top of each module. Tests are `unittest.TestCase` classes
  that must run without pytest: no `conftest.py`, no fixtures.
- **Vue/TypeScript (QC console):** `npm run build` runs `vue-tsc --noEmit`; it
  must pass.
- **Byte-identical files.** `lwcam_secrets.py`, `tls.py`, `netlogin.py` and
  `geometry_replay.py` exist in more than one module. A test in each suite fails
  when the copies differ. Edit one copy, copy it to the others, run the suites.
- A bug fix needs a test that fails without the fix. Check that it does.

## CHANGELOG

Write one entry in `CHANGELOG.md` for every user-visible change (a feature, a
behaviour change, a fix a user can notice). Do not add entries for refactors or
documentation. Group by version; newest first.

## Database schema changes

1. Add a new numbered file in `LWCam_QC_Platform/database/migrations/`, for
   example `009_short_name.sql`. Never edit an old migration.
2. Make it safe to run twice (`IF NOT EXISTS`, and so on). `setup_qc_db.py`
   applies every migration in name order and records each in `schema_migrations`.
3. Grant the new objects to the group role `lwcam_app` as needed. Run
   `scripts/check_role_grants.py` against a test database.
4. Raise the required level in the code that needs the new schema. The level is
   the highest migration number. Today QC requires 8
   (`REQUIRED_SCHEMA` in `LWCam_QC_Platform/backend/app/services/schema_check.py`),
   and LWCAM (`kRequiredSchema` in `LWCAM/lib/services/sync_sink.dart`), LWIP
   (`cloud_report.py`) and Upload (`health.py`) require 7. Raise only the parts
   that really need the new objects.
5. Remember the rollout: `LWCamDatabaseSetup` must run on the database PC before
   a part that needs the new level starts. Say so in the changelog.
6. Run the database tests (`tests/test_setup_qc_db.py`) against a local
   PostgreSQL.

## Secrets

Never commit real configuration or secrets: passwords, keys, `config.txt`,
`upload_config.json`, `deskew_crop_config.json` with a real login, certificates,
PostgreSQL dumps, customer images. Commit only `*.example` files
(`config.example.txt`, `upload_config.example.json`,
`deskew_crop_config.example.json`). If you commit a secret by mistake, tell the
project lead at once: the secret must be rotated, and removing it from the next
commit is not enough. See `SECURITY.md`.

## Issues and labels

Work is tracked in GitHub Issues. Give each issue:

- one **module** label: `lwcam`, `lwcam-admin`, `lwip`, `qc-platform`, `upload`,
  `installer`, `database`, `docs`;
- one **type** label: `bug`, `enhancement`, `refactor`.

## Bringing a fix to the other edition

A fix may belong in both editions. Make it on `lwcam-module` first, then bring
it to `lwcam-all-in-one` with `git cherry-pick`:

```bash
git switch lwcam-all-in-one
git switch -c fix/short-name-aio
git cherry-pick <commit>
```

Both editions keep the apps at the repository root. The one path difference is
LWIP: `LWCAM/LWIP/` in the All-In-One edition, `LWIP/` here. Git's rename
detection often handles it. If the
cherry-pick conflicts, apply the change by hand to the file at the new path.
The two `AGENTS.md` files will always conflict. The All-In-One edition also has
features the Module edition does not (daily colour calibration, AI-review
reliability, volume carry-over pre-fill); do not copy those back by accident.
Test both editions: the All-In-One suites have different counts.
