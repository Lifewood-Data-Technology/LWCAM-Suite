"""Durable JSON state file for the upload sweep. Ported unchanged from QC's
`app/services/ledger.py` (which shared this module with the export worker's
`active.json`/`failures.json`) - the on-disk format is unchanged, so a ledger
carried over from a QC install reads back exactly as it did there.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import time
import uuid
from pathlib import Path
from typing import Any

from .paths import fs_path

logger = logging.getLogger(__name__)


def atomic_json(path: Path, payload: Any, *, keep_backup: bool = False) -> None:
    """Writes JSON so that `path` is never half-written AND survives a power cut.

    fsync BEFORE the rename. os.replace is atomic, so a torn file can never
    appear at `path` - but atomic is not durable: without the fsync a power
    cut can land the rename with the CONTENTS still in the page cache, giving
    an empty or truncated file.

    `keep_backup` first copies the current file, if it still parses, to
    `<name>.bak` - the fallback JsonLedger.load_strict reads when the main
    file is torn or emptied by something outside this process.
    """
    fs_path(path.parent).mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        data = json.dumps(payload, ensure_ascii=False, indent=2, default=str)
        with fs_path(temporary).open("w", encoding="utf-8") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        if keep_backup and _parses(path):
            try:
                shutil.copyfile(fs_path(path), fs_path(_backup_path(path)))
            except OSError:
                pass  # a locked .bak must not stop the real write
        # A reader (the console's status poll) or a virus scanner holding the
        # file open makes the replace fail on Windows for a moment.
        for attempt in range(5):
            try:
                os.replace(fs_path(temporary), fs_path(path))
                break
            except PermissionError:
                if attempt == 4:
                    raise
                time.sleep(0.2)
    finally:
        fs_path(temporary).unlink(missing_ok=True)


def _backup_path(path: Path) -> Path:
    return path.with_name(path.name + ".bak")


def _parses(path: Path) -> bool:
    try:
        return isinstance(json.loads(fs_path(path).read_text(encoding="utf-8")), dict)
    except (OSError, ValueError):
        return False


class LedgerCorrupt(Exception):
    """The ledger and its .bak are both unreadable. Scanning on would treat
    every package as new and upload the whole archive again."""


class LedgerUnavailable(Exception):
    """The ledger could not be opened right now (locked); try next scan."""


class JsonLedger:
    """A JSON object on disk, keyed by id, read whole and written atomically.

    `load` never raises: a missing or corrupt ledger reads as empty, because
    every caller would rather carry on with nothing than fail the upload that
    was about to record its outcome. `save` raises by default; pass
    `best_effort=True` where a failed write must not undo a success that
    already happened elsewhere.
    """

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict[str, Any]:
        try:
            data = json.loads(fs_path(self.path).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def load_strict(self) -> dict[str, Any]:
        """Like load, but never mistakes damage for "nothing uploaded yet".

        Missing file = {} (first run). Locked (OSError) is retried a few times
        and then raises LedgerUnavailable. A file that does not parse falls
        back to `<name>.bak`; if that is bad too the main file is copied to
        `<name>.bad-<time>` for the operator and LedgerCorrupt is raised - the
        main file itself stays put, so the refusal survives a restart.
        """
        text = None
        for attempt in range(3):
            try:
                text = fs_path(self.path).read_text(encoding="utf-8")
                break
            except FileNotFoundError:
                return self._from_backup_or_empty(None)
            except OSError as error:
                if attempt == 2:
                    raise LedgerUnavailable(f"could not read {self.path}: {error}") from error
                time.sleep(0.3)
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                return data
        except ValueError:
            pass
        return self._from_backup_or_empty(text)

    def _from_backup_or_empty(self, bad_text: str | None) -> dict[str, Any]:
        backup = _backup_path(self.path)
        if _parses(backup):
            logger.warning("%s was unreadable; using %s", self.path, backup)
            return json.loads(fs_path(backup).read_text(encoding="utf-8"))
        if bad_text is None and not fs_path(backup).exists():
            return {}  # a first run: nothing there yet
        if bad_text is not None:
            existing = list(fs_path(self.path.parent).glob(self.path.name + ".bad-*"))
            if not existing:
                try:
                    fs_path(self.path.with_name(f"{self.path.name}.bad-{int(time.time())}")).write_text(
                        bad_text, encoding="utf-8"
                    )
                except OSError:
                    pass
        raise LedgerCorrupt(
            f"The upload ledger {self.path} and its backup are both unreadable, so nothing "
            "will be uploaded until it is repaired (a copy of the bad file is kept beside it "
            "as .bad-*). Delete the ledger and its .bak to start again from an empty one - "
            "every package still in the watch folder would then be uploaded again."
        )

    def entries(self) -> list[dict[str, Any]]:
        """The dict-valued rows, in file order."""
        return [item for item in self.load().values() if isinstance(item, dict)]

    def save(self, data: dict[str, Any], *, best_effort: bool = False) -> None:
        try:
            atomic_json(self.path, data, keep_backup=True)
        except OSError:
            if not best_effort:
                raise
            logger.exception("Could not write %s", self.path)


__all__ = ["JsonLedger", "LedgerCorrupt", "LedgerUnavailable", "atomic_json"]
