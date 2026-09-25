"""Client-rework republish must actually resend a corrected file.

Ported from QC's `tests/test_upload_reupload.py`, unchanged in substance:
`_upload_package` skips a PUT only when the bucket already holds an object of
the SAME SIZE *and* the SAME CONTENT (ETag vs local MD5, single-part only) as
the local file - a same-size rework correction must still go out.

Extended with this app's one new behaviour: a package whose ledger row is
UPLOADED but whose current *fingerprint* has changed (QC republished it under
the same Group ID) is treated as newly published by `scan_once` itself, not
just by `_upload_package`'s own content check - see the fingerprint tests
below, and `move_to_done`'s `replace=True` path.

unittest.TestCase so this runs under `python -m unittest` with nothing but the
shipped runtime wheels; pytest collects it too. No boto3 needed anywhere -
the store is faked.
"""

from __future__ import annotations

import hashlib
import json
import time
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from lwcam_upload.config import Config
from lwcam_upload.engine import UploadCoordinator, UploadTarget, move_to_done


class FakeStore:
    """Stands in for S3Store: a dict of key -> (size, etag), no network."""

    def __init__(self, objects: dict[str, tuple[int, str]] | None = None) -> None:
        self.objects = dict(objects or {})
        self.put_calls: list[str] = []

    def remote_info(self, key: str) -> tuple[int, str] | None:
        return self.objects.get(key)

    def remote_size(self, key: str) -> int | None:
        info = self.objects.get(key)
        return info[0] if info else None

    def put_file(self, path: Path, key: str) -> None:
        self.put_calls.append(key)
        data = path.read_bytes()
        self.objects[key] = (len(data), hashlib.md5(data).hexdigest())


def _target(root: Path, **overrides) -> UploadTarget:
    values = dict(
        bucket="bucket",
        prefix="",
        region=None,
        access_key="key",
        secret_key="secret",
        watch_root=root,
        done_root=None,
        summary_db=None,
    )
    values.update(overrides)
    return UploadTarget(**values)


def _config(root: Path, **overrides) -> Config:
    values = dict(
        watch_root=root,
        done_root=None,
        summary_root=None,
        enabled=True,
        s3_path="s3://bucket",
        s3_region="af-south-1",
        s3_access_key="key",
        s3_secret_key="secret",
        interval_seconds=60,
        state_file=root / "uploads.json",
        log_file=root / "upload.log",
        db_host="",
        db_port=5432,
        db_name="lwcam",
        db_user="",
        db_password="",
        db_use_ssl=False,
        ui_port=8091,
        ui_bind="0.0.0.0",
    )
    values.update(overrides)
    return Config(**values)


def _write_group_csv(package: Path, *, rework: str = "FALSE") -> None:
    csv_text = f"GroupID,Title,Total Artifacts,Rework\nG1,A Title,1,{rework}\n"
    if package.is_dir():
        (package / "GroupMetadataImage.csv").write_text(csv_text, encoding="utf-8")
    else:
        import zipfile

        with zipfile.ZipFile(package, "a") as archive:
            archive.writestr("GroupMetadataImage.csv", csv_text)


