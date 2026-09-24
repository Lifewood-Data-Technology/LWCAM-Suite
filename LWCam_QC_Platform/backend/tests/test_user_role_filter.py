"""The admin user list's role filter, over a comma-joined roles column.

`users.roles` holds a LIST ('qc,admin'), shared with LWCAM. list_users used to
filter it with `func.lower(User.roles) == role`, which matches only accounts
holding that one role - so every multi-role account vanished from the screen a
SuperAdmin manages users from, while still logging in and working normally.
reviewer_workload had the same bug and was fixed first; this covers the other
caller, and the paging that has to follow the filter for total and window to
agree.

unittest.TestCase, direct function calls, mocked db - the pattern
test_rework_guards.py and test_reviewer_attribution.py already use. No
TestClient, no fixtures.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timezone
from unittest.mock import Mock

from app.core.errors import BusinessError
from app.models.user import User
from app.routers import admin


def _user(user_id: int, name: str, roles: str) -> User:
    """A real User, because the filter reads the `role_set` property.

    Handing back pre-filtered rows is how the equality match survived review:
    the test could not tell a correct filter from a broken one.
    """
    user = User(user_id=name, roles=roles, active=True)
    user.id = user_id
    user.created_at = datetime(2026, 1, 1, tzinfo=timezone.utc)
    user.last_login_at = None
    user.must_change_password = False
    user.is_deleted = False
    user.projects = []
    return user


def _db(*users: User) -> Mock:
    db = Mock()
    db.scalars.return_value = Mock(unique=Mock(return_value=Mock(all=Mock(return_value=list(users)))))
    return db


def _names(response) -> list[str]:
    return [record.userId for record in response.data.records]


class ListUsersRoleFilterTests(unittest.TestCase):
    ALICE = ("alice", "qc")
    DANA = ("dana", "qc,admin")
    SHAWN = ("shawn", "capture,admin")
    ROOT = ("root", "SuperAdmin")

    def _people(self) -> list[User]:
        return [
            _user(index, name, roles)
            for index, (name, roles) in enumerate((self.ALICE, self.DANA, self.SHAWN, self.ROOT), start=1)
        ]

    def test_a_multi_role_account_appears_under_each_role_it_holds(self) -> None:
        """The bug: 'qc,admin' answered to neither filter.

        page/size are passed explicitly in every call here: calling the route
        directly skips FastAPI, so its Query(...) defaults arrive as Query
        objects rather than ints.
        """
        response = admin.list_users(None, _db(*self._people()), page=1, size=20, role="qc")
        self.assertEqual(_names(response), ["alice", "dana"])

        response = admin.list_users(None, _db(*self._people()), page=1, size=20, role="admin")
        self.assertEqual(_names(response), ["dana", "shawn"])

    def test_super_admin_is_its_own_filter_and_admin_does_not_catch_it(self) -> None:
        """'SuperAdmin' contains 'admin' - a substring match would leak it."""
        response = admin.list_users(None, _db(*self._people()), page=1, size=20, role="super_admin")
        self.assertEqual(_names(response), ["root"])
        self.assertNotIn("root", _names(admin.list_users(None, _db(*self._people()), page=1, size=20, role="admin")))

    def test_no_role_filter_lists_everyone(self) -> None:
        response = admin.list_users(None, _db(*self._people()), page=1, size=20)
        self.assertEqual(_names(response), ["alice", "dana", "shawn", "root"])
        self.assertEqual(response.data.total, 4)

    def test_total_counts_the_filtered_set_not_the_table(self) -> None:
        """Paging follows the filter, or the count and the window disagree."""
        response = admin.list_users(None, _db(*self._people()), page=1, size=1, role="admin")
        self.assertEqual(_names(response), ["dana"])
        self.assertEqual(response.data.total, 2)

        response = admin.list_users(None, _db(*self._people()), page=2, size=1, role="admin")
        self.assertEqual(_names(response), ["shawn"])
        self.assertEqual(response.data.total, 2)

        response = admin.list_users(None, _db(*self._people()), page=3, size=1, role="admin")
        self.assertEqual(_names(response), [])
        self.assertEqual(response.data.total, 2)

    def test_an_unsupported_role_is_still_rejected(self) -> None:
        with self.assertRaises(BusinessError):
            admin.list_users(None, _db(*self._people()), page=1, size=20, role="captain")


if __name__ == "__main__":
    unittest.main()
