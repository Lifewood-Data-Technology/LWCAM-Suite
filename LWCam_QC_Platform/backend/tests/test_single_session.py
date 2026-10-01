"""One live sign-in per account: the FIRST wins (app/core/security.py).

Found on 2026-09-29: the same account could be signed in from two browsers
at once. A second sign-in is now refused while the first is in use; a
sign-in silent for SESSION_IDLE_SECONDS (its browser closed) no longer
blocks, and signing out frees the account at once.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest import mock

from fastapi.security import HTTPAuthorizationCredentials

from app.core import security
from app.core.errors import BusinessError
from app.core.security import (
    ALREADY_SIGNED_IN_KEY,
    SIGNED_IN_ELSEWHERE_KEY,
    create_access_token,
    decode_access_token,
    end_session,
)
from app.dependencies import get_current_user


class _Db:
    def __init__(self, user) -> None:
        self.user = user

    def get(self, _model, user_id):
        return self.user if user_id == self.user.id else None


class SingleSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        security._current_session.clear()
        self.addCleanup(security._current_session.clear)
        self.user = SimpleNamespace(id=7, status="active")
        self.clock = 1000.0
        patcher = mock.patch.object(security.time, "monotonic", lambda: self.clock)
        patcher.start()
        self.addCleanup(patcher.stop)

    def request_as(self, token: str):
        return get_current_user(_Db(self.user), HTTPAuthorizationCredentials(scheme="Bearer", credentials=token))

    def test_a_second_sign_in_is_refused_while_the_first_is_in_use(self) -> None:
        first = create_access_token(7, "clement", "qc")
        self.clock += 170  # still inside the idle window
        with self.assertRaises(BusinessError) as caught:
            create_access_token(7, "clement", "qc")
        self.assertEqual(caught.exception.http_status, 409)
        self.assertEqual(caught.exception.data, {"errorKey": ALREADY_SIGNED_IN_KEY})
        self.assertIs(self.request_as(first), self.user, "the first browser carries on")

    def test_every_request_keeps_the_sign_in_in_use(self) -> None:
        first = create_access_token(7, "clement", "qc")
        for _ in range(5):
            self.clock += 120
            self.request_as(first)  # the console's once-a-minute check-in
        with self.assertRaises(BusinessError):
            create_access_token(7, "clement", "qc")

    def test_a_closed_browser_frees_the_account_after_the_idle_wait(self) -> None:
        first = create_access_token(7, "clement", "qc")
        self.clock += security.SESSION_IDLE_SECONDS + 1
        second = create_access_token(7, "clement", "qc")
        self.assertIs(self.request_as(second), self.user)
        with self.assertRaises(BusinessError) as caught:
            self.request_as(first)  # it comes back after all: signed out, told why
        self.assertEqual(caught.exception.http_status, 401)
        self.assertEqual(caught.exception.data, {"errorKey": SIGNED_IN_ELSEWHERE_KEY})

    def test_signing_out_frees_the_account_at_once(self) -> None:
        first = create_access_token(7, "clement", "qc")
        end_session(7, decode_access_token(first)["sid"])
        create_access_token(7, "clement", "qc")

    def test_signing_out_an_old_token_does_not_free_someone_elses_session(self) -> None:
        create_access_token(7, "clement", "qc")
        end_session(7, "some-older-sid")
        with self.assertRaises(BusinessError):
            create_access_token(7, "clement", "qc")

    def test_the_same_browser_is_not_blocked_by_itself(self) -> None:
        first = create_access_token(7, "clement", "qc")
        create_access_token(7, "clement", "qc", current_session_id=decode_access_token(first)["sid"])

    def test_other_accounts_are_unaffected(self) -> None:
        create_access_token(7, "clement", "qc")
        create_access_token(8, "someone-else", "qc")

    def test_after_a_restart_the_first_token_seen_is_adopted(self) -> None:
        a = create_access_token(7, "clement", "qc")
        security._current_session.clear()  # what a restart leaves
        self.assertTrue(security.is_current_session(7, decode_access_token(a)["sid"]))
        self.assertFalse(security.is_current_session(7, "another-browser"))


if __name__ == "__main__":
    unittest.main()
