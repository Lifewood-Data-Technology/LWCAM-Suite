"""Network-folder logins shared by every LWCam service on this PC.

The QC server, LWIP and Upload run as SYSTEM tasks. SYSTEM reaches another
PC's share as this PC's computer account, which a PC outside a domain does not
accept ("Access is denied", WinError 5). So each service signs in to the other
PC itself, with a saved account, the way `net use \\\\PC\\IPC$ /user:...` does.

One list per PC, not per service: every SYSTEM service on a PC shares one
Windows logon session, and Windows allows that session ONE account per remote
PC (a second one is error 1219). A single shared list makes a clash
impossible and means a login typed into any console serves all three.

The list lives in %ProgramData%\\LWCAM\\network-logins\\logins.json, in a folder
restricted to SYSTEM and Administrators; passwords are also DPAPI-encrypted
(machine scope). A password is never returned, logged or echoed.

Byte-identical copies live in LWIP (deskew_crop_tool), LWCam Upload
(lwcam_upload) and the QC Platform (app/core). Edit all three together - the
QC suite's test_netlogin_copies_match fails when they drift. Stdlib only.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import subprocess
import threading
from pathlib import Path
from typing import Iterable

LOGGER = logging.getLogger("lwcam.netlogin")

STORE_ENV = "LWCAM_NETWORK_LOGINS"
KEEPER_INTERVAL_SECONDS = 120.0
CONNECT_TIMEOUT_SECONDS = 30.0

# A PC name or address: what may follow the two backslashes of a UNC path.
_HOST_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.\-_]{0,254}$")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")

_LOCK = threading.Lock()
_stop = threading.Event()
_last_errors: dict[str, str | None] = {}


# --------------------------------------------------------------------------
# Paths and hosts
# --------------------------------------------------------------------------


def store_path() -> Path:
    override = os.environ.get(STORE_ENV)
    if override:
        return Path(override)
    program_data = os.environ.get("ProgramData") or r"C:\ProgramData"
    return Path(program_data, "LWCAM", "network-logins", "logins.json")


def host_of(path: str | os.PathLike | None) -> str | None:
    """`FILE-PC` for `\\\\FILE-PC\\share\\x` (or its `\\\\?\\UNC\\` form); None
    for a local path."""
    text = str(path or "").strip()
    if text.upper().startswith("\\\\?\\UNC\\"):
        text = "\\\\" + text[8:]
    match = re.match(r"^[\\/]{2}([^\\/?]+)", text)
    return match.group(1) if match else None


def normalise_host(value: str) -> str:
    """Accepts `FILE-PC`, `\\\\FILE-PC` or a whole `\\\\FILE-PC\\share\\...` path."""
    # However many slashes lead it - "\FILE-PC" is an easy slip to type.
    text = (value or "").strip().lstrip("\\/")
    if text.upper().startswith("?\\UNC\\"):
        text = text[6:]
    host = re.split(r"[\\/]", text, maxsplit=1)[0]
    if not host or not _HOST_RE.match(host):
        raise ValueError("Enter the other PC's name or address, e.g. FILE-PC or 192.168.0.120.")
    return host


# --------------------------------------------------------------------------
# The store
# --------------------------------------------------------------------------


def _read_store() -> dict[str, dict]:
    try:
        raw = json.loads(store_path().read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as exc:
        LOGGER.warning("Network logins could not be read: %s", exc)
        return {}
    logins = raw.get("logins") if isinstance(raw, dict) else None
    if not isinstance(logins, list):
        return {}
    result = {}
    for entry in logins:
        if isinstance(entry, dict) and entry.get("host") and entry.get("username"):
            result[str(entry["host"]).lower()] = entry
    return result


def _restrict_folder(folder: Path) -> None:
    """SYSTEM + Administrators only, by SID so a non-English Windows works.
    Raises rather than let a password land in a folder anyone can read."""
    if os.name != "nt" or os.environ.get(STORE_ENV):
        return
    result = subprocess.run(
        [
            "icacls", str(folder), "/inheritance:r",
            "/grant:r", "*S-1-5-18:(OI)(CI)F", "/grant:r", "*S-1-5-32-544:(OI)(CI)F",
        ],
        capture_output=True, text=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    if result.returncode != 0:
        raise OSError(f"Could not restrict {folder}: {(result.stdout or result.stderr).strip()}")


def _write_store(logins: dict[str, dict]) -> None:
    path = store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    _restrict_folder(path.parent)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_text(
        json.dumps({"logins": sorted(logins.values(), key=lambda e: e["host"].lower())}, indent=2),
        encoding="utf-8",
    )
    os.replace(temp, path)


def list_logins(paths: Iterable[str] = ()) -> list[dict]:
    """Saved logins plus any PC the given folders point at, WITHOUT touching
    the network - fast enough for a page load. Never includes a password."""
    saved = _read_store()
    in_use: dict[str, str] = {}
    for path in paths:
        host = host_of(path)
        if host:
            in_use.setdefault(host.lower(), host)
    rows = []
    for key in sorted(set(saved) | set(in_use)):
        entry = saved.get(key)
        rows.append({
            "host": entry["host"] if entry else in_use[key],
            "username": entry["username"] if entry else "",
            "saved": entry is not None,
            "usedByThisService": key in in_use,
        })
    return rows


def save_login(host: str, username: str, password: str | None) -> str | None:
    """Saves (or replaces) the login for one PC and connects with it at once.
    A blank password keeps the saved one. Returns why the connection failed,
    or None - the login is saved either way, since the PC may simply be off."""
    host = normalise_host(host)
    username = (username or "").strip()
    if not username or _CONTROL_RE.search(username):
        raise ValueError("Enter the username, e.g. FILE-PC\\lwcam-share.")
    if password and _CONTROL_RE.search(password):
        raise ValueError("The password contains a character that cannot be saved.")
    with _LOCK:
        logins = _read_store()
        existing = logins.get(host.lower())
        if existing:
            host = existing["host"]  # keep the name as first saved, whatever the case typed now
        if password:
            secret = base64.b64encode(_protect(password.encode("utf-8"))).decode("ascii")
        elif existing and existing.get("password"):
            secret = existing["password"]
        else:
            raise ValueError("Enter the password.")
        logins[host.lower()] = {"host": host, "username": username, "password": secret}
        _write_store(logins)
    # New credentials: drop a connection made with the old ones first, or
    # Windows refuses the new login (1219).
    _cancel(host)
    return connect(host)


def delete_login(host: str) -> None:
    host = normalise_host(host)
    with _LOCK:
        logins = _read_store()
        if logins.pop(host.lower(), None) is not None:
            _write_store(logins)
    _cancel(host)
    _last_errors.pop(host.lower(), None)


# --------------------------------------------------------------------------
# Connecting
# --------------------------------------------------------------------------


def connect(host: str) -> str | None:
    """Signs in to `host` with its saved login. None on success (or when no
    login is saved - nothing to do), else a plain-English reason."""
    entry = _read_store().get(host.lower())
    if entry is None:
        return None
    try:
        password = _unprotect(base64.b64decode(entry["password"])).decode("utf-8")
    except Exception:
        error = "The saved password could not be read on this PC. Enter it again."
    else:
        code = _add_connection(host, entry["username"], password)
        if code == 1219:
            _cancel(host)
            code = _add_connection(host, entry["username"], password)
        error = None if code == 0 else describe_error(code, host)
    previous = _last_errors.get(host.lower(), "unset")
    if error != previous:
        if error:
            LOGGER.warning("Network login to %s failed: %s", host, error)
        elif previous != "unset":
            LOGGER.info("Network login to %s works again.", host)
    _last_errors[host.lower()] = error
    return error


_inflight: dict[str, threading.Thread] = {}


def _bounded(key: str, fn, timeout: float, on_timeout):
    """Runs fn() on its own daemon thread and waits at most `timeout`. Returns
    (finished, result). One stuck call per key at a time: while it hangs, later
    calls do not pile up more threads, they report the timeout at once."""
    box: list = []
    with _LOCK:
        old = _inflight.get(key)
        if old is not None and old.is_alive():
            return False, on_timeout
        thread = threading.Thread(target=lambda: box.append(fn()), daemon=True, name=f"lwcam-netlogin-{key}")
        _inflight[key] = thread
    thread.start()
    thread.join(timeout)
    return (True, box[0]) if box else (False, on_timeout)


def connect_bounded(host: str, timeout: float = CONNECT_TIMEOUT_SECONDS) -> str | None:
    """`connect`, but a dead or slow PC gives a plain-English error after
    `timeout` instead of holding the caller."""
    message = f"{host} did not answer within {int(timeout)} seconds. Check it is on and reachable."
    done, result = _bounded("connect:" + host.lower(), lambda: connect(host), timeout, message)
    if not done:
        _last_errors[host.lower()] = message
    return result


def connect_for_path(path: str | os.PathLike | None) -> str | None:
    host = host_of(path)
    return connect(host) if host else None


def connect_all(timeout: float = CONNECT_TIMEOUT_SECONDS) -> None:
    """Every saved login, each on its own thread: one dead PC does not delay
    the others (total wait is about `timeout`, not the sum)."""
    threads = [
        threading.Thread(target=connect_bounded, args=(entry["host"], timeout), daemon=True)
        for entry in list(_read_store().values())
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout + 5)


def check_folder(path: str) -> str | None:
    """None when this process can list `path`, else why not."""
    try:
        with os.scandir(path) as entries:
            next(entries, None)
        return None
    except OSError as exc:
        code = getattr(exc, "winerror", None)
        host = host_of(path) or "the other PC"
        if code in (2, 3):
            return "This folder does not exist."
        if code in (5, 86, 1326) and not any(
            key == host.lower() for key in _read_store()
        ):
            # Nobody typed a password yet: it is this PC itself being refused.
            return f"{host} refused this PC. Add a login for {host} below."
        return describe_error(code, host) if code else str(exc)


def _check_folder_bounded(path: str, timeout: float = CONNECT_TIMEOUT_SECONDS) -> str | None:
    host = host_of(path) or "the other PC"
    message = f"{host} did not answer within {int(timeout)} seconds. Check it is on and reachable."
    return _bounded("folder:" + path.lower(), lambda: check_folder(path), timeout, message)[1]


def check_all(paths: Iterable[str]) -> list[dict]:
    """`list_logins` plus the network: signs in with each saved login and
    tries each of this service's folders on that PC. Slow when a PC is off."""
    paths = [p for p in paths if host_of(p)]
    rows = list_logins(paths)
    for row in rows:
        row["loginError"] = connect_bounded(row["host"]) if row["saved"] else None
        row["folders"] = [
            {"path": p, "error": _check_folder_bounded(p)}
            for p in paths if host_of(p).lower() == row["host"].lower()
        ]
    return rows


