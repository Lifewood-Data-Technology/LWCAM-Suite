# 0009. Approved folders export on a sweep, not on approve

- **Status:** Accepted (2026-09-21)

## Context

It looks simpler to start an export from the approve handler. Two structural facts stop that. A QC user approves, and every export route needs the Admin role. And `ExportCoordinator.start` refuses while a run is alive, so two near-simultaneous approvals would lose one. A PASS folder would stay unexported, and nothing would record the need.

## Decision

`ExportAutoScheduler` starts a run every 30 seconds for every eligible folder. The setting `exportAutoEnabled` turns it off. The sweep reads that switch on every tick, so a console save applies without a restart. A key missing from `config.txt` reads as true.

## Consequences

- Turning the sweep off asks for confirmation. It changes what the site produces.
- A switch that is read only at start passes every unit test that builds a fresh object. An earlier bug let the export and upload sweeps keep working while switched off. The gate now lives in `_run`, and `tests/test_sweep_switch.py` holds it.
- A malformed boolean or integer in `config.txt` raises an error instead of using a default. This file decides whether deliveries are lossless.

## Don't change this unless

You also solve the role problem and the lost-second-approval problem, and you add a test that flips the switch on a running engine.
