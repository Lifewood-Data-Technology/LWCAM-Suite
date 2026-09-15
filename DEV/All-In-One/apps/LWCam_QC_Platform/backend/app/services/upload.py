"""Upload phase: published export packages go to an S3 bucket.

Runs on the station whose Station Setup has "Run Upload on this PC" on - the
same PC that holds the export output folder, since that folder is what gets
uploaded. Like the export, it is a SWEEP rather than a hook: `publish_package`
makes a package visible by rename, so anything the sweep sees in the output
folder is complete, and a package that lands mid-sweep is picked up next time.

State lives in `.lwcam-export/uploads.json` beside the export's own ledgers,
keyed by package name. An entry is UPLOADED once every file has been PUT and
its size read back from the bucket matches the local file; anything short of
that is FAILED with an error, an attempt count and a back-off, and is retried
on a later sweep (or at once via the retry endpoint).

An UPLOADED package is then SUMMARISED - one row in Upload_Summary.db3 (see
upload_summary.py) with title, image count, size, speed, duration, local
date/time and Rework - and then MOVED out of the output folder into the "Uploaded"
folder (`upload_done_dir`, Station Setup), so the output folder holds only what
has not reached the bucket yet. The ledger row is written UPLOADED before the
move and gains `movedTo` after it, and the move itself is idempotent (see
`move_to_done`), so a crash at any point between resumes on the next sweep
without a second upload and without a half-moved package.

Crash safety, end to end: a package is only visible once the export renamed it
into place; every PUT is verified by size before the ledger says UPLOADED; the
ledger is written with the same fsynced atomic writer as the export's; a file
already in the bucket at the local size is never sent again; and a package in
the output folder that the ledger already calls UPLOADED is just moved. What
this does NOT cover is a multipart upload torn by a power cut mid-part: S3 keeps
those parts (billed) until aborted - set a bucket lifecycle rule
"AbortIncompleteMultipartUpload after 1 day" so they age out on their own.

The DB is deliberately not touched: `is_ingested` on capture_folders means the
downstream team consumed the group, which is not what an upload proves.
"""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable

from app.core.config import settings
from app.core.paths import fs_path
from app.services import upload_summary
from app.services.export import ExportError, runtime_config, utc_now
from app.services.ledger import JsonLedger, atomic_json
from app.services.sweep import PeriodicSweep

logger = logging.getLogger(__name__)

# Failed uploads wait attempts x this before the sweep tries again, capped.
RETRY_STEP = timedelta(minutes=5)
RETRY_CAP = timedelta(hours=1)


def _next_attempt(attempts: int) -> str:
    return (utc_now() + min(RETRY_STEP * attempts, RETRY_CAP)).isoformat()


class UploadError(RuntimeError):
    """Configuration or transfer problems, worded for the operator."""


@dataclass(frozen=True)
class UploadRuntimeConfig:
    bucket: str
    prefix: str
    region: str | None
    access_key: str
    secret_key: str
    output_dir: Path
    temp_dir: Path
    done_dir: Path | None = None
    summary_db: Path | None = None

    def key_for(self, *parts: str) -> str:
        return "/".join(part.strip("/") for part in (self.prefix, *parts) if part.strip("/"))


def parse_s3_path(value: str) -> tuple[str, str]:
    """`s3://bucket/optional/prefix` -> (bucket, prefix). Prefix may be empty."""
    text = (value or "").strip()
    if not text.lower().startswith("s3://"):
        raise UploadError("The S3 path must start with s3://")
    bucket, _, prefix = text[5:].strip("/").partition("/")
    if not bucket:
        raise UploadError("The S3 path names no bucket")
    return bucket, prefix.strip("/")


def upload_runtime_config() -> UploadRuntimeConfig:
    """Everything one sweep needs, or an UploadError saying what is missing.

    Reads the export's runtime config too: the output folder IS the upload
    source, so an unconfigured export means nothing to upload from.
    """
    bucket, prefix = parse_s3_path(settings.upload_s3_path)
    access_key = settings.upload_s3_access_key.strip()
    secret = settings.upload_s3_secret_key.get_secret_value().strip() if settings.upload_s3_secret_key else ""
    missing = [
        name
        for name, value in (("access key", access_key), ("secret key", secret))
        if not value
    ]
    if missing:
        raise UploadError(f"The S3 {' and '.join(missing)} must be set in Station Setup")
    export = runtime_config()
    done_dir: Path | None = None
    done_value = settings.upload_done_dir.strip()
    if done_value:
        done_dir = Path(done_value).expanduser()
        # Inside the output folder it would be listed as a package itself and
        # re-uploaded forever; equal to it and the move is a no-op that then
        # deletes the source.
        if _same_or_inside(done_dir, export.output_dir):
            raise UploadError(
                "The Uploaded folder must be outside the QC output folder"
            )
    summary_value = settings.upload_summary_dir.strip()
    summary_db = (
        Path(summary_value).expanduser() / upload_summary.SUMMARY_FILE
        if summary_value
        else None
    )
    return UploadRuntimeConfig(
        bucket=bucket,
        prefix=prefix,
        region=settings.upload_s3_region.strip() or None,
        access_key=access_key,
        secret_key=secret,
        output_dir=export.output_dir,
        temp_dir=export.temp_dir,
        done_dir=done_dir,
        summary_db=summary_db,
    )


