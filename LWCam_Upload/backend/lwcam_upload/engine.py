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
import shutil
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable

from . import log
from .config import Config, parse_s3_path
from .ledger import JsonLedger, atomic_json
from .paths import fs_path
from .summary import SUMMARY_FILE
from . import summary as upload_summary

# Failed uploads wait attempts x this before the sweep tries again, capped.
RETRY_STEP = timedelta(minutes=5)
RETRY_CAP = timedelta(hours=1)


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _next_attempt(attempts: int) -> str:
    return (utc_now() + min(RETRY_STEP * attempts, RETRY_CAP)).isoformat()


class UploadError(RuntimeError):
    """Transfer-time problems, worded for the operator."""


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
    )


def _package_files(package: Path) -> dict[str, int]:
    """Relative path -> size for a folder package, or {name: size} for a ZIP."""
    if fs_path(package).is_dir():
        root = fs_path(package)
        return {
            p.relative_to(root).as_posix(): p.stat().st_size
            for p in root.rglob("*")
            if p.is_file()
        }
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
            for p in root.rglob("*")
            if p.is_file()
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

    Same volume: one atomic rename straight to the final name - a staging
    step in between would leave a crash-stranded dot-file that no sweep ever
    lists again. Other volume: copy into staging, verify every file's size,
    rename to final, THEN delete the source. So at every crash point the
    source is either intact or already fully at the final name.
    """
    fs_path(done_dir).mkdir(parents=True, exist_ok=True)
    final = done_dir / package.name
    partial = done_dir / f".{package.name}.moving"
    if fs_path(final).exists():
        if replace:
            # A client rework republishes under the SAME Group ID, so what is
            # here is the version the client rejected and the bucket has just
            # been overwritten with the corrected one.
            _remove(final)
        elif _package_files(final) != _package_files(package):
            raise UploadError(
                f"{final} already exists with different contents; not overwriting"
            )
        else:
            _remove(package)
            return final
    _remove(partial)  # staging a cross-volume copy left behind when it crashed
    try:
        os.rename(fs_path(package), fs_path(final))
        return final
    except OSError:
        pass  # another volume: fall through to copy-verify-rename-delete
    if fs_path(package).is_dir():
        shutil.copytree(fs_path(package), fs_path(partial))
    else:
        shutil.copyfile(fs_path(package), fs_path(partial))
    if _package_files(partial) != _package_files(package):
        _remove(partial)
        raise UploadError(f"copy to {done_dir} did not match the source")
    os.replace(fs_path(partial), fs_path(final))
    _remove(package)
    return final


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

    def _s3(self) -> Any:
        if self._client is None:
            import boto3
            from botocore.config import Config as BotoConfig

            self._client = boto3.client(
                "s3",
                region_name=self._target.region,
                aws_access_key_id=self._target.access_key,
                aws_secret_access_key=self._target.secret_key,
                config=BotoConfig(retries={"max_attempts": 5, "mode": "standard"}),
            )
        return self._client

    def remote_size(self, key: str) -> int | None:
        info = self.remote_info(key)
        return info[0] if info else None

    def remote_info(self, key: str) -> tuple[int, str] | None:
        """(size, ETag) of the object in the bucket, or None when it is not
        there. One HEAD call serves both."""
        from botocore.exceptions import ClientError

        try:
            head = self._s3().head_object(Bucket=self._target.bucket, Key=key)
        except ClientError as error:
            code = str(error.response.get("Error", {}).get("Code", ""))
            if code in {"404", "NoSuchKey", "NotFound"}:
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

    # Ledger

    @staticmethod
    def ledger_path(config: Config) -> Path:
        return config.state_file

    @staticmethod
    def _load(path: Path) -> dict[str, Any]:
        return JsonLedger(path).load()

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
            "lastScanAt": last_scan_at,
            "nextScanAt": next_scan_at,
        }
        if config is None or not config.enabled:
            return result
        target = upload_target(config)
        result.update(bucket=target.bucket, prefix=target.prefix)
        ledger = self._load(self.ledger_path(config))
        uploaded = [e for e in ledger.values() if isinstance(e, dict) and e.get("status") == "UPLOADED"]
        # An uploaded package whose summary row or move keeps failing is a
        # failure the operator has to see, even though the bytes are safe.
        failed = [
            {**e, "error": e.get("error") or e.get("moveError") or e.get("summaryError")}
            for e in ledger.values()
            if isinstance(e, dict) and _needs_attention(e)
        ]
        uploaded.sort(key=lambda e: str(e.get("uploadedAt") or ""), reverse=True)
        failed.sort(key=lambda e: str(e.get("failedAt") or ""), reverse=True)
        listed = {str(e.get("package")) for e in (*uploaded, *failed)}
        with self._lock:
            current = dict(self._current) if self._current else None
        result.update(
            uploadedCount=len(uploaded),
            pending=[p.name for p in self.packages(config.watch_root) if p.name not in listed],
            current=current,
            failures=failed,
            recent=uploaded[:10],
        )
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
        target = upload_target(config)
        ledger_path = self.ledger_path(config)
        ledger = self._load(ledger_path)
        store = self._store_factory(target)
        now = utc_now()
        done = 0
        packages = self.packages(config.watch_root)
        count = len(packages)
        if count or count != self._last_scan_count:
            log("SCAN", f"{count} package(s) waiting")
        self._last_scan_count = count
        for package in packages:
            if stop_check is not None and stop_check():
                break
            entry = ledger.get(package.name) if isinstance(ledger.get(package.name), dict) else {}
            next_at = entry.get("nextAttemptAt")
            if next_at and _parse_time(next_at) > now:
                continue
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
                        atomic_json(ledger_path, ledger)
                    continue
            attempts = 1 if reworked else int(entry.get("attempts") or 0) + 1
            with self._lock:
                self._current = {"package": package.name, "startedAt": utc_now().isoformat()}
            try:
                started = time.perf_counter()
                key, size, files = self._upload_package(store, target, package)
                duration = time.perf_counter() - started
            except Exception as error:  # noqa: BLE001 - every cause becomes a ledger row
                ledger[package.name] = {
                    "package": package.name,
                    "groupId": package.stem,
                    "status": "FAILED",
                    "error": str(error) or type(error).__name__,
                    "failedAt": utc_now().isoformat(),
                    "nextAttemptAt": _next_attempt(attempts),
                    "attempts": attempts,
                    "fingerprint": entry.get("fingerprint"),
                }
                log("ERROR", f"upload of {package.name} failed (attempt {attempts}): {error}")
                retry_at = _parse_time(ledger[package.name]["nextAttemptAt"]).astimezone()
                log("RETRY", f"{package.name}: next try at {retry_at:%H:%M} (or press Retry failed)")
            else:
                ledger[package.name] = {
                    "package": package.name,
                    "groupId": package.stem,
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
                done += 1
                speed = round((size / 1_000_000) / duration, 2) if duration > 0 else 0
                log(
                    "DONE",
                    f"{package.name} uploaded in {duration:.1f}s @ {speed} MB/s",
                )
                # UPLOADED is on disk before the summary and the move start, so
                # a crash inside either can never cause a second upload.
                atomic_json(ledger_path, ledger)
                self._after_upload(target, package, ledger[package.name])
            finally:
                with self._lock:
                    self._current = None
            # Written per package, not per sweep: a crash mid-sweep keeps what
            # already finished instead of re-uploading it.
            atomic_json(ledger_path, ledger)
        return done

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
            capture_id=package.stem,
            title=meta.get("Title") or None,
            image_count=upload_summary.image_count_from(meta, package),
            rework=upload_summary.normalize_rework(meta.get("Rework")),
            size_bytes=int(entry.get("size") or 0),
            duration_s=float(entry.get("uploadDuration") or 0),
            at=datetime.now(),
        )
        return utc_now().isoformat()

    def _upload_package(
        self, store: Any, target: UploadTarget, package: Path
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
            files = sorted(p for p in root.rglob("*") if p.is_file())
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
            if remote != size:
                log("VERIFY", f"{key}: bucket holds {remote} bytes, expected {size}")
                raise UploadError(f"{key}: the bucket holds {remote} bytes, expected {size}")
        return base, total, len(files)

    def retry_failed(self, config: Config) -> int:
        """Clears the back-off on every FAILED entry so the next sweep retries
        them. Returns how many were cleared."""
        path = self.ledger_path(config)
        ledger = self._load(path)
        cleared = 0
        for entry in ledger.values():
            if not isinstance(entry, dict) or not entry.get("nextAttemptAt"):
                continue
            if _needs_attention(entry):
                entry["nextAttemptAt"] = None
                cleared += 1
        if cleared:
            atomic_json(path, ledger)
            log("RETRY", f"cleared back-off on {cleared} failed package(s)")
        return cleared


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
    "S3Store",
    "UploadCoordinator",
    "UploadError",
    "UploadTarget",
    "move_to_done",
    "parse_s3_path",
    "upload_target",
    "utc_now",
]
