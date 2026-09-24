"""The delivery contract for pixels leaving the QC engine.

FamilySearch rejected the Taiping project's first delivery for "evidence of
image enhancement ... any compression, sharpening, or other image enhancement".
The cause was upstream in LWIP, but the engine had two problems of its own that
would have re-introduced it: the deferred-ops baker re-encoded at quality 95
with 4:2:0 chroma and dropped all metadata, and the TIFF export discarded the
capture's provenance. These tests pin both, plus the luminance guard.

Written as unittest.TestCase so they run under `python -m unittest` with nothing
but the shipped runtime wheels, and are still collected by the project's pytest.
"""

from __future__ import annotations

import csv
import unittest
from datetime import date
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from PIL import Image, JpegImagePlugin

from app.core.config import settings
from app.core.errors import ApiCodes, BusinessError
from app.services import export
from app.routers.qc import apply_pending_ops, assert_luminance_enabled
from app.services.export import (
    ARTIFACT_CSV_NAME,
    GROUP_CSV_NAME,
    ExportRuntimeConfig,
    FolderExportSnapshot,
    ImageSource,
    build_export_zip,
    convert_to_jpeg,
    convert_to_tiff,
    sanitise_tiff_tag,
    verify_published_folder,
)


GPS_IFD = 0x8825
PREDICTOR = 317
MAKE = 0x010F
MODEL = 0x0110
DATETIME = 0x0132


def strip_bytes(path: Path) -> bytes:
    """The compressed image data itself, read past the tags.

    Two TIFFs that differ only in a declared-but-unapplied predictor would carry
    identical strips; this is what makes that distinguishable from one where the
    transform actually ran.
    """
    with Image.open(path) as artifact:
        offsets = artifact.tag_v2[273]
        counts = artifact.tag_v2[279]
    raw = path.read_bytes()
    return b"".join(raw[o:o + c] for o, c in zip(offsets, counts))


def write_capture(path: Path, *, size: tuple[int, int] = (900, 1200)) -> None:
    """A stand-in for what LWIP hands the engine: q100 4:4:4, EXIF, ICC."""
    frame = Image.new("RGB", size, (232, 230, 224))
    # Some structure, so a resample has something to lose.
    for x in range(0, size[0], 9):
        for y in range(0, size[1], 3):
            frame.putpixel((x, y), (24, 22, 20))

    exif = Image.Exif()
    exif[MAKE] = "Xiaomi"
    exif[MODEL] = "Xiaomi 14 Ultra"
    exif[DATETIME] = "2026:08:04 14:29:30"
    frame.save(
        path,
        format="JPEG",
        quality=100,
        subsampling=0,
        exif=exif,
        icc_profile=b"\x00" * 128,
    )


