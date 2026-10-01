import unittest

from app.core.config import Settings, db_sslmode


class DbSslModeTests(unittest.TestCase):
    def test_remote_hosts_require_tls(self) -> None:
        for host in ("192.168.0.120", "db.example.com", "100.64.1.2"):
            self.assertEqual(db_sslmode(host, False), "require")

    def test_loopback_prefers_unless_forced(self) -> None:
        for host in ("localhost", "127.0.0.1", "::1"):
            self.assertEqual(db_sslmode(host, False), "prefer")
            self.assertEqual(db_sslmode(host, True), "require")

    def test_database_url_carries_the_mode(self) -> None:
        self.assertEqual(Settings(db_host="10.0.0.9").database_url.query["sslmode"], "require")
        self.assertEqual(Settings(db_host="localhost").database_url.query["sslmode"], "prefer")


if __name__ == "__main__":
    unittest.main()
