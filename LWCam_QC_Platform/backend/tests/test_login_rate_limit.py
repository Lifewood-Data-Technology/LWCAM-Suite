"""Pure unit tests for app/routers/auth.py's in-process login rate limiter.

No TestClient, no HTTP - each test calls check_login_rate_limit /
record_login_failure / reset_login_attempts directly, exactly like every
other test in this suite. `now` is passed explicitly throughout so the
window's expiry can be proven without a real sleep.

Each test uses its own (ip, username) key - the limiter's dict is a shared
module-level global, and a key collision between tests would make one test's
failures count against another's threshold check.
"""

from __future__ import annotations

import unittest

from app.core.errors import BusinessError
from app.routers.auth import (
    LOGIN_ATTEMPT_LIMIT,
    LOGIN_ATTEMPT_WINDOW_SECONDS,
    check_login_rate_limit,
    record_login_failure,
    reset_login_attempts,
)


class LoginRateLimitTests(unittest.TestCase):
    def test_allows_up_to_the_threshold(self) -> None:
        ip, user = "10.0.0.1", "operator_a"
        for _ in range(LOGIN_ATTEMPT_LIMIT - 1):
            record_login_failure(ip, user, now=0.0)
        # One below the limit must still pass.
        check_login_rate_limit(ip, user, now=0.0)

    def test_blocks_once_threshold_is_reached(self) -> None:
        ip, user = "10.0.0.2", "operator_b"
        for _ in range(LOGIN_ATTEMPT_LIMIT):
            record_login_failure(ip, user, now=0.0)
        with self.assertRaises(BusinessError) as caught:
            check_login_rate_limit(ip, user, now=0.0)
        self.assertEqual(caught.exception.http_status, 429)
        self.assertTrue(caught.exception.message)

    def test_different_ip_same_username_is_not_blocked(self) -> None:
        user = "operator_c"
        for _ in range(LOGIN_ATTEMPT_LIMIT):
            record_login_failure("10.0.0.3", user, now=0.0)
        # A different station guessing a different password for the same
        # username must not inherit someone else's lockout.
        check_login_rate_limit("10.0.0.4", user, now=0.0)

    def test_window_expires(self) -> None:
        ip, user = "10.0.0.5", "operator_d"
        for _ in range(LOGIN_ATTEMPT_LIMIT):
            record_login_failure(ip, user, now=0.0)
        with self.assertRaises(BusinessError):
            check_login_rate_limit(ip, user, now=0.0)
        # Past the window, the old failures must have aged out.
        later = LOGIN_ATTEMPT_WINDOW_SECONDS + 1.0
        check_login_rate_limit(ip, user, now=later)

    def test_successful_login_resets_the_counter(self) -> None:
        ip, user = "10.0.0.6", "operator_e"
        for _ in range(LOGIN_ATTEMPT_LIMIT - 1):
            record_login_failure(ip, user, now=0.0)
        reset_login_attempts(ip, user)
        # A single further failure right after a reset must not re-trip the
        # limit - the prior near-miss count must be gone, not carried over.
        record_login_failure(ip, user, now=0.0)
        check_login_rate_limit(ip, user, now=0.0)


if __name__ == "__main__":
    unittest.main()
