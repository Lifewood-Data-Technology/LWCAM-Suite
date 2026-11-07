"""Directory protocol v1. A ready marker commits an immutable request."""
import hashlib
import json
import math
import os
import uuid
from datetime import datetime, date
from pathlib import Path

MAX_JSON = 1024 * 1024
MAX_IMAGE = 128 * 1024 * 1024


class ProtocolError(ValueError):
    code = "invalid_request"


class UnsupportedVersion(ProtocolError):
    code = "unsupported_version"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    if Path(path).stat().st_size > MAX_JSON:
        raise ProtocolError("JSON exceeds protocol limit")
    data = Path(path).read_bytes()
    if len(data) > MAX_JSON:
        raise ProtocolError("JSON exceeds protocol limit")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ProtocolError("Expected JSON object")
    return value, data


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    with temp.open("w", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=False, allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temp, path)


def plain_path(path):
    """Reject share-controlled links/junctions, including Windows reparse points."""
    info = Path(path).lstat()
    if Path(path).is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ProtocolError("Links and reparse points are not allowed")
    return Path(path)


def validate_request(folder):
    folder = plain_path(folder)
    if str(uuid.UUID(folder.name)) != folder.name:
        raise ProtocolError("Invalid task UUID")
    ready, _ = read_json(plain_path(folder / "ready.json"))
    request, raw = read_json(plain_path(folder / "request.json"))
    if type(request.get("version")) is not int or request["version"] != 1:
        raise UnsupportedVersion("Unsupported protocol version")
    if ready.get("task_id") != folder.name or request.get("task_id") != folder.name:
        raise ProtocolError("Task identity mismatch")
    if ready.get("request_sha256") != sha(raw):
        raise ProtocolError("Request checksum mismatch")
    for key in ("device_id", "phone_serial", "operator", "captured_at", "capture_local_date"):
        if not isinstance(request.get(key), str) or not request[key]:
            raise ProtocolError(f"Missing {key}")
    captured = datetime.fromisoformat(request["captured_at"])
    if captured.tzinfo is None or captured.date() != date.fromisoformat(request["capture_local_date"]):
        raise ProtocolError("Capture date/offset mismatch")
    image = request.get("image", {})
    if not isinstance(image, dict):
        raise ProtocolError("Invalid image descriptor")
    if image.get("name") != "chart.jpg" or type(image.get("size")) is not int:
        raise ProtocolError("Invalid image descriptor")
    if not 0 < image["size"] <= MAX_IMAGE:
        raise ProtocolError("Invalid image size")
    analysis = request.get("analysis", {})
    if not isinstance(analysis, dict) or type(analysis.get("force", False)) is not bool:
        raise ProtocolError("Invalid analysis options")
    corners = analysis.get("corners")
    if corners is not None:
        if (not isinstance(corners, list) or len(corners) != 4 or
                any(not isinstance(c, list) or len(c) != 2 or
                    any(type(v) not in (float, int) or not math.isfinite(v) or v < 0 for v in c)
                    for c in corners)):
            raise ProtocolError("Invalid manual corners")
    picture = plain_path(folder / "chart.jpg")
    if picture.stat().st_size != image["size"]:
        raise ProtocolError("Image size mismatch")
    data = picture.read_bytes()
    if sha(data) != image.get("sha256"):
        raise ProtocolError("Image checksum mismatch")
    return request, sha(raw), data