class ReuploadOnContentChangeTests(unittest.TestCase):
    def test_same_size_different_content_is_reuploaded(self) -> None:
        """The exact client-rework scenario: corrected CSV, same byte length,
        different content - must be PUT again, not skipped."""
        corrected = b"GroupID,Rework\nG1,TRUE,"
        rejected = b"GroupID,Rework\nG1,FALSE"
        self.assertEqual(len(corrected), len(rejected))
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(corrected)
            target = _target(root)
            key = target.key_for(package.name)
            store = FakeStore({key: (len(rejected), hashlib.md5(rejected).hexdigest())})

            UploadCoordinator()._upload_package(store, target, package)

            self.assertEqual(store.put_calls, [key])
            self.assertEqual(store.objects[key][1], hashlib.md5(corrected).hexdigest())

    def test_same_content_is_not_reuploaded(self) -> None:
        content = b"unchanged bytes"
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(content)
            target = _target(root)
            key = target.key_for(package.name)
            store = FakeStore({key: (len(content), hashlib.md5(content).hexdigest())})

            UploadCoordinator()._upload_package(store, target, package)

            self.assertEqual(store.put_calls, [])

    def test_multipart_etag_always_reuploads(self) -> None:
        """A multipart ETag ("<hash>-<partcount>") can't be checked against a
        plain MD5, so the size shortcut alone must not apply."""
        content = b"large-file-stand-in"
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(content)
            target = _target(root)
            key = target.key_for(package.name)
            store = FakeStore({key: (len(content), "deadbeef-2")})

            UploadCoordinator()._upload_package(store, target, package)

            self.assertEqual(store.put_calls, [key])

    def test_different_size_is_a_fast_negative_no_hash_needed(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(b"new longer content here")
            target = _target(root)
            key = target.key_for(package.name)
            store = FakeStore({key: (3, "irrelevant")})

            UploadCoordinator()._upload_package(store, target, package)

            self.assertEqual(store.put_calls, [key])


class FingerprintReworkTests(unittest.TestCase):
    """scan_once must notice a republished package on its own - QC no longer
    calls anything like the old `clear_upload_ledger_entry` for it."""

    def test_unchanged_folder_package_is_not_reuploaded(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1"
            package.mkdir()
            (package / "page1.tif").write_bytes(b"page one")
            config = _config(root)
            store = FakeStore()
            coordinator = UploadCoordinator(store_factory=lambda target: store)

            coordinator.scan_once(config)
            self.assertEqual(len(store.put_calls), 1)

            store.put_calls.clear()
            coordinator.scan_once(config)
            self.assertEqual(store.put_calls, [], "unchanged package must not be re-uploaded")

    def test_folder_package_republished_with_changed_content_is_reuploaded(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1"
            package.mkdir()
            page = package / "page1.tif"
            page.write_bytes(b"original bytes")
            _write_group_csv(package, rework="FALSE")
            config = _config(root)

            store = FakeStore()
            coordinator = UploadCoordinator(store_factory=lambda target: store)
            coordinator.scan_once(config)
            first_calls = list(store.put_calls)
            self.assertTrue(first_calls)  # uploaded once

            # QC republishes the same Group ID with corrected content and Rework=TRUE.
            store.put_calls.clear()
            page.write_bytes(b"corrected bytes, same length!")
            _write_group_csv(package, rework="TRUE")

            coordinator.scan_once(config)

            self.assertTrue(store.put_calls, "republished package must be uploaded again")
            ledger = json.loads(config.state_file.read_text(encoding="utf-8"))
            self.assertEqual(ledger["G1"]["status"], "UPLOADED")

    def test_zip_package_republished_with_same_size_but_new_mtime_is_reuploaded(self) -> None:
        """The zip fingerprint is `size|mtime_ns` - engineered here to the
        exact same total size across both writes (ZIP_STORED, same-length
        payloads), so only the mtime can be what scan_once notices."""
        import os
        import zipfile

        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("page1.tif", b"original bytes!!")
                archive.writestr("GroupMetadataImage.csv", "GroupID,Rework\nG1,FALSE\n")
            config = _config(root)

            store = FakeStore()
            coordinator = UploadCoordinator(store_factory=lambda target: store)
            coordinator.scan_once(config)
            self.assertTrue(store.put_calls)
            uploaded_size = package.stat().st_size

            store.put_calls.clear()
            with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_STORED) as archive:
                archive.writestr("page1.tif", b"corrected bytes!")
                archive.writestr("GroupMetadataImage.csv", "GroupID,Rework\nG1,TRUE \n")
            self.assertEqual(package.stat().st_size, uploaded_size, "test needs equal sizes")
            future = time.time() + 5
            os.utime(package, (future, future))

            coordinator.scan_once(config)

            self.assertTrue(store.put_calls, "republished zip must be uploaded again")

    def test_move_to_done_replaces_the_rejected_package_on_rework(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            done = root / "done"
            rejected = root / "old" / "G1"
            rejected.mkdir(parents=True)
            (rejected / "page1.tif").write_bytes(b"rejected")
            done.mkdir()
            (done / "G1").mkdir()
            (done / "G1" / "page1.tif").write_bytes(b"rejected")

            corrected = root / "G1"
            corrected.mkdir()
            (corrected / "page1.tif").write_bytes(b"corrected, different bytes")

            final = move_to_done(corrected, done, replace=True)

            self.assertEqual(final, done / "G1")
            self.assertEqual((final / "page1.tif").read_bytes(), b"corrected, different bytes")
            self.assertFalse(corrected.exists())

    def test_move_to_done_without_replace_refuses_a_conflicting_folder(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            done = root / "done"
            done.mkdir()
            (done / "G1").mkdir()
            (done / "G1" / "page1.tif").write_bytes(b"already there")

            package = root / "G1"
            package.mkdir()
            (package / "page1.tif").write_bytes(b"different content")

            from lwcam_upload.engine import UploadError

            with self.assertRaises(UploadError):
                move_to_done(package, done, replace=False)


if __name__ == "__main__":
    unittest.main()
