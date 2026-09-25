r"""The QC server's own settings file.

The file is `config.txt`, beside the `backend/` folder at the QC platform root,
in plain `key = value` lines. Two deliberate choices there:

- **Plain text, not JSON.** This is the file a station technician opens in
  Notepad when the console is not reachable. A missing comma in JSON is a dead
  server; a mistyped line here is one ignored setting. It can also carry
  comments explaining what each path is for, which JSON cannot.
- **At the platform root, not under %LOCALAPPDATA%.** It sits next to the thing
  it configures, so "where are the QC paths set" has an answer you can see in
  Explorer.

ONE file, one writer at a time. The console rewrites it whole on save, so a
hand edit made while the engine is running is replaced by the next save from
the console - the values survive because they are read back first, but comments
a person added by hand do not. That is the cost of letting both a UI and an
editor own one file, and it is the right trade here: the alternative was two
files disagreeing about the same setting, which is the problem this whole
change set exists to remove.
"""

from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Any

from pydantic import SecretStr

# The `Settings` field each file key maps onto. Operator-facing names on the
# left, internal field names on the right. An explicit table - rather than
# accepting whatever is on disk - is what keeps this file from growing into a
# settings dump with no list of what it may touch. It is also the whole list:
# since the QC server stopped reading LWCam Admin's node config, anything not
# here is a code default. The old captureImageHostPath/ContainerPath pair is
# deliberately absent; qcInputRoot replaces it.
SETTINGS_BY_KEY: dict[str, str] = {
    "dbHost": "db_host",
    "dbPort": "db_port",
    "dbName": "db_name",
    "dbUser": "db_user",
    "dbPassword": "db_password",
    "dbUseSsl": "db_use_ssl",
    "jwtSecret": "jwt_secret",
    "bindHost": "bind_host",
    "port": "port",
    "qcInputRoot": "qc_images_root",
    "exportWorkRoot": "export_temp_dir",
    "qcOutputRoot": "export_output_dir",
    "exportZipOutput": "export_zip_output",
    "exportTiffOutput": "export_tiff_output",
    "luminanceEnabled": "luminance_enabled",
    "previewCacheMaxMb": "preview_cache_max_mb",
    "exportAutoEnabled": "export_auto_enabled",
    "aiReviewEnabled": "ai_review_enabled",
    "aiPreanalysisEnabled": "ai_preanalysis_enabled",
    "openrouterApiKey": "openrouter_api_key",
    "openrouterExtractModel": "openrouter_extract_model",
    "openrouterCompareModel": "openrouter_compare_model",
    "exportWorkerCount": "export_worker_count",
    "jwtExpireMinutes": "jwt_expire_minutes",
    "exportTempRetentionHours": "export_temp_retention_hours",
}
KEY_BY_SETTING = {field: key for key, field in SETTINGS_BY_KEY.items()}
# Until 2026-09-24 the images folder was `qcImagesRoot` and `qcInputRoot` was
# the export work folder - the name every operator misread. Every writer of
# that layout (installer, console) wrote a qcImagesRoot line, so its presence
# marks an old file, read with the old meanings; the next save from the
# console rewrites it with the new keys.
LEGACY_SETTINGS_BY_KEY: dict[str, str] = {
    "qcImagesRoot": "qc_images_root",
    "qcInputRoot": "export_temp_dir",
}
SERVER_SETTINGS_KEYS = tuple(SETTINGS_BY_KEY.values())
# Every value is written as one `key = value` line, so anything the reader
# would take for a line break must never reach the file: a console value of
# "abc\njwtSecret = x" would otherwise plant a key of the sender's choosing.
# That is the C0 controls, DEL, and the three characters str.splitlines() also
# splits on (NEL, LINE SEPARATOR, PARAGRAPH SEPARATOR). Ordinary non-ASCII -
# an accented folder name, a Chinese path - is fine and must stay allowed.
CONTROL_CHARACTERS = re.compile("[\x00-\x1f\x7f\x85\u2028\u2029]")