class ApplyPendingOpsTests(unittest.TestCase):
    """The one re-encode in the backend that reaches the client."""

    def test_reencode_matches_a_camera_grade_encode(self) -> None:
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            write_capture(page)

            apply_pending_ops(page, [{"op": "deskew", "degrees": 1.5}])

            with Image.open(page) as baked:
                tables = baked.quantization
                sampling = JpegImagePlugin.get_sampling(baked)
            # All-1 tables are what the capture phone writes. At the previous
            # quality of 95 the maxima were 12 and 10.
            for table in tables.values():
                self.assertEqual(max(table), 1)
            # 0 is 4:4:4. Pillow's DEFAULT is 4:2:0, which silently halved the
            # colour resolution of every page a reviewer touched.
            self.assertEqual(sampling, 0)

    def test_metadata_survives_the_bake(self) -> None:
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            write_capture(page)

            apply_pending_ops(page, [{"op": "crop", "rect": [0.1, 0.1, 0.9, 0.9]}])

            with Image.open(page) as baked:
                carried = baked.getexif()
                icc = baked.info.get("icc_profile")
            self.assertEqual(carried.get(MAKE), "Xiaomi")
            self.assertEqual(carried.get(MODEL), "Xiaomi 14 Ultra")
            self.assertEqual(carried.get(DATETIME), "2026:08:04 14:29:30")
            self.assertTrue(icc)

    def test_orientation_is_not_applied_twice(self) -> None:
        """exif_transpose bakes the rotation into the pixels and clears the tag.

        Carrying the SOURCE's EXIF back onto the result would restore an
        orientation already applied, and every viewer would turn the page a
        second time. The metadata must come off the transposed frame.
        """
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            write_capture(page, size=(900, 1200))
            with Image.open(page) as frame:
                copy = frame.copy()
                exif = frame.getexif()
            exif[0x0112] = 6  # "rotate 90 CW on display"
            copy.save(page, format="JPEG", quality=100, subsampling=0, exif=exif)

            apply_pending_ops(page, [{"op": "crop", "rect": [0.0, 0.0, 1.0, 1.0]}])

            with Image.open(page) as baked:
                orientation = baked.getexif().get(0x0112)
                size = baked.size
            # Pixels were turned, so the frame is now landscape...
            self.assertEqual(size, (1200, 900))
            # ...and the tag must not ask for the turn to happen again.
            self.assertIn(orientation, (None, 1))

    def test_no_ops_leaves_the_file_untouched(self) -> None:
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            write_capture(page)
            before = page.read_bytes()

            apply_pending_ops(page, [])

            self.assertEqual(page.read_bytes(), before)


class ConvertToTiffTests(unittest.TestCase):
    def test_a_capture_with_exif_converts_rather_than_raising(self) -> None:
        """Regression: handing TIFF the JPEG EXIF blob CRASHES.

        `frame.save(..., format="TIFF", exif=<APP1 bytes>)` makes libtiff reject
        the block's ExifIFD pointer ("Bad LONG8 or IFD8 value ... for
        EXIFIFDOffset") and raises, which would have failed every export of
        every folder. Provenance has to be copied tag by tag instead.
        """
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            target = Path(temporary) / "page.tif"
            write_capture(page)

            width, height = convert_to_tiff(page, target)

            self.assertEqual((width, height), (900, 1200))
            self.assertTrue(target.is_file())

    def test_provenance_and_compression_reach_the_artifact(self) -> None:
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            target = Path(temporary) / "page.tif"
            write_capture(page)

            convert_to_tiff(page, target)

            with Image.open(target) as artifact:
                tags = artifact.tag_v2
                icc = artifact.info.get("icc_profile")
            self.assertIn(tags.get(259), (8, 32946), "must stay adobe_deflate")
            self.assertEqual(tags.get(MAKE), "Xiaomi")
            self.assertEqual(tags.get(MODEL), "Xiaomi 14 Ultra")
            self.assertEqual(tags.get(DATETIME), "2026:08:04 14:29:30")
            self.assertTrue(icc)

    def test_the_predictor_is_recorded_and_provenance_survives_it(self) -> None:
        """Tag 317 has to arrive WITH the camera tags, not instead of them.

        Pillow takes a single `tiffinfo`, so the predictor is written into the
        same directory the provenance tags are assembled in. Passing it as its
        own dict silently replaces that directory, and the delivery loses the
        capture identity again - the exact regression this module exists for.
        """
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            target = Path(temporary) / "page.tif"
            write_capture(page)

            convert_to_tiff(page, target)

            with Image.open(target) as artifact:
                tags = artifact.tag_v2
                icc = artifact.info.get("icc_profile")
            self.assertEqual(tags.get(PREDICTOR), 2, "horizontal differencing")
            self.assertIn(tags.get(259), (8, 32946), "must stay adobe_deflate")
            self.assertEqual(tags.get(MAKE), "Xiaomi")
            self.assertEqual(tags.get(MODEL), "Xiaomi 14 Ultra")
            self.assertTrue(icc)

    def test_the_predictor_is_applied_and_not_merely_declared(self) -> None:
        """Written tag, unwritten effect, is the failure this guards against.

        Compared against predictor 1 - TIFF's own "no prediction", not a second
        code path - so the two files differ in exactly one thing. If the tag were
        declared but the transform skipped, the compressed strips would be byte
        identical; they must not be. And it has to be reversible, so both files
        decode to the same pixels, which are the capture's own.

        Size is deliberately NOT asserted. The gain is content dependent: the
        delivered camera pages measured -16% to -37%, but this module's synthetic
        fixture, once round-tripped through JPEG, gets slightly LARGER. Pinning a
        byte count here would pin the fixture, not the behaviour.
        """
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            predicted = Path(temporary) / "predicted.tif"
            plain = Path(temporary) / "plain.tif"
            write_capture(page)

            convert_to_tiff(page, predicted)
            with patch.object(export, "TIFF_PREDICTOR_HORIZONTAL", 1):
                convert_to_tiff(page, plain)

            self.assertNotEqual(strip_bytes(predicted), strip_bytes(plain))
            with Image.open(predicted) as a, Image.open(plain) as b, Image.open(page) as source:
                self.assertEqual(a.tobytes(), b.tobytes(), "predictor is reversible")
                # And the delivery still matches the capture it came from: a
                # page with no ops is the camera's pixels, predictor or not.
                self.assertEqual(a.tobytes(), source.convert(a.mode).tobytes())

    def test_gps_never_reaches_the_artifact(self) -> None:
        """LWIP strips GPS, and nothing here may put it back.

        It pins the building the records were photographed in and travels to the
        client inside every page.
        """
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            target = Path(temporary) / "page.tif"
            write_capture(page)
            with Image.open(page) as frame:
                copy = frame.copy()
                exif = frame.getexif()
            exif[GPS_IFD] = {1: "N", 2: (4.0, 51.0, 0.0)}
            copy.save(page, format="JPEG", quality=100, subsampling=0, exif=exif)

            convert_to_tiff(page, target)

            with Image.open(target) as artifact:
                self.assertNotIn(GPS_IFD, artifact.tag_v2)


