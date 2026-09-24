"""A sweep's switch takes effect on the next tick, in both directions.

Found on the station 2026-09-22, testing exportAutoEnabled properly for the
first time. Folder 14 was approved at 13:56:09 with the switch off - false in
config.txt, false in the settings singleton, and rendered off on the Settings
screen - and the sweep exported it at 13:56:48 anyway, as group ...000013.

PeriodicSweep read `enabled` only in `start()`; `_run` then ticked until
`stop()`. So a save after boot changed nothing, and the reverse failed too: a
sweep that booted disabled had no thread, so turning it on also needed a
restart. Of the three sweeps only the AI pre-analysis one escaped, by checking
its own switch again at the top of `scan_once`; export and upload did not, and
both did real work - exporting, uploading - while switched off.

The thread now always runs and idles, and the tick is what the switch gates.
These tests drive the loop directly rather than through a scheduler, because
what broke is the base class the three of them share.
"""

from __future__ import annotations

import threading
import unittest

from app.services.sweep import PeriodicSweep


class SweepSwitchTests(unittest.TestCase):
    def setUp(self) -> None:
        self.ticks = 0
        self.ticked = threading.Event()
        self.switch = True

    def _tick(self) -> None:
        self.ticks += 1
        self.ticked.set()

    def sweep(self) -> PeriodicSweep:
        sweep = PeriodicSweep(
            "test-sweep",
            tick=self._tick,
            # Short enough that a test never waits on the clock; every wait
            # below is on the event the tick sets, not on this.
            interval=lambda: 0.01,
            enabled=lambda: self.switch,
        )
        self.addCleanup(sweep.stop)
        return sweep

    def wait_for_tick(self) -> bool:
        self.ticked.clear()
        return self.ticked.wait(2)

    def test_turning_the_switch_off_stops_the_ticks(self) -> None:
        """The station case: a running sweep, switched off, must stop working."""
        sweep = self.sweep()
        sweep.start()
        self.assertTrue(self.wait_for_tick(), "the sweep never ran while enabled")

        self.switch = False
        self.ticked.clear()
        # Two intervals' worth of chances to tick, which the old loop took.
        self.assertFalse(self.ticked.wait(0.3), "the sweep ticked while switched off")

    def test_turning_it_back_on_needs_no_restart(self) -> None:
        """And the direction the old start()-only gate failed silently on."""
        self.switch = False
        sweep = self.sweep()
        sweep.start()
        self.assertFalse(self.ticked.wait(0.2), "a disabled sweep ticked")

        self.switch = True
        self.assertTrue(self.wait_for_tick(), "re-enabling did not resume the sweep")

    def test_a_sweep_that_boots_disabled_still_has_its_thread(self) -> None:
        """Because without one there is nothing for a later save to re-enable."""
        self.switch = False
        sweep = self.sweep()
        sweep.start()

        self.assertTrue(sweep._thread_alive())
        # ...but it reports itself as not running, which is what the console
        # shows for the AI scanner - an idling thread is not a working one.
        self.assertFalse(sweep.is_running())

        self.switch = True
        self.assertTrue(sweep.is_running())

    def test_start_is_idempotent(self) -> None:
        """The guard moved to _thread_alive; a second start must not add one."""
        sweep = self.sweep()
        sweep.start()
        first = sweep._thread
        sweep.start()

        self.assertIs(first, sweep._thread)

    def test_stop_ends_the_loop_whatever_the_switch_says(self) -> None:
        sweep = self.sweep()
        sweep.start()
        self.assertTrue(self.wait_for_tick())

        sweep.stop()

        self.assertFalse(sweep._thread_alive())
        self.assertFalse(sweep.is_running())
