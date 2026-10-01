"""One background thread that calls a function on a timer.

The export, upload and AI pre-analysis workers are all the same shape: while
their switch is on, run `tick()` every `interval()` seconds on a daemon thread,
log a failure and carry on, stop cleanly at shutdown. They used to be three
hand-written copies of that loop; a fix in one had to be repeated in the others.
"""

from __future__ import annotations

import logging
import threading
from typing import Callable

logger = logging.getLogger(__name__)


class PeriodicSweep:
    """Runs `tick` every `interval()` seconds on a daemon thread, while enabled.

    `expected` names exception types that mean "nothing to do yet" (an upload
    that is not configured): they are logged at WARNING without a traceback.
    Anything else is logged with one and the loop keeps going - a sweep that
    dies on its first surprise is worse than one that retries next tick.

    **`enabled` is read every tick, not once at startup.** It used to gate
    `start()` alone, which made both directions of every switch restart-only:
    the loop ticked on regardless after a save turned it off, and a sweep that
    booted disabled had no thread to enable. Proven on the station 2026-09-22 -
    folder 14 was approved with exportAutoEnabled false in config.txt, in the
    settings singleton and on the toggle, and the sweep exported it 39 seconds
    later. The thread therefore always runs and idles; the tick is what the
    switch gates.
    """

    def __init__(
        self,
        name: str,
        *,
        tick: Callable[[], object],
        interval: Callable[[], float],
        enabled: Callable[[], bool] = lambda: True,
        expected: tuple[type[BaseException], ...] = (),
    ) -> None:
        self.name = name
        self._tick = tick
        self._interval = interval
        self._enabled = enabled
        self._expected = expected
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._wake = threading.Event()

    def enabled(self) -> bool:
        return bool(self._enabled())

    def _thread_alive(self) -> bool:
        """Whether the loop exists. The start guard, not the console's answer."""
        thread = self._thread
        return bool(thread and thread.is_alive())

    def is_running(self) -> bool:
        """Whether the sweep is actually working - alive AND switched on.

        Kept apart from `_thread_alive` because the thread now outlives the
        switch: the console asks this to show whether the scanner is doing
        anything, and a thread idling on a disabled switch is not.
        """
        return self._thread_alive() and self.enabled()

    def kick(self) -> None:
        """Runs the next tick now instead of after the interval."""
        self._wake.set()

    def _schema_ok(self) -> bool:
        """Skips the tick while the DB is older than this program (gate logs once
        per 10 min). Late import: schema_check imports the engine."""
        from app.services import schema_check

        return schema_check.gate_ok(self.name)

    def _run(self) -> None:
        while not self._stop_event.is_set():
            if self.enabled() and self._schema_ok():
                try:
                    self._tick()
                except self._expected as error:
                    logger.warning("%s skipped: %s", self.name, error)
                except Exception:
                    logger.exception("%s failed", self.name)
            self._wake.wait(self._interval())
            self._wake.clear()

    def start(self) -> None:
        if self._thread_alive():
            return
        self._stop_event.clear()
        self._wake.clear()
        self._thread = threading.Thread(target=self._run, name=self.name, daemon=True)
        self._thread.start()
        logger.info("%s started", self.name)

    def stop(self) -> None:
        self._stop_event.set()
        self._wake.set()
        thread = self._thread
        self._thread = None
        if thread and thread.is_alive():
            thread.join(timeout=5)


__all__ = ["PeriodicSweep"]
