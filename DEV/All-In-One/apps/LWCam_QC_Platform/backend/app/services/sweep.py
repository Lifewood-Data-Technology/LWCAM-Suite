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
    """Runs `tick` every `interval()` seconds on a daemon thread.

    `expected` names exception types that mean "nothing to do yet" (an upload
    that is not configured): they are logged at WARNING without a traceback.
    Anything else is logged with one and the loop keeps going - a sweep that
    dies on its first surprise is worse than one that retries next tick.
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

    def is_running(self) -> bool:
        thread = self._thread
        return bool(thread and thread.is_alive())

    def kick(self) -> None:
        """Runs the next tick now instead of after the interval."""
        self._wake.set()

    def _run(self) -> None:
        while not self._stop_event.is_set():
            try:
                self._tick()
            except self._expected as error:
                logger.warning("%s skipped: %s", self.name, error)
            except Exception:
                logger.exception("%s failed", self.name)
            self._wake.wait(self._interval())
            self._wake.clear()

    def start(self) -> None:
        if not self.enabled() or self.is_running():
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
