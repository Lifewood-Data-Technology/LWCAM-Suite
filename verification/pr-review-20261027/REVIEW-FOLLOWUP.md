# PR #1 review follow-up: recovery and rework

Validated on Windows with Python 3.14.8, Flutter, and PostgreSQL on 2026-10-28.
This records validation of the complete source submitted for review. The
original colour integration and QC toolbar change remain in the PR. The initial
blocking/recovery fixes and the subsequent metadata-share correction are kept
as follow-up commits for review.

## Blocking 1: recovery integrity permanently blocks every transfer

The production transfer path now checks the selected folder's pages rather
than throwing on a global `color_integrity` row. Valid profiles and their
payloads survive recovery and transfer, including when new calibration is off.
Missing or unreadable old databases mark recovered unknown bindings explicitly.

Unknown pages show the folder, filename and recovery reason. The operator can
accept historical/uncalibrated status explicitly; the decision is audited and
does not replace valid bindings. The global flag clears only after every OPEN
page has a valid decision. Damaged bindings and pending replacements remain
actionable failures rather than being silently accepted.

Policy detail for review: disabling calibration affects new capture and does
not erase historical parameters. Unknown recovered pages still require an
explicit decision even when calibration is off. This deliberately retains a
stricter check than the suggested switch-only bypass; maintainer acceptance
of that behaviour is still required.

Coverage includes `box_color_preflight_test.dart`, `color_binding_test.dart`,
`stable_schema_recovery_test.dart`, and `processing_marker_service_test.dart`.

## Blocking 2: abandoned recapture intents survive Undo, box switch or restart

Undo and box-staging cleanup discard the matching durable intent. Submit only
loads `pending()` for an item actually staged in the current session. An old
abandoned intent cannot silently turn a Metadata resolution into Recapture.

An overwrite that has started is different: its applying record survives until
photo installation, profile binding, marker updates and closure finish. Undo
refuses that incomplete operation and allows Submit/restart recovery. Closure
and folder metadata/reset are queued in one SQLite transaction per folder;
failures keep the remaining work retryable.

The metadata-share follow-up removes input-file resolution from ordinary
metadata-only submission. Local v2 intents persist applying before the first
remote marker write, and guard the whole folder, including siblings outside the
current worklist. Exact-generation receipts commit with closures in SQLite, so
failed intent cleanup does not block later metadata or exempt a newer overwrite.
Ambiguous pre-v2 intents alone require a bounded source/gate recovery check;
when that legacy share is unavailable, the operation stays open with a reason.
No database schema or image-processing algorithm changes are needed.

Completion checks its own generation before deleting an intent. A regression
test reproduced the old cleanup deleting a newer applying generation before
the fix; unreadable intent cleanup is also covered. Tests are in
`rework_staging_test.dart`, `rework_helpers_test.dart`, `color_rework_test.dart`,
and `color_rework_lifecycle_test.dart`.

Final review also covered re-entry after a closure committed but intent cleanup
failed. Recovery now checks the exact committed generation before reading or
re-staging old pixels, and a new photo does not inherit a finished operation's
applying flag. Uncommitted/newer generations still recover normally. The missing
recovery-entry assertion failed before this final correction; the page-entry
call followed by Metadata submission is now in the integration host as well.

## Other review findings addressed

- Completed LWIP tasks use cheap stat signatures, with full validation after
  restart/change or before result republication. Completed tasks are archived
  before local work/ledger cleanup; active work remains protected.
- Capture staging and calibration caches have retention, protecting active
  intents and untransferred replacement overlays. Interrupted capture-slot
  overlays can be recovered without repeating an uncertain phone rename.
- Transient serial/listing failures do not freeze an invalid daily session.
  Serial identity is cached per session; timed-out adb probes are terminated.
- Older marker-less recaptures regain a guarded marker. Empty/BOM markers with
  no calibration are accepted; damaged calibration remains a failure.
- QC checks its own colour-consumer parity, the real calibration gate is used,
  and the installer removes the colour consumer's stale bytecode directory.
- All three identical TLS implementations retain localhost HTTPS after a
  network change by restricting renewed leaves to the existing CA's permitted
  names. The CA is not widened or replaced to bypass NameConstraints.

## Validation

| Suite / check | Latest result |
| --- | --- |
| LWCAM `flutter test` | 546 passed after the final recovery-entry review |
| LWCAM `flutter analyze` | Existing 5 style infos; no error/warning |
| LWCam Admin test / analyze | 136 passed / clean |
| QC backend unittest | 405 run: 397 passed, 8 skipped |
| LWIP unittest | 328 run: 324 passed, 4 skipped |
| Upload unittest | 160 passed |
| One-off atomic overwrite / real PostgreSQL acceptance host | 26 passed after the final recovery-entry review |
| Both Flutter Windows Release builds | Passed; latest cleanup guard present in capture AOT |
| Shared TLS and colour consumer parity / whitespace | Passed |

Run the ordinary suites using the commands in `docs/TESTING.md`. The extended
26-case local host extracted the production Submit/Undo/button and Windows
atomic-overwrite bodies; it substituted UI/path/phone seams, used real SQLite
and session-temporary PostgreSQL tables, and injected file/transaction faults.
It also checked real PG snapshot/rebuild and calibration-off marker publication,
zero input-share probes for ordinary metadata submissions, interrupted local
records, mixed-folder failures, commit receipts and the offline-share PG path.
It is a one-off local acceptance host, not an additional portable CI suite.

The 20 portable tests in `metadata_rework_guard_test.dart` cover local-only
eligibility, Undo, restaging, changed roots, siblings, legacy recovery, committed
receipts, rollback and newer-generation protection. The ordinary offline-share
Submit regression failed with the previous production method (two source probes
instead of zero), then passed with the fix. Earlier non-LWCAM suite results
above remain unchanged; no Python service or Admin source changed in this patch.
The final review's first PG-host run had seven connection failures while Docker
was unavailable; restoring the existing PG container and rerunning passed all
26 cases. That failed run is preserved separately from the passing result.

On 2026-10-27, controlled native UI checks and the real QC/LWIP web consoles
covered a dedicated synthetic folder: QC reject, phone-free production Submit,
background LWIP republication/cloud reporting, and QC preview of the replacement
and its new profile. On 2026-10-28 the persisted result was read back: PENDING,
unclaimed, all processing flags true, latest rework CLOSED/Recapture, no held
gate, empty local outbox, matching photo/profile, and an untouched disabled
second page. This readback was not another UI round trip. The final cleanup
boundary change was covered by the current suites and 16-case host.

The initial offline-PG run failed six connection-dependent integration cases
and one QC sweep timing assertion. The same sweep assertion reproduced in a
clean HEAD snapshot. Restoring PostgreSQL and rerunning made both full QC and
the 16-case host pass. No assertion was weakened to obtain those results.

## Limits

- The latest QC suite skipped 8 database-provisioning tests. The separate PG
  acceptance host covers rework/recovery transport, not database provisioning.
- No phone/USB or physical colour-card accuracy was retested. The phone-free
  scope was agreed in advance. Separate real PCs, SYSTEM/SMB permissions, real
  S3 delivery and power-loss recovery remain unproven.
- Latest local tests establish the stated behaviour, not a blanket guarantee
  against all related defects or approval by the maintainer.
