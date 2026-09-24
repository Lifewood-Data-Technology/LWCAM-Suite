"""Client-rework republish must actually resend a corrected file.

`_upload_package` used to skip the PUT whenever the bucket already held an
object of the SAME SIZE as the local file. A client-rework correction (a
fixed CSV or metadata file replacing a rejected one) is frequently the exact
same length, so the old check left the rejected bytes in the bucket beside
the corrected TIFFs - the republish silently did nothing for that file.

The fix compares content via ETag vs local MD5 (S3's ETag is the object's MD5
for a single-part PUT), falling back to "always upload" when the ETag is
multipart or missing, since that can't be verified this cheaply.

unittest.TestCase so this runs under `python -m unittest` with nothing but
the shipped runtime wheels; pytest collects it too. No boto3 needed - the
store is faked.
"""

from __future__ import annotations

import hashlib
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from app.services.upload import UploadCoordinator, UploadRuntimeConfig


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


def _config(root: Path) -> UploadRuntimeConfig:
    return UploadRuntimeConfig(
        bucket="bucket",
        prefix="",
        region=None,
        access_key="key",
        secret_key="secret",
        output_dir=root,
        temp_dir=root,
    )


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
            config = _config(root)
            key = config.key_for(package.name)
            store = FakeStore({key: (len(rejected), hashlib.md5(rejected).hexdigest())})

            UploadCoordinator()._upload_package(store, config, package)

            self.assertEqual(store.put_calls, [key])
            self.assertEqual(store.objects[key][1], hashlib.md5(corrected).hexdigest())

    def test_same_content_is_not_reuploaded(self) -> None:
        content = b"unchanged bytes"
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(content)
            config = _config(root)
            key = config.key_for(package.name)
            store = FakeStore({key: (len(content), hashlib.md5(content).hexdigest())})

            UploadCoordinator()._upload_package(store, config, package)

            self.assertEqual(store.put_calls, [])

    def test_multipart_etag_always_reuploads(self) -> None:
        """A multipart ETag ("<hash>-<partcount>") can't be checked against a
        plain MD5, so the size shortcut alone must not apply."""
        content = b"large-file-stand-in"
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(content)
            config = _config(root)
            key = config.key_for(package.name)
            store = FakeStore({key: (len(content), "deadbeef-2")})

            UploadCoordinator()._upload_package(store, config, package)

            self.assertEqual(store.put_calls, [key])

    def test_different_size_is_a_fast_negative_no_hash_needed(self) -> None:
        with TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "G1.zip"
            package.write_bytes(b"new longer content here")
            config = _config(root)
            key = config.key_for(package.name)
            store = FakeStore({key: (3, "irrelevant")})

            UploadCoordinator()._upload_package(store, config, package)

            self.assertEqual(store.put_calls, [key])


if __name__ == "__main__":
    unittest.main()