BOOLEAN_SETTINGS = frozenset(
    {
        "db_use_ssl",
        "export_zip_output",
        "export_tiff_output",
        "luminance_enabled",
        "export_auto_enabled",
        "ai_review_enabled",
        "ai_preanalysis_enabled",
    }
)
INTEGER_SETTINGS = frozenset(
    {
        "db_port",
        "port",
        "preview_cache_max_mb",
        "export_worker_count",
        "jwt_expire_minutes",
        "export_temp_retention_hours",
    }
)

_TRUE = frozenset({"true", "yes", "on", "1"})
_FALSE = frozenset({"false", "no", "off", "0"})

_HEADER = """\
# LWCam QC server configuration
#
# Rewritten by the QC console whenever settings are saved, so comments you add
# below will not survive that - the values will. It holds the database password
# and the login secret: keep it readable by administrators only.
#
# Server (read at start - restart the server after changing these):
#   dbHost, dbPort, dbName, dbUser, dbPassword, dbUseSsl
#                     The PostgreSQL database. dbUseSsl true requires TLS.
#   jwtSecret         Signs login tokens. At least 32 random characters; the
#                     installer generates one. Changing it signs everyone out.
#   jwtExpireMinutes  How long a login lasts (default 480).
#   bindHost          127.0.0.1 = this PC only. 0.0.0.0 = the whole LAN.
#   port              Port the console is served on (default 8080).
#
# Review and export (the console's Admin > Settings page edits these live):
#   qcInputRoot       Where LWIP's output (2.Batches) is - the folders QC
#                     reviews. QC saves its edits beside the images, so it
#                     needs write access there. Leave empty on a single-PC
#                     station: the server then uses the path LWCAM recorded.
#                     On a split site set the share the images live on, e.g.
#                     \\\\capture-pc\\2.Batches - each folder's own date and
#                     name are kept, only the part in front is replaced.
#   exportWorkRoot    Temporary folder the export builds each package in,
#                     cleared after exportTempRetentionHours. Must be separate
#                     from qcInputRoot and qcOutputRoot. Keep it LOCAL: a
#                     share here moves every TIFF across the network twice.
#   qcOutputRoot      Where the finished package is published for ingest.
#   exportZipOutput   true = publish a .zip, false = publish a folder.
#   exportTiffOutput  true = lossless TIFF. false re-encodes edited pages as
#                     q100 4:4:4 JPEG and copies untouched ones byte for byte.
#                     Only turn this off where lossless delivery is not required.
#   exportAutoEnabled true = the server exports approved folders by itself.
#                     false leaves every PASS folder waiting for an admin to
#                     export it from the Exports screen; nothing else starts
#                     one. Off means packages stop being produced.
#   exportWorkerCount Export worker processes; 0 = sized from the CPU.
#   exportTempRetentionHours  How long export scratch is kept (default 24).
#   luminanceEnabled  Allows luminance correction in review. This bakes pixels
#                     rather than recording a deferred op; off by default.
#   previewCacheMaxMb Soft cap, in MB, on the rendered-preview cache on disk.
#
# Upload no longer runs here - it moved to the standalone LWCam Upload
# service (the LWCam_Upload folder), which watches qcOutputRoot on its own
# schedule and config. An old uploadEnabled/uploadS3*/uploadDoneRoot/
# uploadSummaryRoot line left over from before that move is simply ignored,
# and the next save from this console drops it.
#
# AI metadata review (OpenRouter):
#   aiReviewEnabled, aiPreanalysisEnabled, openrouterApiKey,
#   openrouterExtractModel, openrouterCompareModel
#
# A path may be local (C:\\...) or a UNC share (\\\\server\\share\\...), never a
# mapped drive letter (Z:\\...): the server runs as a Windows service, which
# cannot see drives a logged-in user mapped.
# A blank value means "use the default". A line this file does not recognise
# is ignored, not fatal; a true/false or number that is not one stops the
# server with a message naming the key.
"""


