"""startDate / endDate are verbatim text; only the source timestamps are dates.

Station QC-STATION, 2026-09-09: the Completed tab returned 400 and showed nothing.
Folder 13 - "All Saints' Church Taiping ... Year 1877-1927" - had the year 1877
keyed. It was stored as a timestamptz, read back in the connection's zone, and
Malaysia had no standard time before 1901, so Asia/Kuala_Lumpur is local mean
time there (+06:55:25) and .isoformat() emitted

    1877-01-01T06:55:25+06:55:25

datetime.fromisoformat accepts a seconds-precision offset. Pydantic does not -
RFC 3339 offsets are +-HH:MM - so one folder failed validation and took the
whole page with it.

Resolution, 2026-09-10: archive coverage is whatever the project's records
carry - "1914", "1914-06", "1877-Mar-05" - and FamilySearch takes the CSV value
verbatim. capture_folders.start_date / end_date are text, nothing parses them,
and the year-to-datetime dance is gone. rfc3339 stays for sourceCreatedAt /
sourceUpdatedAt, which ARE instants and still round-trip through timestamptz.
"""

from __future__ import annotations

import csv
import unittest
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from pydantic import ValidationError

from app.core.config import settings
from app.models.capture import CaptureBox, CaptureFolder
from app.models.project import Device
from app.routers.qc import (
    SNAPSHOT_DATE_FIELDS,
    apply_metadata_to_folder,
    editable_metadata_to_dict,
    effective_metadata_snapshot,
    metadata_date,
    normalize_metadata_values,
    rfc3339,
    validate_metadata_for_approval,
)
from app.schemas.qc import (
    EditableFolderMetadata,
    FolderMetadataVO,
    MetadataTemplateFieldVO,
    MetadataTemplateVO,
)
from app.services.export import (
    GROUP_CSV_NAME,
    ExportRuntimeConfig,
    FolderExportSnapshot,
    build_export_zip,
)

# Kuala Lumpur local mean time, the offset in force before 1901. Built by hand
# so the test does not depend on the host's tz database.
KL_LMT = timezone(timedelta(hours=6, minutes=55, seconds=25))

# The VO's required fields. Values are irrelevant to what is under test; they
# only have to be present, or the ValidationError raised is the wrong one.
REQUIRED_VO = {
    "folderId": 13,
    "boxId": 1,
    "boxName": "box",
    "folderName": "folder",
    "folderSeq": 1,
    "deviceId": "SAX01",
}

# Free-text date fields, as a project whose records are not year-only would
# declare them.
TEMPLATE = MetadataTemplateVO(fields=[
    MetadataTemplateFieldVO(key="startDate", label="Start Date", input="text", mandatory=True, exported=True),
    MetadataTemplateFieldVO(key="endDate", label="End Date", input="text", mandatory=True, exported=True),
])


def transient_folder() -> CaptureFolder:
    """Folder 13 as metadata_snapshot needs it, with no database behind it."""
    folder = CaptureFolder(id=13, folder_name="folder", folder_seq=1)
    folder.box = CaptureBox(box_id=1, box_name="box")
    folder.device = Device(device_id="SAX01")
    return folder