def console_request(action: str, body: dict | None, paths: Iterable[str]) -> tuple[int, dict]:
    """The console calls, for LWIP's and Upload's http.server consoles (QC's
    FastAPI routes call the functions above directly). The caller has already
    required a signed-in admin; `paths` are the service's configured folders."""
    body = body or {}
    try:
        if action == "list":
            return 200, {"logins": list_logins(paths)}
        if action == "check":
            return 200, {"logins": check_all(paths)}
        if action == "save":
            error = save_login(
                str(body.get("host") or ""), str(body.get("username") or ""),
                str(body.get("password") or "") or None,
            )
            return 200, {"error": error}
        if action == "remove":
            delete_login(str(body.get("host") or ""))
            return 200, {}
    except ValueError as exc:
        return 400, {"error": str(exc)}
    except OSError as exc:
        return 500, {"error": f"The login could not be saved: {exc}"}
    return 404, {"error": "Not found."}


def start_keeper(interval: float = KEEPER_INTERVAL_SECONDS) -> threading.Thread:
    """Signs in with every saved login now and every `interval` seconds, so
    the folders work after a reboot and come back after the other PC does."""
    def run() -> None:
        while True:
            try:
                connect_all()
            except Exception:
                LOGGER.exception("Network login keeper failed")
            _stop.wait(interval)

    thread = threading.Thread(target=run, name="lwcam-netlogin-keeper", daemon=True)
    thread.start()
    return thread