def config_path() -> Path:
    r"""Where the file lives.

    `LWCAM_QC_SERVER_CONFIG` wins when set, so a deployment can put it
    anywhere. Otherwise the QC platform root - this module is
    `<root>/backend/app/core/server_settings.py`, so three parents up from the
    `app` package is `<root>/backend`, and its parent is the root that holds
    `backend/`, `database/` and `config.txt` together.
    """
    override = os.environ.get("LWCAM_QC_SERVER_CONFIG")
    if override:
        return Path(override).expanduser()
    backend_dir = Path(__file__).resolve().parents[2]
    return backend_dir.parent / "config.txt"


def _coerce(field: str, raw: str) -> Any:
    if field in BOOLEAN_SETTINGS:
        lowered = raw.strip().lower()
        if lowered in _TRUE:
            return True
        if lowered in _FALSE:
            return False
        raise RuntimeError(
            f"LWCam QC configuration: {KEY_BY_SETTING[field]} must be true or false, not {raw!r}"
        )
    if field in INTEGER_SETTINGS:
        try:
            return int(raw.strip())
        except ValueError:
            raise RuntimeError(
                f"LWCam QC configuration: {KEY_BY_SETTING[field]} must be a whole number, not {raw!r}"
            ) from None
    return raw


def load_server_settings_overrides() -> dict[str, Any]:
    """Read `config.txt`.

    A missing file reads as {} - a fresh install that has never saved anything
    is the normal state, not an error. An unreadable one IS an error: silently
    ignoring it would serve stale settings with nothing to say why.

    An unrecognised key is skipped rather than rejected, so a file written by a
    newer or older build still loads. A recognised key with an unusable value
    (a boolean that is not a boolean) raises, because that is a typo the
    operator needs told about rather than quietly reverted to a default.
    """
    path = config_path()
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return {}
    except OSError as error:
        raise RuntimeError(f"LWCam QC configuration is unreadable: {path}") from error

    pairs: list[tuple[str, str]] = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, raw = stripped.partition("=")
        pairs.append((key.strip(), raw.strip()))

    keys = SETTINGS_BY_KEY
    if any(key == "qcImagesRoot" for key, _ in pairs):
        keys = {**SETTINGS_BY_KEY, **LEGACY_SETTINGS_BY_KEY}
    values: dict[str, Any] = {}
    for key, value in pairs:
        field = keys.get(key)
        if field is None or not value:
            continue
        values[field] = _coerce(field, value)
    return values


def write_server_settings(values: dict[str, Any]) -> None:
    """Rewrite `config.txt` from the console's edit.

    Whole-file, header included, so the result is always a readable document
    rather than an append-only log of edits. Values not being written keep
    whatever is already on disk, so a save from a console that knows about
    fewer keys than the file holds cannot silently drop the rest.

    Atomic the same way every other writer in this codebase is - temp file
    beside the target, then os.replace - so a crash mid-write leaves the old
    file intact rather than a truncated one the engine would refuse to start
    on.
    """
    path = config_path()
    merged = {**load_server_settings_overrides(), **{
        field: value for field, value in values.items() if field in SERVER_SETTINGS_KEYS
    }}

    lines = [_HEADER]
    for key, field in SETTINGS_BY_KEY.items():
        if field not in merged:
            continue
        value = merged[field]
        if isinstance(value, SecretStr):
            value = value.get_secret_value()
        rendered = ("true" if value else "false") if field in BOOLEAN_SETTINGS else str(value)
        if CONTROL_CHARACTERS.search(rendered):
            # Names the key, never the value: it may be a secret.
            raise RuntimeError(f"{key} contains a line break or control character")
        lines.append(f"{key} = {rendered}")
    body = "\n".join(lines) + "\n"

    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_name(f".{path.name}.tmp")
    temp_path.write_text(body, encoding="utf-8")
    os.replace(temp_path, path)
