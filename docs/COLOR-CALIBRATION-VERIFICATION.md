# ColorCal directory integration verification — 2026-10-20

Only the module edition was edited. The all-in-one reference directory was not
modified. No installation, database schema change, commit or push was performed.
Unrelated `.idea/` and `debug.log` remain untouched. Before this refactor, changed
source was backed up to ignored `artifacts/colorcal-directory/before.zip` and
`before.patch`.

## Automated evidence

Windows, Python 3.14.6 venv, Flutter 3.47.7 / Dart 3.13.5. Pristine HEAD baseline
was extracted to `artifacts/colorcal/baseline` before the original calibration
implementation. The pre-directory implementation had 487 capture tests and 239
LWIP tests; the standalone algorithm had 59 tests (2 skips).

| Check | Final result | Evidence under artifacts/colorcal-directory |
| --- | --- | --- |
| Capture Flutter | 491 passed | capture-verified.log |
| Capture analyzer | Only the 5 original brace-style infos; no new errors/warnings | analyze-final3.log |
| Admin Flutter / analyzer | 136 passed / clean | admin-final.log; combined analyzer log |
| LWIP Python | 313 run, 9 skipped; passed | lwip-verified.log |
| QC Python | 402 run, 8 skipped, 1 existing failure | qc-full-native.log |
| QC frontend | Build passed; existing large-chunk warning | frontend-final.log |
| Installer PowerShell | Syntax parser passed | Verified without executing installation |
| Consumer parity | LWIP/QC five consumer files byte-identical | Included in LWIP suite and installer build check |
| Old document discovery negative control | New test fails with old scan that admits .calibration | negative-directory.log |
| Old JPEG direct-copy negative control | New calibrated-JPEG test fails with old if-not-ops branch | negative-jpeg.log |

Counts: 59 algorithm tests moved into LWIP, plus 15 new queue/protocol tests,
so 239 + 59 + 15 = 313. Capture's obsolete local-runtime/process tests were
replaced with directory submission, recovery, identity/hash, cancellation and
confirmation tests; the net total increased from 487 to 491.

QC's one failure is
`tests.test_sweep_switch.SweepSwitchTests.test_stop_ends_the_loop_whatever_the_switch_says`
(`wait_for_tick`): it also fails in the pristine 392-test suite. See
`artifacts/colorcal/LWCam_QC_Platform-clean-full.log`. This is **not** reported as
a passing QC suite. No database integration credentials were supplied.

One intermediate QC run forced PYTHONUTF8 and additionally failed the existing
PowerShell provisioner self-test decoding Windows output. Re-running with native
Windows encoding removed that extra failure. One intermediate LWIP run timed out
on an existing console-login socket test; the final full 313-test run passed.
No test was disabled or assertion relaxed to obtain these results.

## Coverage retained and added

- Shared Dart/Python fixtures: committed request, ready hash, success, failure,
  corrupt ready/result, parameter validation.
- No ready means no analysis; damaged request/image never runs the algorithm;
  unsupported protocol has a separate code; malformed JSON produces failure.
- Duplicate completion is idempotent; same UUID/different bytes conflicts;
  exclusive consumer lock; restart of interrupted analysis; retry publication
  from local output without rerunning; owned-child execution deadline.
- A real child process imports the migrated algorithm and analyses a generated
  JPEG. The 59 migrated algorithm tests include synthetic chart fitting.
- Both document depths exclude the reserved chart root. Negative controls are
  temporary in-memory mutations, never working-tree edits.
- Capture persists immutable local requests, restores pending tasks, checks
  device/phone/request/photo hashes, refuses unsafe attachment names and corrupted
  profiles, leaves successful results unactivated until confirmation, rejects
  stale or superseded confirmations and preserves abandoned photographs.
- Late wait results/progress cannot replace a newer controller operation.
  Shared I/O is asynchronous and bounded; timed-out OS calls retain a barrier
  so polling does not accumulate unbounded outstanding share calls.
- Existing per-page snapshots, mixed profiles/skips, capture-boundary protection,
  SQLite recovery, recapture intent integrity, LWIP parameter fingerprints, QC
  cache/export checks, external-page exemption, separation and encode-once tests
  remain in their original suites.

## Build and field acceptance record

| Acceptance item | Status | Reason / next action |
| --- | --- | --- |
| Three installer configurations | Updated, static checks passed | LWCam has no calibration Python; LWIP bundles full algorithm/entry; QC keeps consumer copies |
| Actual installer binaries | Environment blocked | installer/vendor, LWIP/wheels and both Flutter Release executables are absent |
| Capture PC without Python/LWIP, real chart and phone | Not tested | Requires physical capture PC and phone; file-client tests do not replace this |
| Separate-PC SYSTEM share access / disconnect / reboot | Not tested | Local failure simulations passed; real SMB credentials and boot-task behavior need site validation |
| Multiple capture PCs and live test database | Not tested | No physical two-PC setup or test database credentials provided |
| 10–20-page and site-scale batches | Not tested | Requires representative photographs and actual site configuration |
| Lossless installed JPEG trim | Not tested here | jpegtran is absent; relevant existing tests skip. Input bytes are protected, but source-checkout fallback re-encodes the OUTPUT without jpegtran |
| Installation/upgrade task count | Not tested on installed host | Scripts retain the existing LWCam LWIP task only; no Calibration task added |
| Actual colour accuracy / throughput | Not claimed | Existing algorithm reused; site camera and lighting need validation |

Use [deployment, source running, recovery and two-PC steps](COLOR-CALIBRATION.zh-CN.md)
and [protocol v1](CALIBRATION-PROTOCOL.md). Upgrade QC → LWIP → LWCAM/Admin;
keep colour calibration disabled until all consumers are upgraded and field
acceptance passes. Shared PostgreSQL schema and Upload remain unchanged.