def describe_error(code: int | None, host: str) -> str:
    if code in (86, 1326):
        return f"{host} did not accept this username or password."
    if code == 5:
        return (f"{host} refused access. Save a network login for {host}, or give "
                "the saved account permission on the share and the folder.")
    if code == 1219:
        return (f"Windows is already connected to {host} with a different account, made by "
                "another program on this PC. Restart this PC, then test again.")
    if code in (51, 53, 64, 1231, 1232):
        return f"Cannot reach {host} on the network. Check it is on and the name is right."
    if code == 67:
        return f"{host} has no shared folder by that name."
    if code in (1327, 1330, 1331, 1385, 1907, 1909):
        return f"{host} refused the login: {_format_error(code)}"
    return f"{_format_error(code)} (Windows error {code})"


# --------------------------------------------------------------------------
# Windows calls (ctypes: mpr.dll for connections, crypt32.dll for DPAPI)
# --------------------------------------------------------------------------

_CONNECT_TEMPORARY = 0x4
_CRYPTPROTECT_UI_FORBIDDEN = 0x1
_CRYPTPROTECT_LOCAL_MACHINE = 0x4


def _format_error(code: int | None) -> str:
    if os.name == "nt" and code:
        import ctypes
        return ctypes.FormatError(code).strip()
    return f"error {code}"


