"""One unreadable folder must cost one row, not the whole page.

`list_tasks` used to build every folder's view model eagerly, so a single
failure failed the entire page response. On 2026-09-09 a folder dated 1877
serialised with a sub-minute UTC offset Pydantic refuses (see
test_pre_1901_dates.py) and station QC-STATION's Completed tab went completely
dark - 19 of its 20 rows were perfectly serviceable.

That cause is fixed. What is under test HERE is the skip itself, so the next
per-folder data fault degrades instead of blanking a tab. The failure is
injected by patching `to_task_vo` rather than by building a genuinely poisoned
row: the fault mode is already covered elsewhere, and injecting keeps this test
about the recovery.
"""

from __future__ import annotations

import logging
import unittest
from unittest.mock import patch

from app.routers.qc import task_vo_or_skip


class _Folder:
    """Minimal stand-in - task_vo_or_skip only ever reads `.id`."""

    def __init__(self, folder_id: int) -> None:
        self.id = folder_id


class TaskVoOrSkipTests(unittest.TestCase):
    def test_a_healthy_folder_is_returned_untouched(self) -> None:
        sentinel = object()
        with patch("app.routers.qc.to_task_vo", return_value=sentinel) as built:
            self.assertIs(task_vo_or_skip("db", _Folder(1), "shawn"), sentinel)
        # Arguments forwarded verbatim - this must not become a re-wrapper.
        built.assert_called_once_with("db", built.call_args.args[1], "shawn")

    def test_a_failing_folder_yields_none_instead_of_raising(self) -> None:
        with patch("app.routers.qc.to_task_vo", side_effect=ValueError("bad date")):
            with self.assertLogs("app.routers.qc", level=logging.ERROR):
                self.assertIsNone(task_vo_or_skip("db", _Folder(13), "shawn"))

    def test_the_skip_names_the_folder_and_the_error(self) -> None:
        """The log is the only trace left, so it has to identify the folder."""
        with patch("app.routers.qc.to_task_vo", side_effect=ValueError("bad date")):
            with self.assertLogs("app.routers.qc", level=logging.ERROR) as caught:
                task_vo_or_skip("db", _Folder(13), "shawn")
        blob = "\n".join(caught.output)
        self.assertIn("folder_id=13", blob)
        self.assertIn("error_type=ValueError", blob)
        # logger.exception, so the traceback travels too - without it the log
        # says a folder failed but not where.
        self.assertIn("Traceback", blob)

    def test_the_catch_is_broad_enough_for_an_unforeseen_fault(self) -> None:
        """Not just ValidationError: malformed data raises KeyError too."""
        for boom in (KeyError("images"), AttributeError("folder_path"), TypeError):
            with self.subTest(boom=boom):
                with patch("app.routers.qc.to_task_vo", side_effect=boom):
                    with self.assertLogs("app.routers.qc", level=logging.ERROR):
                        self.assertIsNone(
                            task_vo_or_skip("db", _Folder(7), "shawn")
                        )

    def test_a_page_keeps_every_row_it_can_build(self) -> None:
        """The shape list_tasks uses: one bad folder, the rest survive."""
        folders = [_Folder(i) for i in (11, 12, 13, 14)]

        def build(_db, folder, _user):
            if folder.id == 13:
                raise ValueError("1877-01-01T06:55:25+06:55:25")
            return f"vo-{folder.id}"

        with patch("app.routers.qc.to_task_vo", side_effect=build):
            with self.assertLogs("app.routers.qc", level=logging.ERROR):
                records = [
                    vo
                    for vo in (
                        task_vo_or_skip("db", folder, "shawn") for folder in folders
                    )
                    if vo is not None
                ]

        self.assertEqual(records, ["vo-11", "vo-12", "vo-14"])
        # 3 of 4, not 0 of 4. `total` is deliberately NOT adjusted - it answers
        # "how much work exists", the row count answers "how much can be shown".
        self.assertEqual(len(records), len(folders) - 1)


class ListTasksWiringTests(unittest.TestCase):
    """Both list comprehensions must go through the wrapper.

    There are exactly two - the AI-gated pending branch, and the default branch
    that serves plain pending, mine AND completed. Miss one and a whole scope
    keeps the old all-or-nothing behaviour, which is invisible until a folder
    goes bad in production.
    """

    def test_list_tasks_uses_the_wrapper_everywhere(self) -> None:
        import inspect

        from app.routers import qc

        source = inspect.getsource(qc.list_tasks)
        self.assertEqual(source.count("task_vo_or_skip("), 2)
        self.assertNotIn(
            "to_task_vo(",
            source,
            "a bare to_task_vo in list_tasks reintroduces the blank page",
        )

    def test_single_folder_endpoints_still_fail_loudly(self) -> None:
        """Opening ONE broken folder must not silently return nothing.

        Skipping there would hide the fault entirely - the operator asked for
        that folder specifically.
        """
        import inspect

        from app.routers import qc

        self.assertNotIn("task_vo_or_skip", inspect.getsource(qc.claim_next))


if __name__ == "__main__":
    unittest.main()
