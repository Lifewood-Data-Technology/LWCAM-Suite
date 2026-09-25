"""LWCam Upload: a standalone sweep that sends QC's published export packages to S3.

Split out of the QC server (2026-09-25) so upload can run on its own PC with
its own installer, independent of whether QC or LWIP are even installed there.
Behaviour carried over unchanged: size-verified PUTs, a JSON ledger with
back-off retries, an Upload_Summary.db3 row per package, then a move into the
"Uploaded" folder. See engine.py for the sweep itself.

This module holds the one piece every other module needs and that must not
import any of them back: the console's "log line" - a tagged, timestamped
message kept in an in-memory ring buffer (for the console's live view) and
mirrored to the rotating log file. Both engine.py and console.py call
`log(tag, message)`; only console.py calls `configure_logging` (once, at
startup, when it knows the config's log_file).
"""

from __future__ import annotations

import itertools
import logging
import threading
from collections import deque
from datetime import datetime
from pathlib import Path

__all__ = [
    "configure_logging",
    "log",
    "log_lines_after",
    "log_last_seq",
]

LOGGER_NAME = "lwcam_upload"
_logger = logging.getLogger(LOGGER_NAME)
_logger.setLevel(logging.INFO)
_logger.propagate = False

# Last 2000 lines, each with an increasing seq number, so the console's
# GET /api/log?after=<seq> can page without re-reading the log file.
_RING_MAXLEN = 2000
_ring: "deque[dict]" = deque(maxlen=_RING_MAXLEN)
_ring_lock = threading.Lock()
_seq_counter = itertools.count(1)


class TaggedFormatter(logging.Formatter):
    """`YYYY-MM-DD HH:MM:SS [TAG] message` - the one log line shape, on screen
    and in the file. The tag comes from `log()`'s `extra`, defaulting to
    SYSTEM for anything logged some other way (a library exception, say)."""

    def format(self, record: logging.LogRecord) -> str:
        tag = getattr(record, "tag", "SYSTEM")
        timestamp = datetime.fromtimestamp(record.created).strftime("%Y-%m-%d %H:%M:%S")
        return f"{timestamp} [{tag}] {record.getMessage()}"


class _RingBufferHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        text = self.format(record)
        with _ring_lock:
            _ring.append({"seq": next(_seq_counter), "text": text})


def log(tag: str, message: str) -> None:
    """The one way every module writes a console log line, e.g. `log("UPLOAD", "...")`.

    Never pass a secret (s3_secret_key, db_password) or a session cookie here -
    it is kept in memory and written to disk in the plain.
    """
    _logger.info(message, extra={"tag": tag})


def log_lines_after(after: int) -> list[dict]:
    """Buffered lines with seq > `after` (all of them when `after` is 0)."""
    with _ring_lock:
        return [line for line in _ring if line["seq"] > after]


def log_last_seq() -> int:
    with _ring_lock:
        return _ring[-1]["seq"] if _ring else 0


def configure_logging(log_file: Path) -> None:
    """Attaches the ring buffer and a rotating file handler (10 MB x 5) on
    `log_file`. Idempotent - the first call wins for the lifetime of the
    process (the console calls it once; a test suite that exercises `run()`
    more than once, or calls this directly, must not end up with the same
    line duplicated once per call).
    """
    if _logger.handlers:
        return

    from logging.handlers import RotatingFileHandler

    from .paths import fs_path

    formatter = TaggedFormatter()

    ring_handler = _RingBufferHandler()
    ring_handler.setFormatter(formatter)
    _logger.addHandler(ring_handler)

    fs_path(log_file).parent.mkdir(parents=True, exist_ok=True)
    file_handler = RotatingFileHandler(
        fs_path(log_file), maxBytes=10 * 1024 * 1024, backupCount=5, encoding="utf-8"
    )
    file_handler.setFormatter(formatter)
    _logger.addHandler(file_handler)
