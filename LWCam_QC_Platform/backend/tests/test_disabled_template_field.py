"""A field the project DISABLED is not shown and is not required.

Found on screen 2026-09-22, reviewing folder 13 of "South Africa Military
Project 2024". The desk rendered `* Cover tag` as a mandatory free-text box and
Approve refused with "This field is required: Cover tag" - but that project sets
`"enabled": false` on Cover Tag, so `metadata_template` drops it and the engine
never asks for it. The block was invented entirely by the web console, whose
`editableTemplateFields` fell back per key and marked the reinvented field
mandatory; the reviewer's only way past it was to type something into a column
the project had chosen not to collect.

The console now trusts the template whenever the task carries one. These tests
hold the backend half of that contract, which is what the console mirrors: a
disabled field leaves the template, and approval validates against the template
it was given rather than a fixed list of names.
"""

from __future__ import annotations

import unittest

from app.models.capture import CaptureBox, CaptureFolder
from app.models.project import Project
from app.routers.qc import metadata_template, validate_metadata_for_approval

TEMPLATE_FIELDS = [
    {
        "id": "coverTag",
        "mode": "editable",
        "label": "Cover Tag",
        "enabled": False,
        "options": ["Cover Will Be Captured"],
        "inputType": "dropdown",
        "mandatory": True,
    },
    {
        "id": "title",
        "mode": "editable",
        "label": "Title",
        "enabled": True,
        "options": ["WWII Medical Files"],
        "inputType": "dropdown",
        "mandatory": True,
    },
    {
        "id": "startDate",
        "mode": "mapped",
        "label": "Start Date",
        "enabled": True,
        "options": ["1939"],
        "valueMap": {"WWII Medical Files": "1939"},
        "inputType": "dropdown",
        "mandatory": True,
        "mappedFrom": "title",
    },
]


def folder_with_template(fields: list[dict]) -> CaptureFolder:
    """Folder 13 as metadata_template reads it, with no database behind it."""
    folder = CaptureFolder(id=13, folder_name="folder", folder_seq=1)
    folder.box = CaptureBox(box_id=1, box_name="box")
    folder.box.project = Project(
        id=1,
        project_id="p1",
        project_key="pk1",
        project_name="South Africa Military Project 2024",
        country_location_code="ZA",
        template={"fields": fields},
    )
    return folder


class DisabledTemplateFieldTests(unittest.TestCase):
    def test_a_disabled_field_leaves_the_template(self) -> None:
        template = metadata_template(folder_with_template(TEMPLATE_FIELDS))

        keys = [field.key for field in template.fields]
        self.assertNotIn("coverTag", keys)
        self.assertEqual(["title", "startDate"], keys)

    def test_approval_does_not_require_a_disabled_field(self) -> None:
        """The whole point: no coverTag value, and approval still passes."""
        template = metadata_template(folder_with_template(TEMPLATE_FIELDS))

        validate_metadata_for_approval(
            {"title": "WWII Medical Files", "startDate": "1939", "coverTag": None},
            template,
        )

    def test_an_enabled_mandatory_field_is_still_required(self) -> None:
        """Dropping the disabled one must not drop the guard with it."""
        template = metadata_template(folder_with_template(TEMPLATE_FIELDS))

        with self.assertRaises(Exception) as caught:
            validate_metadata_for_approval({"title": None, "startDate": "1939"}, template)
        self.assertIn("Title", str(caught.exception))
