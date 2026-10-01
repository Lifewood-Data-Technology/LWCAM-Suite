import unittest

from lwcam_upload.config import db_sslmode


class DbSslModeTests(unittest.TestCase):
    def test_remote_requires_loopback_prefers(self) -> None:
        self.assertEqual(db_sslmode("192.168.0.120", False), "require")
        self.assertEqual(db_sslmode("::1", False), "prefer")
        self.assertEqual(db_sslmode("localhost", True), "require")


if __name__ == "__main__":
    unittest.main()
