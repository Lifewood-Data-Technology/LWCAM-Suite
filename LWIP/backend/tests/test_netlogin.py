"""Tests for deskew_crop_tool.netlogin - the per-PC network-folder login list
(identical copies ship in LWCam Upload and the QC Platform).

The store is pointed at a temp file (LWCAM_NETWORK_LOGINS), never the real
one under %ProgramData%. Windows' own calls are patched except where a test
says it calls them for real.
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from deskew_crop_tool import netlogin


class NetLoginTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.store = Path(temp.name) / "logins.json"
        env = patch.dict(os.environ, {netlogin.STORE_ENV: str(self.store)})
        env.start()
        self.addCleanup(env.stop)
        self.add = patch.object(netlogin, "_add_connection", return_value=0).start()
        self.cancel = patch.object(netlogin, "_cancel").start()
        self.addCleanup(patch.stopall)
        netlogin._last_errors.clear()

    def test_host_of_and_normalise(self) -> None:
        self.assertEqual(netlogin.host_of(r"\\FILE-PC\LWCamTest\2.Batches"), "FILE-PC")
        self.assertEqual(netlogin.host_of(r"\\?\UNC\FILE-PC\share"), "FILE-PC")
        self.assertIsNone(netlogin.host_of(r"C:\LWIP\1.Images"))
        for typed in ("FILE-PC", r"\\FILE-PC", r"\\FILE-PC\share\x", " FILE-PC ", r"\FILE-PC\x", r"\\?\UNC\FILE-PC\s"):
            self.assertEqual(netlogin.normalise_host(typed), "FILE-PC")
        for bad in ("", r"\\", "LW DEMO", "a;b"):
            with self.assertRaises(ValueError):
                netlogin.normalise_host(bad)

    def test_save_connects_and_never_stores_or_returns_the_password_plainly(self) -> None:
        self.assertIsNone(netlogin.save_login(r"\\FILE-PC\share", r"FILE-PC\lwcam", "p@ss word"))
        self.add.assert_called_once_with("FILE-PC", r"FILE-PC\lwcam", "p@ss word")
        # New credentials drop any connection made with the old ones first.
        self.cancel.assert_called_with("FILE-PC")
        self.assertNotIn("p@ss word", self.store.read_text(encoding="utf-8"))
        rows = netlogin.list_logins()
        self.assertEqual(rows, [{"host": "FILE-PC", "username": r"FILE-PC\lwcam", "saved": True,
                                 "usedByThisService": False}])
        self.assertNotIn("password", json.dumps(rows))

    def test_a_blank_password_keeps_the_saved_one(self) -> None:
        netlogin.save_login("FILE-PC", "old-user", "first")
        netlogin.save_login("file-pc", "new-user", None)
        self.add.assert_called_with("FILE-PC", "new-user", "first")
        self.assertEqual(netlogin.list_logins()[0]["host"], "FILE-PC")  # the name as first saved
        with self.assertRaises(ValueError):
            netlogin.save_login("OTHER-PC", "user", None)  # nothing saved to keep

    def test_one_login_per_pc_whatever_the_case(self) -> None:
        netlogin.save_login("FILE-PC", "a", "1")
        netlogin.save_login("file-pc", "b", "2")
        self.assertEqual([r["username"] for r in netlogin.list_logins()], ["b"])

    def test_list_adds_the_pcs_this_service_uses_without_a_login(self) -> None:
        netlogin.save_login("SAVED-PC", "u", "p")
        rows = netlogin.list_logins([r"\\FILE-PC\a", r"\\file-pc\b", r"C:\local", ""])
        self.assertEqual([(r["host"], r["saved"], r["usedByThisService"]) for r in rows],
                         [("FILE-PC", False, True), ("SAVED-PC", True, False)])

    def test_a_refused_login_is_reported_and_logged_once(self) -> None:
        self.add.return_value = 1326
        with self.assertLogs(netlogin.LOGGER, "WARNING") as logs:
            error = netlogin.save_login("FILE-PC", "u", "wrong")
            netlogin.connect("FILE-PC")
        self.assertEqual(error, "FILE-PC did not accept this username or password.")
        self.assertEqual(len(logs.records), 1)
        self.assertNotIn("wrong", logs.output[0])

    def test_a_clashing_connection_is_dropped_and_retried(self) -> None:
        netlogin.save_login("FILE-PC", "u", "p")
        self.add.reset_mock()
        self.add.side_effect = [1219, 0]
        self.assertIsNone(netlogin.connect("FILE-PC"))
        self.assertEqual(self.add.call_count, 2)

    def test_connect_without_a_saved_login_does_nothing(self) -> None:
        self.assertIsNone(netlogin.connect_for_path(r"\\NOBODY\share"))
        self.assertIsNone(netlogin.connect_for_path(r"C:\local"))
        self.add.assert_not_called()

    def test_remove_forgets_and_disconnects(self) -> None:
        netlogin.save_login("FILE-PC", "u", "p")
        self.cancel.reset_mock()
        netlogin.delete_login(r"\\FILE-PC")
        self.assertEqual(netlogin.list_logins(), [])
        self.cancel.assert_called_once_with("FILE-PC")

    def test_check_all_reports_each_folder_on_each_pc(self) -> None:
        netlogin.save_login("FILE-PC", "u", "p")
        with patch.object(netlogin, "check_folder", side_effect=lambda p: None if p.endswith("a") else "nope"):
            rows = netlogin.check_all([r"\\FILE-PC\a", r"\\FILE-PC\b", r"C:\local"])
        self.assertEqual(rows[0]["loginError"], None)
        self.assertEqual(rows[0]["folders"], [{"path": r"\\FILE-PC\a", "error": None},
                                              {"path": r"\\FILE-PC\b", "error": "nope"}])

    def test_console_request_maps_every_action(self) -> None:
        paths = [r"\\FILE-PC\a"]
        status, body = netlogin.console_request("save", {"host": "FILE-PC", "username": "u", "password": "p"}, paths)
        self.assertEqual((status, body), (200, {"error": None}))
        self.assertEqual(netlogin.console_request("list", None, paths)[1]["logins"][0]["saved"], True)
        self.assertEqual(netlogin.console_request("save", {"host": "", "username": "u"}, paths)[0], 400)
        self.assertEqual(netlogin.console_request("remove", {"host": "FILE-PC"}, paths), (200, {}))
        self.assertEqual(netlogin.console_request("nonsense", {}, paths)[0], 404)

    def test_describe_error_is_plain_english(self) -> None:
        self.assertIn("Cannot reach PC1", netlogin.describe_error(53, "PC1"))
        self.assertIn("Save a network login for PC1", netlogin.describe_error(5, "PC1"))
        self.assertIn("different account", netlogin.describe_error(1219, "PC1"))


@unittest.skipUnless(os.name == "nt", "Windows calls")
class WindowsCallTests(unittest.TestCase):
    """These call Windows for real: DPAPI, and a connection to this PC's own
    IPC$ with the current account - proof the structures and flags are laid
    out right, which a mock cannot give."""

    def test_dpapi_round_trip(self) -> None:
        secret = "p@ss wörd".encode("utf-8")
        blob = netlogin._protect(secret)
        self.assertNotEqual(blob, secret)
        self.assertEqual(netlogin._unprotect(blob), secret)

    def test_a_real_connection_to_this_pc(self) -> None:
        self.assertIn(netlogin._add_connection("127.0.0.1", None, None), (0, 1219))


if __name__ == "__main__":
    unittest.main()