def _same_or_inside(candidate: Path, root: Path) -> bool:
    # resolve() follows junctions and expands 8.3 short names, so a done
    # folder aliased into the output folder is still caught.
    try:
        a, b = candidate.resolve(), root.resolve()
    except OSError:
        return False
    return a == b or a.is_relative_to(b)


def _package_files(package: Path) -> dict[str, int]:
    """Relative path -> size for a folder package, or {name: size} for a ZIP."""
    if fs_path(package).is_dir():
        # Walked from the prefixed root, so relative_to(root) - not the
        # possibly-unprefixed `package` - is what the children can match.
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


def _is_rework_package(package: Path) -> bool:
    """Whether this package says it is a client rework.

    Read from the package's own GroupMetadataImage.csv - the same Rework value
    the summary row uses - rather than from the ledger, so it is known even on a
    station with no Upload Summary database configured, where that step is
    skipped entirely.

    Best effort: an unreadable CSV means "not a rework", which keeps the
    existing refusal-to-overwrite rather than making a bad read destructive.
    """
    try:
        meta = upload_summary.read_group_metadata(package)
    except Exception:  # noqa: BLE001 - a bad read must not decide to overwrite
        return False
    # Compared to the text, NOT bool(): normalize_rework returns the CSV's own
    # "TRUE"/"FALSE" strings, and bool("FALSE") is True - which would have made
    # every package look like a rework and overwrite unconditionally.
    return upload_summary.normalize_rework(meta.get("Rework")) == "TRUE"


def move_to_done(package: Path, done_dir: Path, *, replace: bool = False) -> Path:
    """Moves an uploaded package into the Uploaded folder. Idempotent.

    Same volume: one atomic rename straight to the final name - a staging
    step in between would leave a crash-stranded dot-file that no sweep ever
    lists again. Other volume: copy into staging, verify every file's size,
    rename to final, THEN delete the source. So at every crash point the
    source is either intact or already fully at the final name - never
    half-copied under the final name, never deleted before the copy was
    proven. A final that already exists and matches the source (the crash
    came between the rename and the delete) just has its source removed; one
    that does not match is a conflict and is left alone.
    """
    fs_path(done_dir).mkdir(parents=True, exist_ok=True)
    final = done_dir / package.name
    partial = done_dir / f".{package.name}.moving"
    if fs_path(final).exists():
        if replace:
            # A client rework republishes under the SAME Group ID, so what is
            # here is the version the client rejected and the bucket has just
            # been overwritten with the corrected one. This folder mirrors what
            # was sent, so it follows.
            #
            # Replaced WITHOUT comparing first: _package_files compares names
            # and sizes, and two versions of a page can differ while measuring
            # the same - which would keep the rejected package and quietly
            # disagree with the bucket.
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

    boto3 is imported here rather than at module import so the backend still
    starts (and the tests still run) on a checkout without the wheel; the
    scheduler only constructs one of these when upload is enabled.
    """

    def __init__(self, config: UploadRuntimeConfig) -> None:
        self._config = config
        self._client: Any = None

    def _s3(self) -> Any:
        if self._client is None:
            import boto3
            from botocore.config import Config

            self._client = boto3.client(
                "s3",
                region_name=self._config.region,
                aws_access_key_id=self._config.access_key,
                aws_secret_access_key=self._config.secret_key,
                config=Config(retries={"max_attempts": 5, "mode": "standard"}),
            )
        return self._client

    def remote_size(self, key: str) -> int | None:
        """The object's size in the bucket, or None when it is not there."""
        info = self.remote_info(key)
        return info[0] if info else None

    def remote_info(self, key: str) -> tuple[int, str] | None:
        """(size, ETag) of the object in the bucket, or None when it is not
        there. One HEAD call serves both - callers that only need the size
        (the post-PUT verification) just read [0]."""
        from botocore.exceptions import ClientError

        try:
            head = self._s3().head_object(Bucket=self._config.bucket, Key=key)
        except ClientError as error:
            code = str(error.response.get("Error", {}).get("Code", ""))
            if code in {"404", "NoSuchKey", "NotFound"}:
                return None
            raise
        return int(head["ContentLength"]), str(head.get("ETag") or "").strip('"')

    def put_file(self, path: Path, key: str) -> None:
        # upload_file switches to multipart above 8 MB on its own, so a
        # multi-gigabyte ZIP needs nothing special here.
        self._s3().upload_file(str(path), self._config.bucket, key)


