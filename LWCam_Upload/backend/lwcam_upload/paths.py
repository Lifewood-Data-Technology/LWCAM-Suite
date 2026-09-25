"""Windows long-path handling. Ported from QC's `app/core/paths.py`, trimmed
to the two functions this app needs - the LWCAM/LWIP host-container path
remapping stays behind in QC, which is the only place that reads `folder_path`
values LWCAM wrote; this app only ever reads the folders its own config names.
"""

from __future__ import annotations

import os
from pathlib import Path

# Literal "\\?\", the Windows extended-length path prefix. This app's own
# packages can sit several directories below a watch_root that is itself a
# deep UNC share, so the same 260-char MAX_PATH failure LWIP and QC guard
# against applies here too.
_EXTENDED_PREFIX = "\\\\?\\"
_UNC_EXTENDED_PREFIX = "\\\\?\\UNC\\"


def fs_path(path: Path | str) -> Path:
    r"""`path` in the form Windows accepts past its 260-character MAX_PATH.

    Applied ONLY at the system-call boundary (open/exists/scandir/mkdir/
    shutil/zipfile/...), never to a path that gets stored: the prefixed form
    must not reach the ledger, the summary database, a console response, or a
    zip member name. Use `display_path` to strip it back off first.

    Idempotent, and a no-op off Windows.
    """
    if os.name != "nt":
        return Path(path)
    text = os.path.abspath(str(path))
    if text.startswith(_EXTENDED_PREFIX):
        return Path(text)
    if text.startswith("\\\\"):
        # UNC: \\server\share -> \\?\UNC\server\share
        return Path(_EXTENDED_PREFIX + "UNC" + text[1:])
    return Path(_EXTENDED_PREFIX + text)


def display_path(path: Path | str) -> str:
    """Reverse of `fs_path`: strip the extended-length prefix for anything
    shown to a user or written to the ledger, the summary database, a console
    response, or a zip member name. A path with no prefix passes through
    unchanged."""
    text = str(path)
    if text.startswith(_UNC_EXTENDED_PREFIX):
        return "\\\\" + text[len(_UNC_EXTENDED_PREFIX):]
    if text.startswith(_EXTENDED_PREFIX):
        return text[len(_EXTENDED_PREFIX):]
    return text


__all__ = ["fs_path", "display_path"]
