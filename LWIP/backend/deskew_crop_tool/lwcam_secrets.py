r"""Stored passwords and secret keys in LWCam's service configuration files.

A secret is kept as `dpapi:<base64>` instead of plain text. The blob is made by
Windows DPAPI in MACHINE scope with a fixed entropy string, so:

- the installers (run by an administrator) and the services (run as SYSTEM)
  can both read what the other wrote;
- a config file copied to another PC is useless there (it raises SecretError).

What this does NOT do: it does not protect against an administrator (or any
process running as SYSTEM) on the SAME PC - they can decrypt it exactly as the
services do. It keeps the secret out of backups, screenshots, support e-mails
and casual reads of the file, and ties it to the PC. Nothing more.

A value without the prefix is passed through unchanged (older files, hand
edits); the services rewrite such a file protected when they start.

ONE source file, copied byte-for-byte to every module that needs it (a test
checks all copies are identical). Standard library only. Edit all copies or
none.

Command line (there is deliberately no decrypt command - it would be a
one-line secret dump; Python callers import `unprotect`):

    python lwcam_secrets.py protect-file <path> --keys k1,k2,...

`.json` files: top-level keys. Anything else: `key = value` lines. Comments,
order, line endings and the absence of a BOM are kept; already-protected
values are left alone; the write is atomic; values are never printed.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import json
import os
import re
import sys
import uuid
from ctypes import wintypes
from pathlib import Path

PREFIX = "dpapi:"
_ENTROPY = b"LWCam config v1"
_UI_FORBIDDEN = 0x1
_LOCAL_MACHINE = 0x4


class SecretError(ValueError):
    """A stored secret cannot be read on this PC."""


def is_protected(value: object) -> bool:
    return isinstance(value, str) and value.startswith(PREFIX)


class _Blob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


def _blob(data: bytes) -> tuple[_Blob, object]:
    buffer = ctypes.create_string_buffer(data, len(data))
    return _Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char))), buffer


def _dpapi(data: bytes, encrypt: bool) -> bytes:
    if sys.platform != "win32":
        raise OSError("DPAPI is available on Windows only")
    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    source, source_keep = _blob(data)
    entropy, entropy_keep = _blob(_ENTROPY)
    out = _Blob()
    if encrypt:
        ok = crypt32.CryptProtectData(
            ctypes.byref(source), None, ctypes.byref(entropy), None, None,
            _UI_FORBIDDEN | _LOCAL_MACHINE, ctypes.byref(out),
        )
    else:
        ok = crypt32.CryptUnprotectData(
            ctypes.byref(source), None, ctypes.byref(entropy), None, None,
            _UI_FORBIDDEN, ctypes.byref(out),
        )
    del source_keep, entropy_keep
    if not ok:
        raise OSError(ctypes.WinError().strerror or "DPAPI call failed")
    try:
        return ctypes.string_at(out.pbData, out.cbData)
    finally:
        kernel32.LocalFree(out.pbData)


def protect(text: str) -> str:
    """`dpapi:<base64>`. Empty stays empty; an already-protected value is unchanged."""
    if not text or is_protected(text):
        return text
    return PREFIX + base64.b64encode(_dpapi(text.encode("utf-8"), True)).decode("ascii")


def unprotect(value: str, key: str | None = None) -> str:
    """The plain text. A value without the prefix is returned as it is. A
    protected value that cannot be decrypted here raises SecretError."""
    if not is_protected(value):
        return value
    name = f"The stored value of {key}" if key else "A stored secret"
    try:
        return _dpapi(base64.b64decode(value[len(PREFIX):], validate=True), False).decode("utf-8")
    except Exception as error:  # bad base64, wrong PC, damaged blob, not Windows
        raise SecretError(
            f"{name} cannot be decrypted on this PC (it was protected on another PC, "
            "or is damaged). Enter it again in the console, or re-run the installer."
        ) from error


_LINE = re.compile(r"[^\n]*\n|[^\n]+")
_ASSIGNMENT = re.compile(r"^(\s*)([^\s=#][^=]*?)(\s*=\s*)(.*?)(\s*)$", re.S)


def _write_atomic(path: Path, data: bytes) -> None:
    temp = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")  # same folder: same ACL
    try:
        with temp.open("wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def protect_file(path: Path | str, keys) -> bool:
    """Protect `keys` in place. True when the file changed."""
    path = Path(path)
    wanted = set(keys)
    original = path.read_bytes().decode("utf-8")  # utf-8, not -sig: a BOM stays as it is
    if path.suffix.lower() == ".json":
        document = json.loads(original)
        if not isinstance(document, dict):
            raise ValueError("configuration root must be a JSON object")
        changed = False
        for key in wanted & document.keys():
            value = document[key]
            if isinstance(value, str) and value and not is_protected(value):
                document[key] = protect(value)
                changed = True
        if not changed:
            return False
        newline = "\r\n" if "\r\n" in original else "\n"
        text = json.dumps(document, indent=2, ensure_ascii=False)
        if original.endswith("\n"):
            text += "\n"
        result = text.replace("\n", newline)
    else:
        parts = []
        changed = False
        for line in _LINE.findall(original):
            match = _ASSIGNMENT.match(line) if not line.lstrip().startswith("#") else None
            if match and match.group(2) in wanted and match.group(4) and not is_protected(match.group(4)):
                line = (
                    match.group(1) + match.group(2) + match.group(3)
                    + protect(match.group(4)) + match.group(5)
                )
                changed = True
            parts.append(line)
        if not changed:
            return False
        result = "".join(parts)
    _write_atomic(path, result.encode("utf-8"))
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Protect stored secrets in a config file.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("protect-file")
    command.add_argument("path")
    command.add_argument("--keys", required=True, help="comma-separated key names")
    args = parser.parse_args(argv)
    keys = [key.strip() for key in args.keys.split(",") if key.strip()]
    try:
        changed = protect_file(args.path, keys)
    except Exception as error:  # never the values: report the kind of failure only
        print(f"protect-file failed: {type(error).__name__}", file=sys.stderr)
        return 1
    print("protected" if changed else "nothing to protect")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