def _add_connection(host: str, username: str | None, password: str | None) -> int:
    """WNetAddConnection2W on \\\\host\\IPC$: one SMB session to the PC, which
    every share on it then uses. Returns the Windows error code (0 = done)."""
    if os.name != "nt":
        return 50  # ERROR_NOT_SUPPORTED
    import ctypes
    from ctypes import wintypes

    class NetResource(ctypes.Structure):
        _fields_ = [
            ("dwScope", wintypes.DWORD), ("dwType", wintypes.DWORD),
            ("dwDisplayType", wintypes.DWORD), ("dwUsage", wintypes.DWORD),
            ("lpLocalName", wintypes.LPWSTR), ("lpRemoteName", wintypes.LPWSTR),
            ("lpComment", wintypes.LPWSTR), ("lpProvider", wintypes.LPWSTR),
        ]

    mpr = ctypes.WinDLL("mpr")
    add = mpr.WNetAddConnection2W
    add.argtypes = [ctypes.POINTER(NetResource), wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.DWORD]
    add.restype = wintypes.DWORD
    resource = NetResource(lpRemoteName=f"\\\\{host}\\IPC$")
    return int(add(ctypes.byref(resource), password, username, _CONNECT_TEMPORARY))


def _cancel(host: str) -> None:
    if os.name != "nt":
        return
    import ctypes
    from ctypes import wintypes

    cancel = ctypes.WinDLL("mpr").WNetCancelConnection2W
    cancel.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.BOOL]
    cancel.restype = wintypes.DWORD
    cancel(f"\\\\{host}\\IPC$", 0, True)


def _dpapi(data: bytes, protect: bool) -> bytes:
    import ctypes
    from ctypes import wintypes

    class Blob(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]

    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32")
    func = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    func.argtypes = [
        ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob),
    ]
    func.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    buffer = ctypes.create_string_buffer(data, len(data))
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_char)))
    result = Blob()
    flags = _CRYPTPROTECT_UI_FORBIDDEN | (_CRYPTPROTECT_LOCAL_MACHINE if protect else 0)
    if not func(ctypes.byref(source), None, None, None, None, flags, ctypes.byref(result)):
        raise OSError(ctypes.get_last_error(), "DPAPI failed")
    try:
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        kernel32.LocalFree(result.pbData)


def _protect(data: bytes) -> bytes:
    # ponytail: machine-scope DPAPI - any process on this PC can decrypt, so
    # the folder ACL is the real guard; this stops a copied file being read
    # anywhere else. A per-account key would need the services to share one.
    return _dpapi(data, True) if os.name == "nt" else data


def _unprotect(data: bytes) -> bytes:
    return _dpapi(data, False) if os.name == "nt" else data