class MalformedMetadataTests(unittest.TestCase):
    """A page LWIP never saw must not be able to fail a delivery.

    Found on a station 2026-09-09: a page INSERTED during QC carried
    Orientation 0 - Xiaomi writes a literal 0, which is not a legal value.
    libtiff refuses it, Pillow reports only `RuntimeError: Error setting from
    dictionary` with no tag named, and the whole folder's export failed. The
    auto-export sweep then retried on a doubling backoff and failed every time,
    so the batch would never have shipped.

    Every CAPTURED page was fine, because LWIP normalises the same tag on the
    way through. Nothing had corrected an inserted one.
    """

    def _page(self, directory: Path, orientation: int | None) -> Path:
        page = directory / "page.jpg"
        image = Image.new("RGB", (48, 32), (90, 120, 150))
        exif = image.getexif()
        exif[MAKE] = "Xiaomi"
        if orientation is not None:
            exif[0x0112] = orientation
        image.save(page, format="JPEG", quality=100, subsampling=0, exif=exif.tobytes())
        return page

    def test_illegal_orientation_zero_still_exports(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "out.tif"
            convert_to_tiff(self._page(directory, 0), target)
            with Image.open(target) as artifact:
                # Corrected, not dropped: the pixels are upright, so 1 is true.
                self.assertEqual(artifact.tag_v2.get(0x0112), 1)

    def test_a_legal_orientation_is_carried_unchanged(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            target = directory / "out.tif"
            convert_to_tiff(self._page(directory, 6), target)
            with Image.open(target) as artifact:
                self.assertEqual(artifact.tag_v2.get(0x0112), 6)

    def test_export_does_not_alter_pixels(self) -> None:
        """The whole point: this fix is metadata only."""
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            page = self._page(directory, 0)
            target = directory / "out.tif"
            convert_to_tiff(page, target)
            with Image.open(page) as source, Image.open(target) as artifact:
                self.assertEqual(
                    source.convert("RGB").tobytes(), artifact.convert("RGB").tobytes()
                )

    def test_sanitiser_rejects_what_libtiff_would(self) -> None:
        self.assertEqual(sanitise_tiff_tag(0x0112, 0), 1)
        self.assertEqual(sanitise_tiff_tag(0x0112, 99), 1)
        self.assertEqual(sanitise_tiff_tag(0x0112, 4), 4)
        self.assertIsNone(sanitise_tiff_tag(0x0112, "not a number"))
        self.assertIsNone(sanitise_tiff_tag(282, 0))
        self.assertEqual(sanitise_tiff_tag(282, 72.0), 72.0)
        # A tag with no constraint travels untouched.
        self.assertEqual(sanitise_tiff_tag(MAKE, "Xiaomi"), "Xiaomi")

    def test_ops_flush_normalises_orientation_and_drops_gps(self) -> None:
        """The other half: fix the working file, not just the artifact."""
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            page = directory / "edit.jpg"
            image = Image.new("RGB", (60, 40), (10, 20, 30))
            exif = image.getexif()
            exif[MAKE] = "Xiaomi"
            exif[0x0112] = 0
            # GPSLatitudeRef only: an ASCII tag, so the fixture does not depend
            # on Pillow's rational packing (which cannot serialise a raw tuple).
            exif[GPS_IFD] = {1: "N"}
            image.save(page, format="JPEG", quality=100, subsampling=0, exif=exif.tobytes())

            apply_pending_ops(page, [{"type": "rotate", "degrees": 90}])

            with Image.open(page) as edited:
                tags = edited.getexif()
                self.assertEqual(tags.get(0x0112), 1)
                self.assertNotIn(GPS_IFD, tags)
                self.assertEqual(tags.get(MAKE), "Xiaomi")
                self.assertEqual(JpegImagePlugin.get_sampling(edited), 0)


class ConvertToJpegTests(unittest.TestCase):
    """Toggle OFF: the JPEG sibling of ConvertToTiffTests.

    An op-free page's losslessness has to be PROVABLE by comparing bytes, not
    by eyeballing a quality=100 re-save - a decode/re-encode round trip is
    never truly identical even at the highest setting, which is exactly the
    defect that got the Taiping batches rejected in the first place.
    """

    def test_op_free_page_is_byte_identical_to_the_source(self) -> None:
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            target = Path(temporary) / "page_out.jpg"
            write_capture(page)

            convert_to_jpeg(page, target)

            self.assertEqual(target.read_bytes(), page.read_bytes())

    def test_page_with_ops_is_q100_444_carries_exif_icc_no_gps(self) -> None:
        with TemporaryDirectory() as temporary:
            page = Path(temporary) / "page.jpg"
            target = Path(temporary) / "page_out.jpg"
            write_capture(page)
            with Image.open(page) as frame:
                copy = frame.copy()
                exif = frame.getexif()
            exif[GPS_IFD] = {1: "N", 2: (4.0, 51.0, 0.0)}
            copy.save(
                page,
                format="JPEG",
                quality=100,
                subsampling=0,
                exif=exif,
                icc_profile=b"\x00" * 128,
            )

            convert_to_jpeg(page, target, [{"op": "rotate", "degrees": 90.0}])

            with Image.open(target) as artifact:
                tables = artifact.quantization
                sampling = JpegImagePlugin.get_sampling(artifact)
                tags = artifact.getexif()
                icc = artifact.info.get("icc_profile")
            for table in tables.values():
                self.assertEqual(max(table), 1)
            self.assertEqual(sampling, 0)
            self.assertEqual(tags.get(MAKE), "Xiaomi")
            self.assertNotIn(GPS_IFD, tags)
            self.assertTrue(icc)


class ExportZipToggleTests(unittest.TestCase):
    """build_export_zip with the toggle off: a mix of edited and untouched
    pages, both extensions right, and verification agreeing they are .jpg -
    the two independent reconstructions (verify_published_folder here,
    verify_published_zip when zipped) are exactly what would otherwise fail
    every JPEG export with publishedFolderInvalid / publishedZipInvalid."""

    def _metadata(self) -> dict:
        return {
            "clientRework": False,
            "title": "All Saints",
            "place": "Taiping",
            "startDate": "1877",
            "endDate": "1927",
            "recordType": "Cemetery Records",
            "language": "English",
            "recordCustodian": "All Saints' Church",
            "archivalRefNo": "",
            "captureOperatorName": "op",
            "captureOperatorId": "op-1",
            "volume": "1",
            "digitizingEntity": "Lifewood",
        }

    def test_mixed_pages_export_as_jpeg_and_verify(self) -> None:
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            untouched = root / "untouched.jpg"
            edited = root / "edited.jpg"
            write_capture(untouched)
            write_capture(edited)
            sources = [
                ImageSource(
                    id=1,
                    name=untouched.name,
                    path=untouched,
                    size=untouched.stat().st_size,
                    mtime_ns=untouched.stat().st_mtime_ns,
                    ops=[],
                ),
                ImageSource(
                    id=2,
                    name=edited.name,
                    path=edited,
                    size=edited.stat().st_size,
                    mtime_ns=edited.stat().st_mtime_ns,
                    ops=[{"op": "rotate", "degrees": 90.0}],
                ),
            ]
            snapshot = FolderExportSnapshot(
                folder_id=1,
                project_id=1,
                ingest_project_id="P1",
                location_code="MY",
                metadata=self._metadata(),
                images=sources,
                source_user_id="op",
                source_date=date(2026, 8, 4),
            )

            with (
                patch.object(settings, "export_zip_output", False),
                patch.object(settings, "export_tiff_output", False, create=True),
            ):
                config = ExportRuntimeConfig(
                    temp_dir=root,
                    output_dir=root,
                    encoding="utf-8",
                    line_ending_name="LF",
                    line_ending="\n",
                    tiff_output=settings.export_tiff_output,
                    zip_output=settings.export_zip_output,
                )
                package = build_export_zip(snapshot, "GROUP", "run", config)

                artifacts_dir = package.path / "artifacts"
                names = sorted(entry.name for entry in artifacts_dir.iterdir())
                self.assertEqual(names, ["GROUP_Image0001.jpg", "GROUP_Image0002.jpg"])
                self.assertEqual(
                    (artifacts_dir / "GROUP_Image0001.jpg").read_bytes(),
                    untouched.read_bytes(),
                )
                with (package.path / GROUP_CSV_NAME).open(encoding="utf-8") as handle:
                    self.assertTrue(list(csv.DictReader(handle)))
                with (package.path / ARTIFACT_CSV_NAME).open(encoding="utf-8") as handle:
                    rows = list(csv.DictReader(handle))
                self.assertEqual(
                    [row["Filename"] for row in rows],
                    ["GROUP_Image0001.jpg", "GROUP_Image0002.jpg"],
                )
                # The verifier rebuilds these names independently - proving it
                # agrees they are .jpg, not the .tif it would compute with the
                # toggle on.
                verify_published_folder(
                    package.path, "GROUP", 2, config.encoding, config.tiff_output
                )


class LuminanceGuardTests(unittest.TestCase):
    """The button is not the boundary.

    LWCAM hides the tool when the station has it switched off, but a stale
    client or anything speaking to the engine directly must be refused too.
    """

    def test_enabled_station_allows_the_request(self) -> None:
        with patch.object(settings, "luminance_enabled", True):
            assert_luminance_enabled()

    def test_disabled_station_refuses_with_503(self) -> None:
        with patch.object(settings, "luminance_enabled", False):
            with self.assertRaises(BusinessError) as caught:
                assert_luminance_enabled()
        self.assertEqual(caught.exception.http_status, 503)
        self.assertEqual(caught.exception.code, ApiCodes.SERVICE_UNAVAILABLE)

    def test_default_is_off_since_the_tool_is_enhancement_by_definition(self) -> None:
        self.assertFalse(type(settings).model_fields["luminance_enabled"].default)


if __name__ == "__main__":
    unittest.main()
