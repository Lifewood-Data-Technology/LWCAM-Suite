# 0012 — Colour calibration is bound per page at capture

Accepted: 2026-10-19, Issue #1.

LWIP owns ColorCal inside its existing service. Capture submits immutable
folder tasks under destinationPath/.calibration; no local Python, HTTP calls,
or process control. LWIP analyses in one owned short-lived child at a time.
An atomic result is validated and explicitly confirmed on the capture PC.
Capture date, phone, station and exact-byte hashes are part of the contract.
A station/phone/day gate may explicitly skip calibration. Each newly assigned
page freezes its parameters in the local ledger; transfer carries those values,
never the active profile at transfer time. Old/unattributed pages are uncalibrated.

The completion marker and LWIP manifest carry a versioned profile dictionary
and per-filename bindings. Profile keys hash the exact UTF-8 JSON string, avoiding
Dart/Python numeric canonicalisation differences. Declared but invalid data fails
closed. Calibration-only changes invalidate the LWIP fingerprint and QC cache.

LWIP corrects thumbnails only. QC renders from source and applies geometry,
then calibration, before the final encoding. Approving pure geometry still writes
only operations. External QC pages are exempt independently of ignore_lwip.

Recapture preserves a durable image/profile pair and holds the completion gate
until both are installed. A restart does not auto-submit an unconfirmed pair;
the page must be re-staged (the abandoned photo is kept for the deferred
task-lifecycle cleanup). Ordinary metadata-only submission never opens the photo
share. Versioned local intents record applying before the first remote marker
write; pending replacements still block closure. A generation receipt commits
with the SQLite closure, so failed intent cleanup does not strand later metadata.
Only ambiguous pre-v2 intents need a bounded legacy source/gate check. Split
children keep only their pages' bindings.
Consumers bundle byte-identical application/validation code; no runtime imports
or RPC calls cross installations. Upgrade QC and LWIP before enabling capture.

See [deployment and acceptance](../COLOR-CALIBRATION.zh-CN.md).
