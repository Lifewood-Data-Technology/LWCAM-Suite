"""The upload sweep: published export packages go to an S3 bucket.

Ported from QC's `app/services/upload.py`, which ran this as a 60-second
sweep on the QC server itself. Here it is the standalone app's whole reason to
exist, run from the main thread of `console.py`'s loop instead of a
`PeriodicSweep` on a scheduler - `settings`/`runtime_config` become the
`config.Config` object the caller loads fresh before every scan, and the
ledger path is `config.state_file` instead of a path derived from the
export's own temp_dir.

State lives in `state_file`, keyed by package name. An entry is UPLOADED once
every file has been PUT and its size read back from the bucket matches the
local file; anything short of that is FAILED with an error, an attempt count
and a back-off, and is retried on a later sweep (or at once via the retry
endpoint).

An UPLOADED package is then SUMMARISED - one row in Upload_Summary.db3 (see
summary.py) with title, image count, size, speed, duration, local date/time
and Rework - and then MOVED out of watch_root into the "Uploaded" folder
(done_root), so watch_root holds only what has not reached the bucket yet.
The ledger row is written UPLOADED before the move and gains `movedTo` after
it, and the move itself is idempotent (see `move_to_done`), so a crash at any
point between resumes on the next sweep without a second upload and without a
half-moved package.

Crash safety, end to end: every PUT is verified by size before the ledger
says UPLOADED; the ledger is written with the same fsynced atomic writer
LWIP's own state files use; a file already in the bucket at the local size is
never sent again; and a package already called UPLOADED is just moved. What
this does NOT cover is a multipart upload torn by a power cut mid-part: S3
keeps those parts (billed) until aborted - set a bucket lifecycle rule
"AbortIncompleteMultipartUpload after 1 day" so they age out on their own.

Rework, the one behaviour change from QC's copy: an UPLOADED package whose
current fingerprint no longer matches its ledger row (folder package: sha256
of the sorted `relpath|size|mtime_ns` of every file; zip package:
`size|mtime_ns` of the zip itself) is treated as newly published - QC
republished it under the same Group ID after a client rework - and goes
through the upload path again instead of only being checked for a pending
summary row or move. This replaces QC's `clear_upload_ledger_entry`, which had
to be called from the export side each time; here the engine notices on its
own. A row with no `fingerprint` (never happens for a package this app wrote
itself, but the ledger format is otherwise identical to QC's) is treated as
matching, since there is nothing to compare against.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import stat
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from . import log
from .config import Config, parse_s3_path
from .ledger import JsonLedger, LedgerCorrupt, LedgerUnavailable, atomic_json
from .paths import fs_path
from .summary import SUMMARY_FILE
from . import summary as upload_summary

# Failed uploads wait attempts x this before the sweep tries again, capped.
RETRY_STEP = timedelta(minutes=5)
RETRY_CAP = timedelta(hours=1)

# A network share that stops answering must not freeze the sweep, the
# heartbeat or the console: every check of it runs on a worker thread.
WATCH_CHECK_SECONDS = 10.0
# A package is uploaded only after its content has been unchanged this long
# (guards hand-copied or foreign packages that are still being written).
SETTLE_SECONDS = 10.0
# Windows errors that mean "the server answered and there is no such folder",
# as opposed to the server not answering (53 network path not found, 64, 67, 1231...).
_NOT_FOUND_WINERRORS = {2, 3}


def _bounded(fn: Callable[[], Any], seconds: float | None = None) -> Any:
    """Runs `fn` on a daemon thread; raises TimeoutError if it does not finish.
    A wedged call leaks its (daemon) thread until the OS gives up - acceptable."""
    seconds = WATCH_CHECK_SECONDS if seconds is None else seconds
    box: dict[str, Any] = {}

    def work() -> None:
        try:
            box["value"] = fn()
        except BaseException as error:  # noqa: BLE001 - re-raised in the caller
            box["error"] = error

    thread = threading.Thread(target=work, name="lwcam-upload-fscheck", daemon=True)
    thread.start()
    thread.join(seconds)
    if thread.is_alive():
        raise TimeoutError(f"no answer within {seconds:g} s")
    if "error" in box:
        raise box["error"]
    return box.get("value")


def watch_state(watch_root: Path, seconds: float | None = None) -> tuple[str, str | None]:
    """("ok" | "missing" | "unreachable", plain-English problem or None)."""
    try:
        if _bounded(lambda: fs_path(watch_root).is_dir(), seconds):
            return "ok", None
        # is_dir() swallows most errors as False; stat() says which one it was.
        _bounded(lambda: os.stat(fs_path(watch_root)), seconds)
        return "missing", f"Watch folder {watch_root} is not a folder"
    except FileNotFoundError as error:
        if os.name != "nt" or getattr(error, "winerror", None) in _NOT_FOUND_WINERRORS:
            return "missing", f"Watch folder {watch_root} does not exist"
        return "unreachable", f"Watch folder {watch_root} is unreachable"
    except Exception:  # noqa: BLE001 - timeout, access denied, network down...
        return "unreachable", f"Watch folder {watch_root} is unreachable"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _next_attempt(attempts: int, *, permanent: bool = False) -> str:
    # A permanent failure (keys or bucket rejected) skips the step-up: nothing
    # changes until someone fixes Settings, so it waits the full cap at once.
    delay = RETRY_CAP if permanent else min(RETRY_STEP * attempts, RETRY_CAP)
    return (utc_now() + delay).isoformat()


CREDENTIAL_CODES = {
    "InvalidAccessKeyId", "SignatureDoesNotMatch", "ExpiredToken",
    "InvalidClientTokenId", "AccessDenied", "403", "Forbidden",
}
BUCKET_CODES = {
    "NoSuchBucket", "PermanentRedirect", "AuthorizationHeaderMalformed",
    "IllegalLocationConstraintException",
}
NETWORK_CODES = {
    "EndpointConnectionError", "ConnectTimeout", "ConnectTimeoutError",
    "ReadTimeout", "ReadTimeoutError", "ConnectionClosedError",
}


def error_code(error: BaseException) -> str:
    """The S3/botocore code behind an error: a ClientError's own code, the
    code in boto3's S3UploadFailedError text ("An error occurred (X) ..."), or
    the exception's class name (botocore's network errors)."""
    for exc in (error, error.__cause__):
        response = getattr(exc, "response", None)
        if isinstance(response, dict) and response.get("Error", {}).get("Code"):
            return str(response["Error"]["Code"])
    match = re.search(r"An error occurred \((\w+)\)", str(error))
    return match.group(1) if match else type(error).__name__


def classify_error(error: BaseException) -> tuple[str, str]:
    """(kind, code): kind is credentials / bucket / network / other."""
    code = error_code(error)
    if code in CREDENTIAL_CODES:
        return "credentials", code
    if code in BUCKET_CODES:
        return "bucket", code
    if code in NETWORK_CODES:
        return "network", code
    return "other", code


def is_permanent(kind: str) -> bool:
    return kind in ("credentials", "bucket")


class UploadError(RuntimeError):
    """Transfer-time problems, worded for the operator."""


class UploadStopped(Exception):
    """A stop was requested between two files of a package. Not a failure: the
    package stays as it was and resumes (finished files are skipped) later."""


# A HEAD that S3 answers with these says nothing about the keys: many IAM
# policies allow PutObject but not HeadObject/ListBucket, and S3 then answers
# 403 for a missing key. Only the PUT itself decides "keys rejected".
HEAD_DENIED_CODES = {"403", "AccessDenied", "Forbidden"}


@dataclass(frozen=True)
class UploadTarget:
    bucket: str
    prefix: str
    region: str | None
    access_key: str
    secret_key: str
    watch_root: Path
    done_root: Path | None
    summary_db: Path | None
    https_proxy: str = ""

    def key_for(self, *parts: str) -> str:
        return "/".join(part.strip("/") for part in (self.prefix, *parts) if part.strip("/"))


def upload_target(config: Config) -> UploadTarget:
    bucket, prefix = parse_s3_path(config.s3_path)
    summary_db = (config.summary_root / SUMMARY_FILE) if config.summary_root else None
    return UploadTarget(
        bucket=bucket,
        prefix=prefix,
        region=config.s3_region or None,
        access_key=config.s3_access_key,
        secret_key=config.s3_secret_key,
        watch_root=config.watch_root,
        done_root=config.done_root,
        summary_db=summary_db,
        https_proxy=config.https_proxy,
    )


def _is_link(path: Path | str) -> bool:
    """A symlink, junction or any other reparse point (OneDrive placeholder,
    dedup stub...). Never followed: a link out of watch_root could pull in - and
    upload - files that were never exported. Unreadable counts as a link."""
    try:
        info = os.lstat(path)
    except OSError:
        return True
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    )


def _iter_files(root: Path) -> list[Path]:
    """Every regular file under `root`, links skipped, sorted. `root` is already
    an fs_path."""
    found: list[Path] = []
    stack = [root]
    while stack:
        with os.scandir(stack.pop()) as entries:
            for entry in entries:
                if _is_link(entry.path):
                    continue
                if entry.is_dir(follow_symlinks=False):
                    stack.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    found.append(Path(entry.path))
    return sorted(found)


def group_id_for(package: Path | str) -> str:
    """The Group ID a package name stands for: a zip's stem, a folder's whole
    name (a folder called `G1.2` must not lose its `.2`)."""
    name = Path(package).name
    return name[:-4] if name.lower().endswith(".zip") else name


def _package_files(package: Path) -> dict[str, int]:
    """Relative path -> size for a folder package, or {name: size} for a ZIP."""
    if fs_path(package).is_dir():
        root = fs_path(package)
        return {p.relative_to(root).as_posix(): p.stat().st_size for p in _iter_files(root)}
    return {package.name: fs_path(package).stat().st_size}


def _md5_hex(path: Path) -> str:
    digest = hashlib.md5()
    with fs_path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _same_content(etag: str, path: Path) -> bool:
    """Whether `path` is what a same-size object with this ETag already holds.

    A single-part PUT's ETag is the MD5 of the object, quoted; a multipart
    upload's is `<hash-of-part-hashes>-<partcount>` and proves nothing about
    the plaintext without redoing the same multipart hash S3 used, which
    needs the original part size - not worth it here, so it re-uploads.
    """
    if not etag or "-" in etag:
        return False
    return etag.lower() == _md5_hex(path).lower()


def _fingerprint(package: Path) -> str:
    """The rework signal: a folder's own content fingerprint (sha256 of every
    file's `relpath|size|mtime_ns`, sorted so file order never matters), or a
    zip's `size|mtime_ns` - cheap enough to compute on every scan, since only
    UPLOADED packages are checked against their stored value."""
    root = fs_path(package)
    if root.is_dir():
        parts = sorted(
            f"{p.relative_to(root).as_posix()}|{p.stat().st_size}|{p.stat().st_mtime_ns}"
            for p in _iter_files(root)
        )
        return hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()
    info = root.stat()
    return f"{info.st_size}|{info.st_mtime_ns}"


def _is_rework_package(package: Path) -> bool:
    """Whether this package says it is a client rework, read from its own
    GroupMetadataImage.csv (the same value the summary row uses), so it is
    known even when no Upload Summary database is configured.

    Best effort: an unreadable CSV means "not a rework", which keeps the
    existing refusal-to-overwrite rather than making a bad read destructive.
    """
    try:
        meta = upload_summary.read_group_metadata(package)
    except Exception:  # noqa: BLE001 - a bad read must not decide to overwrite
        return False
    # Compared to the text, NOT bool(): normalize_rework returns the CSV's own
    # "TRUE"/"FALSE" strings, and bool("FALSE") is True.
    return upload_summary.normalize_rework(meta.get("Rework")) == "TRUE"


def move_to_done(package: Path, done_dir: Path, *, replace: bool = False) -> Path:
    """Moves an uploaded package into the Uploaded folder. Idempotent.

    With `replace` (a client rework) the previous copy is renamed aside first
    and deleted only once the new one is in place, so a crash never leaves the
    Uploaded folder without the package.

    Same volume: one atomic rename straight to the final name - a staging
    step in between would leave a crash-stranded dot-file that no sweep ever
    lists again. Other volume: copy into staging, verify every file's size,
    rename to final, THEN delete the source. So at every crash point the
    source is either intact or already fully at the final name.
    """
    fs_path(done_dir).mkdir(parents=True, exist_ok=True)
    final = done_dir / package.name
    partial = done_dir / f".{package.name}.moving"
    aside: Path | None = None
    if fs_path(final).exists():
        if replace:
            # A client rework republishes under the SAME Group ID, so what is
            # here is the version the client rejected and the bucket has just
            # been overwritten with the corrected one. It is renamed aside, not
            # deleted first, so a crash before the corrected package is in
            # place loses nothing; the move below puts it back if it fails.
            _remove_old_asides(done_dir)
            aside = done_dir / f".{package.name}.old-{int(time.time())}-{uuid.uuid4().hex}"
            os.rename(fs_path(final), fs_path(aside))
        elif _package_files(final) != _package_files(package):
            raise UploadError(
                f"{final} already exists with different contents; not overwriting"
            )
        else:
            _remove(package)
            return final
    try:
        _move_in(package, final, partial, done_dir)
    except BaseException:
        if aside is not None:
            _remove(final)
            os.rename(fs_path(aside), fs_path(final))
        raise
    if aside is not None:
        _remove(aside)
        if fs_path(aside).exists():
            log("upload", f"could not delete the replaced package {aside}; cleaned up later")
    return final


_slow_move_logged = False


def _move_in(package: Path, final: Path, partial: Path, done_dir: Path) -> None:
    _remove(partial)  # staging a cross-volume copy left behind when it crashed
    try:
        os.rename(fs_path(package), fs_path(final))
        return
    except OSError:
        pass  # another volume: fall through to copy-verify-rename-delete
    global _slow_move_logged
    if not _slow_move_logged:
        _slow_move_logged = True
        log(
            "SYSTEM",
            f"{done_dir} is not on the same volume as the watch folder, so uploaded packages are "
            "copied, size-checked and then deleted instead of renamed - slower, but a crash never "
            "loses a package. Put the Uploaded folder on the same drive/share to make it instant.",
        )
    if fs_path(package).is_dir():
        shutil.copytree(fs_path(package), fs_path(partial))
    else:
        shutil.copyfile(fs_path(package), fs_path(partial))
    if _package_files(partial) != _package_files(package):
        _remove(partial)
        raise UploadError(f"copy to {done_dir} did not match the source")
    os.replace(fs_path(partial), fs_path(final))
    _remove(package)


def _remove_old_asides(done_dir: Path) -> None:
    """Deletes `.<name>.old-<epoch>-<hex>` leftovers (a crash or a locked file
    between setting a rework's previous copy aside and deleting it) older than
    a day. Dot-names are never listed as packages, so they are invisible."""
    for entry in fs_path(done_dir).iterdir():
        _, marker, tail = entry.name.rpartition(".old-")
        stamp = tail.split("-", 1)[0]
        if entry.name.startswith(".") and marker and stamp.isdigit() and time.time() - int(stamp) > 86400:
            _remove(entry)


def _remove(path: Path) -> None:
    if fs_path(path).is_dir():
        shutil.rmtree(fs_path(path), ignore_errors=True)
    elif fs_path(path).exists():
        fs_path(path).unlink(missing_ok=True)


class S3Store:
    """The two calls the sweep makes, over a boto3 client built on first use.

    boto3 is imported here rather than at module import so the app still
    starts (and the tests still run) without the wheel installed; the console
    only constructs one of these when a scan actually runs with upload enabled.
    """

    def __init__(self, target: UploadTarget) -> None:
        self._target = target
        self._client: Any = None
        # Set when a HEAD came back 403: the size read-back is then impossible
        # and the PUT's own success is the proof (see _upload_package).
        self.head_denied = False

    def _s3(self) -> Any:
        if self._client is None:
            import boto3
            from botocore.config import Config as BotoConfig

            proxy = self._target.https_proxy
            self._client = boto3.client(
                "s3",
                region_name=self._target.region,
                aws_access_key_id=self._target.access_key,
                aws_secret_access_key=self._target.secret_key,
                config=BotoConfig(
                    retries={"max_attempts": 5, "mode": "standard"},
                    connect_timeout=15,
                    read_timeout=60,
                    **({"proxies": {"https": proxy, "http": proxy}} if proxy else {}),
                ),
            )
        return self._client

    def remote_size(self, key: str) -> int | None:
        info = self.remote_info(key)
        return info[0] if info else None

    def remote_info(self, key: str) -> tuple[int, str] | None:
        """(size, ETag) of the object in the bucket, or None when it is not
        there (or when HEAD is not permitted - see HEAD_DENIED_CODES). One HEAD
        call serves both."""
        from botocore.exceptions import ClientError

        try:
            head = self._s3().head_object(Bucket=self._target.bucket, Key=key)
        except ClientError as error:
            code = str(error.response.get("Error", {}).get("Code", ""))
            if code in {"404", "NoSuchKey", "NotFound"}:
                return None
            if code in HEAD_DENIED_CODES:
                self.head_denied = True
                return None
            raise
        return int(head["ContentLength"]), str(head.get("ETag") or "").strip('"')

    def put_file(self, path: Path, key: str) -> None:
        # upload_file switches to multipart above 8 MB on its own, so a
        # multi-gigabyte ZIP needs nothing special here.
        self._s3().upload_file(str(path), self._target.bucket, key)


StoreFactory = Callable[[UploadTarget], Any]


class UploadCoordinator:
    def __init__(self, store_factory: StoreFactory = S3Store) -> None:
        self._store_factory = store_factory
        self._lock = threading.RLock()
        self._current: dict[str, Any] | None = None
        self._last_scan_count: int | None = None
        # `writer(group_id, error) -> bool`: the capture_folders write-back
        # (error None = mark ingested). Set by the console; False/raise means
        # "not written, try again on a later scan".
        self.db_writer: Callable[[str, str | None], bool] | None = None
        # Set by the HTTP thread, applied by the scan thread - the scan thread
        # is the ONLY writer of the ledger, so a click can never race a save.
        self._retry_requested = threading.Event()
        # Why the ledger cannot be used right now (None = fine). Shown as a
        # banner and sent in the heartbeat.
        self.ledger_problem: str | None = None
        # Why watch_root cannot be listed right now (None = fine), and which
        # kind ("missing" / "unreachable"). Set by the sweep, read by the
        # heartbeat and the console - they never touch the share themselves.
        self.watch_problem: str | None = None
        self.watch_kind: str | None = None
        # Scan timing for the heartbeat (monotonic; created-at until the first scan).
        self._created_at = time.monotonic()
        self._scan_started_at: float | None = None
        self._scan_done_at: float | None = None
        self._scanning = False
        # Settle check: name -> (fingerprint, monotonic time first seen with it).
        self._first_seen: dict[str, tuple[str, float]] = {}
        self._settle_noted: set[str] = set()  # "still changing" already logged
        self._settle_ready: float | None = None  # earliest settling package's ready time

    def scan_age_minutes(self) -> float:
        """Minutes since the last COMPLETED scan; while one is running, since it
        started (a hung scan keeps growing; a long healthy scan is not hidden
        because scan_once only counts as done when it returns)."""
        with self._lock:
            since = (
                self._scan_started_at if self._scanning
                else self._scan_done_at if self._scan_done_at is not None
                else self._created_at
            )
        return round((time.monotonic() - since) / 60, 1)

    # Ledger

    @staticmethod
    def ledger_path(config: Config) -> Path:
        return config.state_file

    def _load(self, path: Path) -> dict[str, Any]:
        """The ledger, or raises LedgerCorrupt / LedgerUnavailable (recorded in
        `ledger_problem`). Damage is never read as "nothing uploaded yet"."""
        try:
            data = JsonLedger(path).load_strict()
        except (LedgerCorrupt, LedgerUnavailable) as error:
            if self.ledger_problem != str(error):
                log("ERROR", str(error))
            self.ledger_problem = str(error)
            raise
        self.ledger_problem = None
        return data

    @staticmethod
    def _save(path: Path, ledger: dict[str, Any]) -> None:
        atomic_json(path, ledger, keep_backup=True)

    @staticmethod
    def packages(watch_root: Path) -> list[Path]:
        """Published packages: `<GroupID>.zip` files or `<GroupID>/` folders.

        Dot-prefixed entries are the export's own staging/state and never
        packages. Both forms can coexist if a project switched output format.
        """
        if not fs_path(watch_root).is_dir():
            return []
        found = [
            path
            for path in fs_path(watch_root).iterdir()
            if not path.name.startswith(".")
            and not _is_link(path)
            and (path.is_dir() or path.suffix.lower() == ".zip")
        ]
        return sorted(found, key=lambda path: path.name)

    # Reporting

    def status(
        self,
        config: Config | None,
        *,
        config_problem: str | None = None,
        last_scan_at: str | None = None,
        next_scan_at: str | None = None,
    ) -> dict[str, Any]:
        """What GET /api/status shows. Never raises: a broken setup is a
        message here, not an error page."""
        result: dict[str, Any] = {
            "enabled": bool(config.enabled) if config else False,
            "problem": config_problem,
            "bucket": None,
            "prefix": None,
            "watch_root": str(config.watch_root) if config else "",
            "done_root": str(config.done_root) if config and config.done_root else "",
            "current": None,
            "pending": [],
            "failures": [],
            "recent": [],
            "uploadedCount": 0,
            "permanentProblem": None,
            "ledgerProblem": None,
            "lastErrorKind": None,
            "lastScanAt": last_scan_at,
            "nextScanAt": next_scan_at,
            "watchProblem": self.watch_problem,
            "watchKind": self.watch_kind,
            "dbPending": 0,
            "scanIntervalMinutes": round(config.interval_seconds / 60, 1) if config else None,
        }
        if config is None or not config.enabled:
            return result
        target = upload_target(config)
        result.update(bucket=target.bucket, prefix=target.prefix)
        try:
            ledger = self._load(self.ledger_path(config))
        except (LedgerCorrupt, LedgerUnavailable) as error:
            ledger = {}
            result["ledgerProblem"] = str(error)
        uploaded = [e for e in ledger.values() if isinstance(e, dict) and e.get("status") == "UPLOADED"]
        # An uploaded package whose summary row or move keeps failing is a
        # failure the operator has to see, even though the bytes are safe.
        failed = [
            {**e, "error": e.get("error") or e.get("moveError") or e.get("summaryError")}
            for e in ledger.values()
            if isinstance(e, dict) and _needs_attention(e)
        ]
        result["dbPending"] = sum(
            1 for e in ledger.values() if isinstance(e, dict) and e.get("dbPending")
        )
        uploaded.sort(key=lambda e: str(e.get("uploadedAt") or ""), reverse=True)
        failed.sort(key=lambda e: str(e.get("failedAt") or ""), reverse=True)
        listed = {str(e.get("package")) for e in (*uploaded, *failed)}
        with self._lock:
            current = dict(self._current) if self._current else None
        try:
            # Bounded, and skipped while the sweep knows the share is down.
            waiting = (
                [] if self.watch_problem
                else _bounded(lambda: self.packages(config.watch_root))
            )
        except Exception:  # noqa: BLE001 - the status page must still answer
            waiting = []
        result.update(
            uploadedCount=len(uploaded),
            pending=[p.name for p in waiting if p.name not in listed],
            current=current,
            failures=failed,
            recent=uploaded[:10],
        )
        rejected = next((e for e in failed if is_permanent(str(e.get("errorKind")))), None)
        if rejected:
            result["permanentProblem"] = (
                f"The bucket or keys were rejected: {rejected.get('errorCode')}. "
                "Fix them in Settings."
            )
        if failed:
            result["lastErrorKind"] = failed[0].get("errorKind")
        if result["ledgerProblem"]:
            result["pending"] = []  # unknowable without the ledger
        return result

    # The sweep

    def scan_once(self, config: Config, *, stop_check: Callable[[], bool] | None = None) -> int:
        """Uploads every package not yet recorded as UPLOADED (or republished
        under a changed fingerprint). Returns how many finished this pass.

        `stop_check`, when given, is polled between packages so a shutdown
        request does not have to wait for the whole backlog - the console
        passes a peek at the stop file, never one that deletes it (that
        happens once, in the console's own loop, at the point it actually
        honours the request).
        """
        with self._lock:
            self._scan_started_at = time.monotonic()
            self._scanning = True
        try:
            done = self._scan(config, stop_check)
            # Packages that appeared or changed just now are held back until
            # they have been still for SETTLE_SECONDS; wait for that here (at
            # most two extra passes) instead of leaving them a whole interval.
            extra = 0
            while self._settle_ready is not None and extra < 2:
                while (
                    self._settle_ready is not None
                    and time.monotonic() < self._settle_ready
                    and not (stop_check is not None and stop_check())
                ):
                    time.sleep(max(0.0, min(1.0, self._settle_ready - time.monotonic())))
                if stop_check is not None and stop_check():
                    break
                extra += 1
                done += self._scan(config, stop_check)
            if self._settle_ready is not None and extra >= 2:
                for name in self._first_seen:
                    if name not in self._settle_noted and self._is_settling(name):
                        self._settle_noted.add(name)
                        log("SCAN", f"{name}: still changing; will check again next scan")
            return done
        finally:
            with self._lock:
                self._scanning = False
                self._scan_done_at = time.monotonic()

    def _is_settling(self, name: str) -> bool:
        seen = self._first_seen.get(name)
        return bool(seen) and time.monotonic() - seen[1] < SETTLE_SECONDS

    def _scan(self, config: Config, stop_check: Callable[[], bool] | None) -> int:
        self._settle_ready = None
        target = upload_target(config)
        ledger_path = self.ledger_path(config)
        kind, problem = watch_state(config.watch_root)
        if problem != self.watch_problem:
            log("ERROR" if problem else "SYSTEM", problem or f"Watch folder {config.watch_root} is reachable again")
        self.watch_problem, self.watch_kind = problem, (None if kind == "ok" else kind)
        try:
            ledger = self._load(ledger_path)
        except (LedgerCorrupt, LedgerUnavailable):
            return 0  # refused, already logged; the banner and heartbeat say why
        if self._retry_requested.is_set():
            self._retry_requested.clear()
            cleared = 0
            for row in ledger.values():
                if isinstance(row, dict) and row.get("nextAttemptAt") and _needs_attention(row):
                    row["nextAttemptAt"] = None
                    cleared += 1
            if cleared:
                self._save(ledger_path, ledger)
                log("RETRY", f"cleared back-off on {cleared} failed package(s)")
        use_db = self.db_writer is not None and bool(config.db_host)
        store = self._store_factory(target)
        target_sig = _target_sig(target)
        now = utc_now()
        done = 0
        packages = self.packages(config.watch_root)
        count = len(packages)
        if count or count != self._last_scan_count:
            log("SCAN", f"{count} package(s) waiting")
        self._last_scan_count = count
        present = {p.name for p in packages}
        for name in [n for n in self._first_seen if n not in present]:
            del self._first_seen[name]
            self._settle_noted.discard(name)
        for package in packages:
            if stop_check is not None and stop_check():
                break
            entry = ledger.get(package.name) if isinstance(ledger.get(package.name), dict) else {}
            next_at = entry.get("nextAttemptAt")
            fingerprint = None
            if next_at and _parse_time(next_at) > now:
                if entry.get("status") != "FAILED":
                    continue
                # A failed package waits out its back-off only while nothing
                # has changed: QC republishing it (client rework) or an
                # operator fixing it, or fixed S3 settings, is tried at once.
                fingerprint = _fingerprint(package)
                if entry.get("fingerprint") != fingerprint:
                    log("RETRY", f"{package.name}: package changed since the last failure, retrying now")
                elif is_permanent(str(entry.get("errorKind"))) and entry.get("targetSig") != target_sig:
                    log("RETRY", f"{package.name}: S3 settings changed since the last failure, retrying now")
                else:
                    continue
            if fingerprint is None:
                fingerprint = _fingerprint(package)
            reworked = False
            if entry.get("status") == "UPLOADED":
                old_fingerprint = entry.get("fingerprint")
                if old_fingerprint and old_fingerprint != fingerprint:
                    reworked = True
                    log("REWORK", f"{package.name} republished; uploading again")
                else:
                    # In the bucket already; still here because the summary
                    # row or the move did not happen (not configured then, or
                    # a crash).
                    if self._after_upload(target, package, entry):
                        self._save(ledger_path, ledger)
                    continue
            # Settle: upload only what has been unchanged for SETTLE_SECONDS.
            seen = self._first_seen.get(package.name)
            clock = time.monotonic()
            if seen is None or seen[0] != fingerprint:
                if seen is None:
                    log("SCAN", f"{package.name}: waiting for it to stop changing")
                self._first_seen[package.name] = seen = (fingerprint, clock)
                self._settle_noted.discard(package.name)
            if clock - seen[1] < SETTLE_SECONDS:
                ready = seen[1] + SETTLE_SECONDS
                if self._settle_ready is None or ready < self._settle_ready:
                    self._settle_ready = ready
                continue
            self._settle_noted.discard(package.name)
            attempts = 1 if reworked else int(entry.get("attempts") or 0) + 1
            with self._lock:
                self._current = {"package": package.name, "startedAt": utc_now().isoformat()}
            try:
                started = time.perf_counter()
                key, size, files = self._upload_package(
                    store, target, package, stop_check=stop_check
                )
                duration = time.perf_counter() - started
            except UploadStopped:
                log("SYSTEM", f"stop requested; {package.name} will resume later")
                break
            except Exception as error:  # noqa: BLE001 - every cause becomes a ledger row
                kind, code = classify_error(error)
                permanent = is_permanent(kind)
                ledger[package.name] = {
                    "package": package.name,
                    "groupId": group_id_for(package),
                    "status": "FAILED",
                    "error": str(error) or type(error).__name__,
                    "failedAt": utc_now().isoformat(),
                    "nextAttemptAt": _next_attempt(attempts, permanent=permanent),
                    "attempts": attempts,
                    "fingerprint": fingerprint,
                    "targetSig": target_sig,
                    "errorKind": kind,
                    "errorCode": code,
                }
                if permanent and use_db:
                    ledger[package.name]["dbPending"] = {
                        "error": f"The bucket or keys were rejected: {code}"
                    }
                log("ERROR", f"upload of {package.name} failed (attempt {attempts}): {error}")
                retry_at = _parse_time(ledger[package.name]["nextAttemptAt"]).astimezone()
                log("RETRY", f"{package.name}: next try at {retry_at:%H:%M} (or press Retry failed)")
            else:
                ledger[package.name] = {
                    "package": package.name,
                    "groupId": group_id_for(package),
                    "status": "UPLOADED",
                    "key": key,
                    "size": size,
                    "files": files,
                    "fingerprint": fingerprint,
                    "uploadedAt": utc_now().isoformat(),
                    "uploadDuration": round(duration, 3),
                    "attempts": attempts,
                    "summaryAt": None,
                    "movedTo": None,
                }
                if use_db:
                    ledger[package.name]["dbPending"] = {"ok": True}
                done += 1
                speed = round((size / 1_000_000) / duration, 2) if duration > 0 else 0
                log(
                    "DONE",
                    f"{package.name} uploaded in {duration:.1f}s @ {speed} MB/s",
                )
                # UPLOADED is on disk before the summary and the move start, so
                # a crash inside either can never cause a second upload.
                self._save(ledger_path, ledger)
                self._after_upload(target, package, ledger[package.name])
            finally:
                with self._lock:
                    self._current = None
            # Written per package, not per sweep: a crash mid-sweep keeps what
            # already finished instead of re-uploading it.
            self._save(ledger_path, ledger)
        if use_db and self._flush_db(ledger):
            self._save(ledger_path, ledger)
        return done

    def _flush_db(self, ledger: dict[str, Any]) -> bool:
        """Writes every pending capture_folders update (uploaded / permanent
        error), keyed by Group ID. A failed write never fails an upload: the
        `dbPending` mark stays in the ledger and the next scan retries. The
        first failure ends the pass (the database is unreachable or slow: one
        warning per scan, not one connect timeout per package). A writer that
        answers False (no row matched) leaves the mark too.
        Returns whether the ledger changed."""
        writer = self.db_writer
        if writer is None:
            return False
        changed = False
        for entry in ledger.values():
            pending = entry.get("dbPending") if isinstance(entry, dict) else None
            if not pending:
                continue
            # From the package NAME, not the stored groupId: rows written by an
            # older build cut a dotted folder name at its last dot.
            group_id = group_id_for(str(entry.get("package")))
            try:
                written = writer(group_id, None if pending.get("ok") else pending.get("error"))
            except Exception as error:  # noqa: BLE001 - retried next scan
                log("WARN", f"database write-back failed ({error}); will retry on a later scan")
                break
            if written:
                entry.pop("dbPending", None)
                changed = True
        return changed

    def _after_upload(
        self, target: UploadTarget, package: Path, entry: dict[str, Any]
    ) -> bool:
        """Summary row first, then the move. A failed summary skips the move so
        the package stays in watch_root, where the next sweep finds it and
        retries both in order. Returns whether `entry` changed."""
        summary_db, done_dir = target.summary_db, target.done_root
        changed = False
        if summary_db is not None and not entry.get("summaryAt"):
            changed = True
            ok = self._step(
                entry,
                "summary",
                "summaryAt",
                lambda: self._summary_row(summary_db, package, entry),
                f"write {summary_db}",
            )
            if not ok:
                return True
        if done_dir is not None and not entry.get("movedTo"):
            changed = True
            replace = _is_rework_package(package)
            self._step(
                entry,
                "move",
                "movedTo",
                lambda: str(move_to_done(package, done_dir, replace=replace)),
                f"move to {done_dir}",
            )
        return changed

    @staticmethod
    def _step(
        entry: dict[str, Any],
        prefix: str,
        done_key: str,
        action: Callable[[], Any],
        what: str,
    ) -> bool:
        """Runs one post-upload step and records the outcome on the entry.

        Success stores action()'s result under `done_key` and clears the
        step's error and back-off. Failure stays UPLOADED (the bytes are
        safe) but sets `<prefix>Error`, counts `<prefix>Attempts` and backs
        off, which is what the failures list shows.
        """
        try:
            value = action()
        except Exception as error:  # noqa: BLE001 - recorded, retried next sweep
            attempts = int(entry.get(f"{prefix}Attempts") or 0) + 1
            entry.update({
                f"{prefix}Error": f"uploaded, but could not {what}: {error or type(error).__name__}",
                f"{prefix}Attempts": attempts,
                "nextAttemptAt": _next_attempt(attempts),
            })
            log(
                "WARN",
                f"{prefix} of {entry.get('package')} failed (attempt {attempts}): {error}",
            )
            return False
        entry.update({done_key: value, f"{prefix}Error": None, "nextAttemptAt": None})
        entry.pop(f"{prefix}Attempts", None)
        if prefix == "summary":
            log("SUMMARY", f"row written for {entry.get('package')}")
        elif prefix == "move":
            log("MOVE", f"{entry.get('package')} -> {value}")
        return True

    @staticmethod
    def _summary_row(summary_db: Path, package: Path, entry: dict[str, Any]) -> str:
        """Writes the package's Upload_Summary row; returns when it was written."""
        meta = upload_summary.read_group_metadata(package)
        upload_summary.record_upload(
            summary_db,
            capture_id=group_id_for(package),
            title=meta.get("Title") or None,
            image_count=upload_summary.image_count_from(meta, package),
            rework=upload_summary.normalize_rework(meta.get("Rework")),
            size_bytes=int(entry.get("size") or 0),
            duration_s=float(entry.get("uploadDuration") or 0),
            at=datetime.now(),
        )
        return utc_now().isoformat()

    def _upload_package(
        self,
        store: Any,
        target: UploadTarget,
        package: Path,
        stop_check: Callable[[], bool] | None = None,
    ) -> tuple[str, int, int]:
        """PUTs one package and proves every file arrived at its local size.

        A ZIP is one object at `<prefix>/<GroupID>.zip`; a folder package keeps
        its layout under `<prefix>/<GroupID>/`. A file already in the bucket
        with the SAME CONTENT is skipped - not just the same size - which is
        what makes a retry after a crash resume rather than restart, without
        also skipping a same-length client-rework correction.
        """
        if fs_path(package).is_dir():
            root = fs_path(package)
            files = _iter_files(root)
            base = target.key_for(package.name)
            keys = [target.key_for(package.name, p.relative_to(root).as_posix()) for p in files]
        else:
            files = [fs_path(package)]
            base = target.key_for(package.name)
            keys = [base]
        if not files:
            raise UploadError("The package is empty")
        total_size_mb = round(sum(p.stat().st_size for p in files) / 1_000_000, 1)
        log("UPLOAD", f"{package.name} ({total_size_mb} MB, {len(files)} file(s))")
        total = 0
        for path, key in zip(files, keys, strict=True):
            if stop_check is not None and stop_check():
                raise UploadStopped()
            size = path.stat().st_size
            total += size
            info = store.remote_info(key)
            # Size mismatch is a fast negative - definitely different, no need
            # to hash. A size match is NOT proof of the same content, so it
            # only short-circuits the re-upload when the ETag confirms it.
            if info is not None and info[0] == size and _same_content(info[1], path):
                log("SKIP", f"{key} already in bucket")
                continue
            store.put_file(path, key)
            remote = store.remote_size(key)
            if remote is None and getattr(store, "head_denied", False):
                # No permission to HEAD: the PUT succeeded (boto3 checks the
                # ETag/checksum), which is all the proof this account allows.
                log("VERIFY", f"{key}: size read-back not permitted; trusting the upload")
            elif remote != size:
                log("VERIFY", f"{key}: bucket holds {remote} bytes, expected {size}")
                raise UploadError(f"{key}: the bucket holds {remote} bytes, expected {size}")
        return base, total, len(files)

    def retry_failed(self, config: Config | None = None) -> None:
        """Asks the next sweep to clear the back-off on every FAILED entry.
        Only sets a flag: the scan thread applies it, being the ledger's one
        writer (an HTTP thread saving here could overwrite a scan's save)."""
        self._retry_requested.set()


def _target_sig(target: UploadTarget) -> str:
    """Identifies the S3 destination and keys (hashed, so no secret is stored):
    a permanent failure is retried at once when this no longer matches."""
    text = "|".join(
        (target.bucket, target.prefix, target.region or "", target.access_key,
         target.secret_key, target.https_proxy)
    )
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _needs_attention(entry: dict[str, Any]) -> bool:
    """A ledger row the operator should see: the upload failed, or it succeeded
    but the summary row or the move did not."""
    return bool(
        entry.get("status") == "FAILED" or entry.get("moveError") or entry.get("summaryError")
    )


def _parse_time(value: Any) -> datetime:
    try:
        parsed = datetime.fromisoformat(str(value))
    except ValueError:
        return utc_now()
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=utc_now().tzinfo)


__all__ = [
    "classify_error",
    "S3Store",
    "UploadCoordinator",
    "UploadError",
    "UploadTarget",
    "move_to_done",
    "parse_s3_path",
    "upload_target",
    "utc_now",
]
