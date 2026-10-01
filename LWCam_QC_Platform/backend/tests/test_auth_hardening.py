"""Phase 2 sign-in hardening (app/core/security.py, dependencies.py, routers/auth.py).

- Signing out REVOKES the token: it used to only free the account's slot, and
  is_current_session then re-adopted any valid token, so a copied old token
  worked again until it expired.
- An admin resetting / changing / deleting a user ends that user's live login.
- must_change_password is enforced by the API, not only by the console's
  redirect.
- Login guessing: a per-IP cap across usernames, and bcrypt runs for an
  unknown username too.
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest import mock

from fastapi.security import HTTPAuthorizationCredentials

from app.core import security
from app.core.errors import BusinessError
from app.core.security import (
    DUMMY_PASSWORD_HASH,
    create_access_token,
    decode_access_token,
    end_session,
    hash_password,
)
from app.dependencies import get_current_user, get_current_user_any_state
from app.routers import admin, auth
from app.schemas.admin import ResetPasswordRequest
from app.schemas.auth import LoginRequest


class _Db:
    def __init__(self, user) -> None:
        self.user = user

    def get(self, _model, user_id):
        return self.user if user_id == self.user.id else None

    def scalar(self, _statement):
        return self.user

    def commit(self) -> None:
        pass


def _bearer(token: str) -> HTTPAuthorizationCredentials:
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


class SessionRevocationTests(unittest.TestCase):
    def setUp(self) -> None:
        security._current_session.clear()
        security._revoked_sessions.clear()
        self.addCleanup(security._current_session.clear)
        self.addCleanup(security._revoked_sessions.clear)
        self.user = SimpleNamespace(id=21, status="active", must_change_password=False)

    def request_as(self, token: str, dependency=get_current_user):
        return dependency(_Db(self.user), _bearer(token))

    def test_logout_then_reusing_the_old_token_is_401(self) -> None:
        token = create_access_token(21, "rita", "qc")
        self.assertIs(self.request_as(token), self.user)
        end_session(21, decode_access_token(token)["sid"])
        with self.assertRaises(BusinessError) as caught:
            self.request_as(token)
        self.assertEqual(caught.exception.http_status, 401)

    def test_a_new_sign_in_after_logout_still_works(self) -> None:
        old = create_access_token(21, "rita", "qc")
        end_session(21, decode_access_token(old)["sid"])
        fresh = create_access_token(21, "rita", "qc")
        self.assertIs(self.request_as(fresh), self.user)

    def test_revocations_are_forgotten_once_the_token_would_have_expired(self) -> None:
        token = create_access_token(21, "rita", "qc")
        sid = decode_access_token(token)["sid"]
        end_session(21, sid)
        self.assertTrue(security.is_revoked(sid))
        security._revoked_sessions[sid] = 0.0  # its expiry has passed
        self.assertFalse(security.is_revoked(sid))
        self.assertEqual(security._revoked_sessions, {})

    def test_resetting_a_users_password_ends_their_login(self) -> None:
        token = create_access_token(21, "rita", "qc")
        self.assertIs(self.request_as(token), self.user)
        target = SimpleNamespace(id=21, password="x", must_change_password=False, updated_by=None)
        with mock.patch.object(admin, "user_or_404", return_value=target):
            admin.reset_password(
                21, ResetPasswordRequest(newPassword="new-secret"), SimpleNamespace(id=1), _Db(target)
            )
        self.assertTrue(target.must_change_password)
        with self.assertRaises(BusinessError) as caught:
            self.request_as(token)
        self.assertEqual(caught.exception.http_status, 401)

    def test_deleting_a_user_ends_their_login(self) -> None:
        token = create_access_token(21, "rita", "qc")
        self.request_as(token)
        security.end_user_sessions(21)
        with self.assertRaises(BusinessError):
            self.request_as(token)
        # ...and does not touch another account's session.
        other = create_access_token(22, "sam", "qc")
        security.end_user_sessions(21)
        self.assertTrue(security.is_current_session(22, decode_access_token(other)["sid"]))


class MustChangePasswordTests(unittest.TestCase):
    def setUp(self) -> None:
        security._current_session.clear()
        security._revoked_sessions.clear()
        self.addCleanup(security._current_session.clear)
        self.addCleanup(security._revoked_sessions.clear)
        self.user = SimpleNamespace(id=31, status="active", must_change_password=True)
        self.token = create_access_token(31, "newbie", "qc")

    def test_a_normal_route_is_refused_with_403(self) -> None:
        with self.assertRaises(BusinessError) as caught:
            get_current_user(_Db(self.user), _bearer(self.token))
        self.assertEqual(caught.exception.http_status, 403)
        self.assertEqual(caught.exception.data, {"errorKey": "auth.mustChangePassword"})

    def test_me_and_change_password_still_work(self) -> None:
        self.assertIs(get_current_user_any_state(_Db(self.user), _bearer(self.token)), self.user)
        # Those two routes - and only those - are wired to the lenient dependency.
        lenient = {
            route.path
            for route in auth.router.routes
            if any(d.call is get_current_user_any_state for d in route.dependant.dependencies)
        }
        self.assertEqual(lenient, {"/auth/me", "/auth/password"})

    def test_once_changed_a_normal_route_works(self) -> None:
        self.user.must_change_password = False
        self.assertIs(get_current_user(_Db(self.user), _bearer(self.token)), self.user)


class LoginGuessingTests(unittest.TestCase):
    def setUp(self) -> None:
        security._current_session.clear()
        self.addCleanup(security._current_session.clear)

    def login(self, ip: str, username: str, password: str, user=None):
        request = SimpleNamespace(client=SimpleNamespace(host=ip), headers={})
        return auth.login(LoginRequest(username=username, password=password), request, _Db(user))

    def test_twenty_first_failure_from_one_ip_across_usernames_is_429(self) -> None:
        ip = "10.9.0.1"
        # A different username every time, so the per-(IP, username) limit never trips.
        for n in range(auth.IP_FAILURE_LIMIT):
            with self.assertRaises(BusinessError) as caught:
                self.login(ip, f"guess{n}", "wrong-password")
            self.assertEqual(caught.exception.http_status, 401)
        with self.assertRaises(BusinessError) as caught:
            self.login(ip, "guess-last", "wrong-password")
        self.assertEqual(caught.exception.http_status, 429)
        # Another address is unaffected.
        with self.assertRaises(BusinessError) as caught:
            self.login("10.9.0.2", "guess0", "wrong-password")
        self.assertEqual(caught.exception.http_status, 401)

    def test_an_unknown_username_still_runs_bcrypt(self) -> None:
        with mock.patch.object(security.bcrypt, "checkpw", return_value=False) as spy:
            with self.assertRaises(BusinessError) as caught:
                self.login("10.9.0.3", "nobody-here", "whatever")
        self.assertEqual(caught.exception.http_status, 401)
        spy.assert_called_once()
        self.assertEqual(spy.call_args.args[1], DUMMY_PASSWORD_HASH.encode("utf-8"))

    def test_the_409_keeps_the_failure_counter(self) -> None:
        ip, name = "10.9.0.4", "busy_user"
        user = SimpleNamespace(
            id=41, user_id=name, password=hash_password("right-password"),
            status="active", role="qc", last_login_at=None,
        )
        create_access_token(41, name, "qc")  # someone else is signed in and in use
        auth.record_login_failure(ip, name)
        with self.assertRaises(BusinessError) as caught:
            self.login(ip, name, "right-password", user)
        self.assertEqual(caught.exception.http_status, 409)
        self.assertEqual(len(auth._login_failures[auth._login_key(ip, name)]), 1)


if __name__ == "__main__":
    unittest.main()
