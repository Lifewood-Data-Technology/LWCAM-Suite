English | [简体中文](TESTING.zh-CN.md)

# Testing

This page lists every test suite, where to run it, and the result you should see on a clean checkout. Set up your tools first: [DEV-SETUP.md](DEV-SETUP.md).

If a count differs from the table, the change is yours. Find out why before you open a pull request.

## 1. The suites

| Suite | Run from | Command | Expected on a clean checkout |
| --- | --- | --- | --- |
| QC backend | `LWCam_QC_Platform/backend` | `python -m unittest discover -s tests -t .` | 405 tests, 8 skipped (database tests, see section 2) |
| QC frontend | `LWCam_QC_Platform/frontend` | `npm ci` then `npm run build` | Builds with no type errors. The build runs `vue-tsc --noEmit && vite build`. |
| LWIP | `LWIP/backend` | `python -m unittest discover -s tests` | 328 tests; skips and the two long-path controls depend on the environment (section 3) |
| Upload | `LWCam_Upload/backend` | `python -m unittest discover -s tests` | 160 tests pass |
| LWCAM | `LWCAM` | `flutter analyze` then `flutter test` | Analyze: 5 infos. Test: 546 pass. |
| LWCam Admin | `LWCamAdmin` | `flutter analyze` then `flutter test` | Analyze: clean. Test: 136 pass. |

The ColorCal algorithm tests (59, including 2 skips) and directory protocol tests (23) are included in LWIP. Shared transport fixtures live in `verification/calibration_protocol`. See [current verification](COLOR-CALIBRATION-VERIFICATION.md) for environment-specific failures and field-test limits.

The Python suites use `unittest`. You do not need pytest. `LWIP/RUN_TESTS.bat` runs the LWIP suite with a private runtime that setup built; on a dev PC use the command above.

Use `python` from your Python 3.14.8 install. Run the Python suites with `unittest discover -s tests -t .` or `-s tests` as shown. This form puts the working tree on `sys.path`. Do not test with the `._pth` runtime of an installed copy (see the trap in [DEV-SETUP.md](DEV-SETUP.md)).

Some log lines in a green QC run are normal. "cv2 is not importable; falling back to Pillow BICUBIC" comes from a test that hides `cv2` on purpose. "AI review OpenRouter call failed" comes from the retry tests that use a stub.

## 2. QC backend: database tests

The database tests (in `tests/test_setup_qc_db.py`, and possibly others) need a reachable PostgreSQL. Without credentials they skip. These are the skipped tests in the clean-checkout count. To run them, give them an administrator login that can create a scratch database:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LWCAM_DB_PASSWORD` | none (tests skip) | Password of the PostgreSQL administrator |
| `LWCAM_DB_USER` | `postgres` | Administrator user |
| `LWCAM_DB_HOST` | `localhost` | Host |
| `LWCAM_DB_PORT` | `5432` | Port |

Example:

```
set LWCAM_DB_PASSWORD=<postgres password>
python -m unittest discover -s tests -t .
```

If `LWCAM_DB_PASSWORD` is not set, the tests read `dbHost`, `dbPort`, `dbUser` and `dbPassword` from `LWCam_QC_Platform/config.txt` when that file exists. The tests create and delete a scratch database whose name starts with `lwcam_setup_test_`. They do not touch your real database.

Not confirmed: the exact count of skipped tests when the variable is set. Check it on your PC and note it in your pull request.

## 3. LWIP: two known failures

`tests/test_long_paths.py` has two negative controls:

- `test_a_long_path_is_writable_only_through_fs_path`
- `test_the_same_folder_fails_without_the_guard`

They check that a path longer than 260 characters fails without the `\\?\` guard that LWIP uses. On a PC where Windows long-path support is on, the long path works even without the guard. The tests then fail, because they expect an error. The code is not wrong. Expect these 2 failures on a PC with long paths enabled. A PC without long-path support should pass them. The 7 skips are tests for other platforms or other conditions (for example `test_non_windows_is_untouched`, which runs only on POSIX).

## 4. Flutter notes

- LWCAM `flutter analyze` reports 5 infos of type `curly_braces_in_flow_control_structures`, in `box_session_controller.dart`, `box_integrity.dart` (two), `pg_sync_sink.dart` and `transfer_queue_service.dart`. A new info or warning is a regression.
- Run `flutter pub get` first on a fresh clone.

## 5. End-to-end checks

The repository has no automated end-to-end harness. The `verification/` folder holds one-off research scripts for image processing (geometry, tone, export fidelity). They are not a test suite and they need sample images. See [FAMILYSEARCH-FIX.md](FAMILYSEARCH-FIX.md) for what they measured.

To test the whole pipeline, use the manual run in [INSTALL.md](INSTALL.md), section 9 ("Check that it works"). For a test folder without a camera, see [DEV-SETUP.md](DEV-SETUP.md), section 7.

## 6. Before you open a pull request

1. Run the suites for every module you changed. Run all of them if you changed shared code (the database schema, `lwcam_secrets.py`, the export format).
2. Compare each result with the table in section 1.
3. If you changed the QC frontend, run `npm run build`.
4. If you added a database migration, run the QC backend tests with `LWCAM_DB_PASSWORD` set. Also run `python scripts\setup_qc_db.py` against a scratch database twice.
5. If you changed `lwcam_secrets.py`, change all four copies the same way. They must be byte-identical. The installer build checks this.
6. Check line endings (`file <path>`) and `git diff --stat`. A small change must not show every line as changed.
7. Add a line to `CHANGELOG.md` for any change that a user or a site would notice.
8. Write in the pull request which suites you ran and the counts. The GitHub plan has no required reviews and no CI, so these local checks are the only gate.

## 7. Manual test checklist for a release

Do these on real, separate PCs. One PC cannot prove them. The full checklist is [INSTALL.md, section 14](INSTALL.md#14-prove-a-site-on-separate-pcs).

- [ ] **SYSTEM login to a real peer.** On each service PC, the saved network folder login works for the SYSTEM account (test with a scheduled task or `psexec -s`). Error 1219 appears when QC, LWIP and Upload share one PC and reach the same peer with different accounts. Use one account per peer.
- [ ] **Share comes back after the peer reboots.** Reboot the peer. The service PC reaches the share again with nobody logged on, and the status sentence clears.
- [ ] **Capture at another site to LWIP input over Tailscale.** Measure the copy speed for a real batch. Run `cmdkey` for the interactive Windows user on the capture PC. Check that the copy timeout fits your link.
- [ ] **QC with `qcInputRoot` set to LWIP's UNC share.** Review and approve a normal folder and a split folder (one batch that LWIP wrote in parts).
- [ ] **Database PC hard power-cycle** in the middle of a batch, an export and an upload. Every part goes red, then recovers alone. Nothing is lost or duplicated.
- [ ] **QC PC power cut in the middle of an export.** The folder can be exported again within about 2 to 3 minutes.
- [ ] **Browsers reach every console by MagicDNS name,** with Tailscale started after the services. The certificate must still match the name.
- [ ] **A real S3 upload,** including a client-rework re-upload of a package that was already uploaded.
- [ ] **Upgrade path.** Install the previous release, then upgrade in the order in [INSTALL.md](INSTALL.md), section 11. Check the System status page and a rework round trip.
- [ ] **Backup and restore.** Run a backup, restore it on a scratch PC, and check that a part signs in.

Note: when Upload's `done_root` is on another volume than the export share, a finished package is copied and then deleted over SMB. This is slower. The Upload login needs delete rights on the export share.
