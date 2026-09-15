"""Durable JSON state files for the background workers.

Three files share this shape: the export's `active.json` (one run) and
`failures.json` (keyed by folder), and the upload's `uploads.json` (keyed by
package). They used to be written and read by three copies of the same code.
The on-disk format is unchanged - a station upgraded onto this module reads the
files it already has.
"""

from __future__ import annotations

import json
import logging
import os
import uuid
from pathlib import Path
from typing import Any

from app.core.paths import fs_path

logger = logging.getLogger(__name__)


def atomic_json(path: Path, payload: Any) -> None:
    """Writes JSON so that `path` is never half-written AND survives a power cut.

    fsync BEFORE the rename, the same way the export's publish does. os.replace
    is atomic, so a torn file can never appear at `path` - but atomic is not
    durable: without the fsync a power cut can land the rename with the
    CONTENTS still in the page cache, giving an empty or truncated file.
    """
    fs_path(path.parent).mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        data = json.dumps(payload, ensure_ascii=False, indent=2, default=str)
        with fs_path(temporary).open("w", encoding="utf-8") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(fs_path(temporary), fs_path(path))
    finally:
        fs_path(temporary).unlink(missing_ok=True)


class JsonLedger:
    """A JSON object on disk, keyed by id, read whole and written atomically.

    `load` never raises: a missing or corrupt ledger reads as empty, because
    every caller would rather carry on with nothing than fail the operation
    that was about to record its outcome. `save` raises by default; pass
    `best_effort=True` where a failed write must not undo a success that
    already happened elsewhere (the export failure ledger).
    """

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict[str, Any]:
        try:
            data = json.loads(fs_path(self.path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def entries(self) -> list[dict[str, Any]]:
        """The dict-valued rows, in file order."""
        return [item for item in self.load().values() if isinstance(item, dict)]

    def save(self, data: dict[str, Any], *, best_effort: bool = False) -> None:
        try:
            atomic_json(self.path, data)
        except OSError:
            if not best_effort:
                raise
            logger.exception("Could not write %s", self.path)


__all__ = ["JsonLedger", "atomic_json"]