class VerbatimDateTests(unittest.TestCase):
    def test_a_metadata_save_round_trips_unchanged(self) -> None:
        """Write path, then the read path the QC page and the task list use."""
        request = EditableFolderMetadata(startDate="  1877-Mar-05 ", endDate="1927")
        folder = transient_folder()

        apply_metadata_to_folder(folder, editable_metadata_to_dict(request), TEMPLATE)
        # Trimmed, and nothing else: no year extraction, no datetime.
        self.assertEqual((folder.start_date, folder.end_date), ("1877-Mar-05", "1927"))

        vo = FolderMetadataVO(**effective_metadata_snapshot(folder, None, TEMPLATE))
        self.assertEqual((vo.startDate, vo.endDate), ("1877-Mar-05", "1927"))

    def test_the_export_csv_carries_both_verbatim(self) -> None:
        metadata = {
            "clientRework": False,
            "title": "Tomb Stones",
            "place": "Taiping",
            "startDate": "1877-Mar-05",
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
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = FolderExportSnapshot(
                folder_id=13,
                project_id=1,
                ingest_project_id="P1",
                location_code="MY",
                metadata=metadata,
                images=[],
                source_user_id="op",
                source_date=date(2026, 8, 4),
            )
            config = ExportRuntimeConfig(
                temp_dir=root, output_dir=root, encoding="utf-8",
                line_ending_name="crlf", line_ending="\r\n",
            )
            with patch.object(settings, "export_zip_output", False):
                package = build_export_zip(snapshot, "GROUP", "run", config)
            with (package.path / GROUP_CSV_NAME).open(encoding="utf-8", newline="") as handle:
                (row,) = list(csv.DictReader(handle))
        self.assertEqual(row["Start Date"], "1877-Mar-05")
        self.assertEqual(row["End Date"], "1927")

    def test_an_1877_folder_needs_no_repair(self) -> None:
        """The value that broke the Completed tab now needs no canonicalising."""
        values = normalize_metadata_values({"startDate": "1877", "endDate": "1927"}, TEMPLATE)
        self.assertEqual((values["startDate"], values["endDate"]), ("1877", "1927"))
        FolderMetadataVO(**REQUIRED_VO, **values)  # must not raise
        self.assertNotIn("startDate", SNAPSHOT_DATE_FIELDS)
        self.assertNotIn("endDate", SNAPSHOT_DATE_FIELDS)
        # No ordering check either: "1927" vs "1877-Mar-05" is not comparable
        # as text, and the archive's notation is not ours to judge.
        validate_metadata_for_approval({"startDate": "1927", "endDate": "1877"}, TEMPLATE)

    def test_blank_is_none_and_whitespace_is_trimmed(self) -> None:
        values = normalize_metadata_values({"startDate": "   ", "endDate": " 1914-06 "}, TEMPLATE)
        self.assertIsNone(values["startDate"])
        self.assertEqual(values["endDate"], "1914-06")


class Rfc3339Tests(unittest.TestCase):
    """Still needed for the source timestamps, which are genuine instants."""

    def test_the_offending_value_becomes_parseable(self) -> None:
        poisoned = datetime(1877, 1, 1, 6, 55, 25, tzinfo=KL_LMT)
        # Precondition: this is genuinely what broke, not a strawman.
        self.assertTrue(poisoned.isoformat().endswith("+06:55:25"))
        with self.assertRaises(ValidationError) as caught:
            FolderMetadataVO(**REQUIRED_VO, sourceCreatedAt=poisoned.isoformat())
        # ...and it fails on that field specifically, not on something else.
        self.assertEqual(
            [e["loc"] for e in caught.exception.errors()], [("sourceCreatedAt",)]
        )

        fixed = rfc3339(poisoned)
        self.assertEqual(fixed, "1877-01-01T00:00:00+00:00")
        FolderMetadataVO(**REQUIRED_VO, sourceCreatedAt=fixed)  # must not raise

    def test_the_instant_is_unchanged(self) -> None:
        """Representation only. The value must not move."""
        poisoned = datetime(1877, 1, 1, 6, 55, 25, tzinfo=KL_LMT)
        self.assertEqual(
            datetime.fromisoformat(rfc3339(poisoned)),
            poisoned,
        )

    def test_a_modern_date_is_untouched_in_value(self) -> None:
        value = datetime(2026, 9, 9, 12, 0, tzinfo=timezone.utc)
        self.assertEqual(rfc3339(value), "2026-09-09T12:00:00+00:00")

    def test_passthrough_cases_match_metadata_date(self) -> None:
        for value in (None, "", "   ", "not a date", "1877-13-45", "1877"):
            with self.subTest(value=value):
                self.assertEqual(rfc3339(value), metadata_date(value))

    def test_every_vo_datetime_field_is_covered(self) -> None:
        """A new datetime field on the VO must be added to SNAPSHOT_DATE_FIELDS.

        Without this, the next such field reintroduces the bug silently. It also
        pins the other direction: startDate/endDate must NOT be datetimes.
        """
        declared = {
            name
            for name, info in FolderMetadataVO.model_fields.items()
            if "datetime" in str(info.annotation)
        }
        self.assertEqual(declared, set(SNAPSHOT_DATE_FIELDS))


class NormalisationFunnelTests(unittest.TestCase):
    """The fix lives in normalize_metadata_values, not metadata_snapshot.

    metadata_snapshot's output is hashed directly by source_hash, so
    normalising there would change every folder's sourceHash - the token the QC
    page holds while a folder is open - and invalidate work in progress. The
    station run confirmed 0 of 36 hashes changed.
    """

    def test_metadata_snapshot_is_not_the_normalisation_point(self) -> None:
        import inspect

        from app.routers import qc

        source = inspect.getsource(qc.metadata_snapshot)
        self.assertNotIn(
            "rfc3339",
            source,
            "normalising in metadata_snapshot would change every sourceHash",
        )

    def test_the_funnel_canonicalises_date_fields(self) -> None:
        import inspect

        from app.routers import qc

        source = inspect.getsource(qc.normalize_metadata_values)
        self.assertIn("SNAPSHOT_DATE_FIELDS", source)
        self.assertIn("rfc3339", source)


if __name__ == "__main__":
    unittest.main()
