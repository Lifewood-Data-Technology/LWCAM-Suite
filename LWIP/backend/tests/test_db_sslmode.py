import unittest

from deskew_crop_tool.config import db_sslmode


class DbSslModeTests(unittest.TestCase):
    def test_remote_requires_loopback_prefers(self) -> None:
        self.assertEqual(db_sslmode("192.168.0.120", False), "require")
        self.assertEqual(db_sslmode("localhost", False), "prefer")
        self.assertEqual(db_sslmode("127.0.0.1", True), "require")


if __name__ == "__main__":
    unittest.main()
