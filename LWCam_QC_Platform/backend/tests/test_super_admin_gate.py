"""User management is SuperAdmin-only: a plain `admin` must get 403 even by a
direct API call, not merely have the button hidden in the console.

`require_roles` (app/dependencies.py) returns a plain closure that takes the
already-resolved current user and either returns it or raises. Called directly
here, the same way `test_task_list_resilience.py` calls `task_vo_or_skip`
directly rather than going through FastAPI's dependency injection - there is
no TestClient in this suite to route an actual request through.
"""

from __future__ import annotations

import unittest

from app.core.errors import BusinessError
from app.dependencies import require_roles


class _User:
    """Minimal stand-in - `require_roles`'s closure only ever reads `.role_set`."""

    def __init__(self, role_set: set[str]) -> None:
        self.role_set = role_set


class RequireSuperAdminTests(unittest.TestCase):
    def test_a_plain_admin_is_refused(self) -> None:
        dependency = require_roles("super_admin")
        with self.assertRaises(BusinessError) as caught:
            dependency(_User({"admin"}))
        self.assertEqual(caught.exception.http_status, 403)

    def test_super_admin_is_let_through(self) -> None:
        dependency = require_roles("super_admin")
        user = _User({"super_admin"})
        self.assertIs(dependency(user), user)

    def test_holding_admin_alongside_other_roles_is_still_refused(self) -> None:
        """role_set can carry several roles - none of them super_admin must still fail."""
        dependency = require_roles("super_admin")
        with self.assertRaises(BusinessError):
            dependency(_User({"admin", "qc"}))


if __name__ == "__main__":
    unittest.main()