StoreFactory = Callable[[UploadRuntimeConfig], Any]


class UploadCoordinator:
    def __init__(self, store_factory: StoreFactory = S3Store) -> None:
        self._store_factory = store_factory
        self._lock = threading.RLock()
        self._current: dict[str, Any] | None = None

    # Ledger

    @staticmethod
    def ledger_path(config: UploadRuntimeConfig) -> Path:
        return config.temp_dir / ".lwcam-export" / "uploads.json"

    @staticmethod
    def _load(path: Path) -> dict[str, Any]:
        return JsonLedger(path).load()

    @staticmethod
    def packages(output_dir: Path) -> list[Path]:
        """Published packages: `<GroupID>.zip` files or `<GroupID>/` folders.

        Dot-prefixed entries are the export's own staging and state and never
        packages. Both forms can coexist if a project switched output format.
        """
        if not fs_path(output_dir).is_dir():
            return []
        # Walked from the prefixed root, so every listed package already
        # carries the extended-length form; downstream fs_path() calls on it
        # are no-ops, and only .name/.stem/.suffix (unaffected by the prefix)
        # ever reach the ledger, DB, or a response.
        found = [
            path
            for path in fs_path(output_dir).iterdir()
            if not path.name.startswith(".")
            and (path.is_dir() or path.suffix.lower() == ".zip")
        ]
        return sorted(found, key=lambda path: path.name)

    # Reporting

    def status(self) -> dict[str, Any]:
        """What the Exports screen shows. Never raises: a broken setup is a
        message here, not an error page."""
        result: dict[str, Any] = {
            "enabled": bool(settings.upload_enabled),
            "problem": None,
            "bucket": None,
            "prefix": None,
            "uploadedCount": 0,
            "pending": [],
            "current": None,
            "failures": [],
            "recent": [],
        }
        try:
            config = upload_runtime_config()
        except (UploadError, ExportError) as error:
            if result["enabled"]:
                result["problem"] = str(error)
            return result
        result.update(bucket=config.bucket, prefix=config.prefix)
        result["doneDir"] = str(config.done_dir) if config.done_dir else None
        ledger = self._load(self.ledger_path(config))
        uploaded = [e for e in ledger.values() if isinstance(e, dict) and e.get("status") == "UPLOADED"]
        # An uploaded package whose summary row or move keeps failing is a
        # failure the operator has to see, even though the bytes are safe.
        failed = [
            # One `error` field whatever step failed, so the screen has a
            # reason to show without knowing the ledger's key names.
            {**e, "error": e.get("error") or e.get("moveError") or e.get("summaryError")}
            for e in ledger.values()
            if isinstance(e, dict) and _needs_attention(e)
        ]
        uploaded.sort(key=lambda e: str(e.get("uploadedAt") or ""), reverse=True)
        failed.sort(key=lambda e: str(e.get("failedAt") or ""), reverse=True)
        # A package already listed as uploaded or failed is not also pending;
        # the client polls while anything is pending, so a failed package in
        # back-off must not keep it polling for an hour.
        listed = {str(e.get("package")) for e in (*uploaded, *failed)}
        with self._lock:
            current = dict(self._current) if self._current else None
        result.update(
            uploadedCount=len(uploaded),
            pending=[p.name for p in self.packages(config.output_dir) if p.name not in listed],
            current=current,
            failures=failed,
            recent=uploaded[:10],
        )
        return result

    # The sweep

    def scan_once(self) -> int:
        """Uploads every package not yet recorded as UPLOADED. Returns how many
        finished this pass. Raises UploadError/ExportError when unconfigured."""
        config = upload_runtime_config()
        ledger_path = self.ledger_path(config)
        ledger = self._load(ledger_path)
        store = self._store_factory(config)
        now = utc_now()
        done = 0
        for package in self.packages(config.output_dir):
            entry = ledger.get(package.name) if isinstance(ledger.get(package.name), dict) else {}
            next_at = entry.get("nextAttemptAt")
            if next_at and _parse_time(next_at) > now:
                continue
            if entry.get("status") == "UPLOADED":
                # In the bucket already; still here because the summary row or
                # the move did not happen (not configured then, or a crash).
                if self._after_upload(config, package, entry):
                    atomic_json(ledger_path, ledger)
                continue
            attempts = int(entry.get("attempts") or 0) + 1
            with self._lock:
                self._current = {"package": package.name, "startedAt": utc_now().isoformat()}
            try:
                started = time.perf_counter()
                key, size, files = self._upload_package(store, config, package)
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
                }
                logger.warning("Upload of %s failed (attempt %s): %s", package.name, attempts, error)
            else:
                ledger[package.name] = {
                    "package": package.name,
                    "groupId": package.stem,
                    "status": "UPLOADED",
                    "key": key,
                    "size": size,
                    "files": files,
                    "uploadedAt": utc_now().isoformat(),
                    "uploadDuration": round(duration, 3),
                    "attempts": attempts,
                    "summaryAt": None,
                    "movedTo": None,
                }
                done += 1
                logger.info("Uploaded %s to s3://%s/%s", package.name, config.bucket, key)
                # UPLOADED is on disk before the summary and the move start, so
                # a crash inside either can never cause a second upload.
                atomic_json(ledger_path, ledger)
                self._after_upload(config, package, ledger[package.name])
            finally:
                with self._lock:
                    self._current = None
            # Written per package, not per sweep: a crash mid-sweep keeps what
            # already finished instead of re-uploading it.
            atomic_json(ledger_path, ledger)
        return done

    def _after_upload(
        self, config: UploadRuntimeConfig, package: Path, entry: dict[str, Any]
    ) -> bool:
        """Summary row first, then the move. A failed summary skips the move so
        the package stays in the output folder, where the next sweep finds it
        and retries both in order - the CSV the summary needs is still there.
        Returns whether `entry` changed, so the caller rewrites the ledger only
        when it did."""
        summary_db, done_dir = config.summary_db, config.done_dir
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
            # The package declares its own status: Rework=TRUE in
            # GroupMetadataImage.csv, the same value the summary row above just
            # read. A reworked package replaces the one already in the Uploaded
            # folder, because the bucket has just been overwritten with it.
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
        off, which is what the Exports screen lists with the failures.
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
            logger.warning(
                "%s of %s failed (attempt %s): %s", prefix, entry.get("package"), attempts, error
            )
            return False
        entry.update({done_key: value, f"{prefix}Error": None, "nextAttemptAt": None})
        entry.pop(f"{prefix}Attempts", None)
        logger.info("%s of %s done: %s", prefix, entry.get("package"), value)
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
        self, store: Any, config: UploadRuntimeConfig, package: Path
    ) -> tuple[str, int, int]:
        """PUTs one package and proves every file arrived at its local size.

        A ZIP is one object at `<prefix>/<GroupID>.zip`; a folder package keeps
        its layout under `<prefix>/<GroupID>/`. A file already in the bucket
        with the SAME CONTENT is skipped - not just the same size - which is
        what makes a retry after a crash resume rather than restart, without
        also skipping a same-length client-rework correction (a corrected CSV
        replacing a rejected one is exactly the same size more often than not).
        Content is proven by ETag vs local MD5 when the object is single-part
        (no "-" in the ETag); a multipart or missing ETag can't be compared
        this cheaply, so it always re-uploads.
        """
        if fs_path(package).is_dir():
            # Walked from the prefixed root, so relative_to(root) is what
            # the yielded children can actually match.
            root = fs_path(package)
            files = sorted(p for p in root.rglob("*") if p.is_file())
            base = config.key_for(package.name)
            keys = [config.key_for(package.name, p.relative_to(root).as_posix()) for p in files]
        else:
            files = [fs_path(package)]
            base = config.key_for(package.name)
            keys = [base]
        if not files:
            raise UploadError("The package is empty")
        total = 0
        for path, key in zip(files, keys, strict=True):
            size = path.stat().st_size
            total += size
            info = store.remote_info(key)
            # Size mismatch is a fast negative - definitely different, no need
            # to hash. A size match is NOT proof of the same content, so it
            # only short-circuits the re-upload when the ETag confirms it.
            if info is not None and info[0] == size and _same_content(info[1], path):
                continue
            store.put_file(path, key)
            remote = store.remote_size(key)
            if remote != size:
                raise UploadError(f"{key}: the bucket holds {remote} bytes, expected {size}")
        return base, total, len(files)

    def retry_failed(self) -> int:
        """Clears the back-off on every FAILED entry so the next sweep retries
        them. Returns how many were cleared."""
        config = upload_runtime_config()
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


upload_coordinator = UploadCoordinator()

# Sweeps the output folder on a timer while upload is on; `kick()` wakes it
# early after a retry. An UploadError/ExportError means "not configured yet"
# and is logged without a traceback.
upload_scheduler = PeriodicSweep(
    "lwcam-upload",
    tick=upload_coordinator.scan_once,
    interval=lambda: settings.upload_interval_seconds,
    enabled=lambda: bool(settings.upload_enabled),
    expected=(UploadError, ExportError),
)

__all__ = [
    "S3Store",
    "UploadCoordinator",
    "UploadError",
    "UploadRuntimeConfig",
    "move_to_done",
    "parse_s3_path",
    "upload_coordinator",
    "upload_runtime_config",
    "upload_scheduler",
]
