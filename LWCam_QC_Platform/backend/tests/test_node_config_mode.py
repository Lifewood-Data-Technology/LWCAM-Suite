"""All-In-One mode: LWCam Admin's lwcam_node_config.json is the settings source."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

from app.core.errors import BusinessError
from app.core.node_config import settings_overrides
from app.routers.admin import update_server_settings

BACKEND = Path(__file__).resolve().parents[1]
NODE = {
    "pgHost": "db.example", "pgDatabase": "from_node", "pgUser": "u", "pgPassword": "p",
    "qcJwtSecret": "x" * 40, "qcInputRoot": r"C:\work", "qcOutputRoot": r"C:\out",
}


class NodeConfigModeTests(unittest.TestCase):
    def test_node_config_wins_over_config_txt(self) -> None:
        with TemporaryDirectory() as temp:
            node = Path(temp) / "lwcam_node_config.json"
            node.write_text(json.dumps(NODE), encoding="utf-8")
            config_txt = Path(temp) / "config.txt"
            config_txt.write_text("dbName = from_config_txt\n", encoding="utf-8")
            env = dict(os.environ, LWCAM_NODE_CONFIG=str(node), LWCAM_QC_SERVER_CONFIG=str(config_txt))
            # The settings singleton is built at import: a fresh process.
            out = subprocess.run(
                [sys.executable, "-c", "import sys; sys.path.insert(0, '.'); "
                 "from app.core.config import settings; print(settings.db_name, settings.export_temp_dir)"],
                cwd=BACKEND, env=env, capture_output=True, text=True, check=True,
            ).stdout.split()
        self.assertEqual(out, ["from_node", r"C:\work"])

    def test_missing_required_key_refuses_to_start(self) -> None:
        with self.assertRaises(RuntimeError):
            settings_overrides({k: v for k, v in NODE.items() if k != "pgPassword"})

    def test_settings_save_is_refused(self) -> None:
        with patch("app.routers.admin.node_config_mode", return_value=True):
            with self.assertRaises(BusinessError):
                update_server_settings(None, None, None)


if __name__ == "__main__":
    unittest.main()
