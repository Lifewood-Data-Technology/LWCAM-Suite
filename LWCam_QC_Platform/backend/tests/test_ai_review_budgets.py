"""The AI review token budgets, and the retry that survives a runaway.

Reasoning tokens are charged against the same output budget as the answer, so
a request with no ceiling truncated mid-JSON and raised the SDK's
`LengthFinishReasonError` - which the retry filter classified as neither
transient nor an output error, ending the job on attempt 1 with no result.
Raising the ceiling alone did not fix it either: bare `reasoning: enabled`
means "medium effort", which a budget-style model derives as ~50% of the
top-level max_tokens, so every increase handed half of it back to the
deliberation.

Pinned here: both budgets are configured and distinct, and a truncation
retries ONCE with reasoning off rather than failing the job.

unittest.TestCase, like the rest of this tree, so `python -m unittest discover`
and pytest both collect it.
"""

from __future__ import annotations

import unittest
from unittest.mock import patch

from app.core.config import settings
from app.services import ai_review
from app.services.ai_review import AiReviewError, OpenRouterReviewProvider


class LengthFinishReasonError(Exception):
    """Stands in for the OpenAI SDK's own class, which the retry filter matches
    by NAME so the SDK does not have to be imported into the retry path."""


class WallTimeoutError(Exception):
    """A wall-clock bail. `_is_timeout` matches on the name, exactly as the
    provider's own `TimeoutError` is matched."""


class BudgetDefaultsTests(unittest.TestCase):
    def test_the_shipped_defaults_are_the_verified_pair(self) -> None:
        self.assertEqual(settings.ai_review_max_tokens, 32768)
        self.assertEqual(settings.ai_review_reasoning_max_tokens, 10240)
        self.assertEqual(settings.ai_review_extract_reasoning_mode, "enabled")
        self.assertEqual(settings.ai_review_extract_timeout_seconds, 300.0)
        # The bail that bounds what an operator waits: a reasoning attempt that
        # has not converged by here is unlikely to at all, and the reasoning-off
        # retry costs ~11s against the ~220s of waiting it out.
        self.assertEqual(settings.ai_review_reasoning_timeout_seconds, 80.0)
        self.assertLess(
            settings.ai_review_reasoning_timeout_seconds,
            settings.ai_review_extract_timeout_seconds,
        )
        # The compare stage does not reason; leaving it enabled would pay for
        # deliberation on a step that only diffs two structures.
        self.assertEqual(settings.ai_review_compare_reasoning_mode, "disabled")

    def test_the_answer_keeps_the_larger_share_of_the_ceiling(self) -> None:
        """The whole point of the pair: OpenRouter requires the top-level
        ceiling to be strictly higher than the thinking budget, and the answer
        needs what is left (5667 tokens, the largest observed)."""
        answer_room = settings.ai_review_max_tokens - settings.ai_review_reasoning_max_tokens
        self.assertGreater(settings.ai_review_max_tokens, settings.ai_review_reasoning_max_tokens)
        self.assertGreaterEqual(answer_room, 8192)


class _Provider(OpenRouterReviewProvider):
    """The retry loop alone - no API key, no client, no sleeping."""

    def __init__(self, outcomes: list[object]) -> None:  # noqa: D107 - see class docstring
        self.outcomes = outcomes
        self.seen_reasoning_modes: list[object] = []
        self.seen_timeouts: list[object] = []
        self.request_semaphore = None
        self.cancellation_event = None
        self.job_id = "test"
        self._effective_reasoning: dict[str, str] = {}

    async def _call_parse_attempt(self, **kwargs: object) -> object:  # type: ignore[override]
        self.seen_reasoning_modes.append(kwargs.get("reasoning_mode"))
        self.seen_timeouts.append(kwargs.get("timeout_seconds"))
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    @staticmethod
    def _retry_delay(error: Exception, attempt: int) -> float:  # type: ignore[override]
        return 0.0


def _call(provider: _Provider, timeout_seconds: float = 1.0) -> object:
    with patch.object(ai_review, "_stage_request_settings", wraps=ai_review._stage_request_settings):
        return provider._call_parse(
            messages=[],
            text_format=ai_review.BatchExtraction,
            stage="extracting",
            timeout_seconds=timeout_seconds,
        )


class TruncationFallsBackToNoReasoningTests(unittest.TestCase):
    def test_a_truncated_attempt_retries_once_with_reasoning_off(self) -> None:
        """Attempt 1 runs out of output tokens mid-JSON; attempt 2 must be sent
        with reasoning disabled, which frees the whole ceiling for the answer.

        Before the fix this error matched no retry branch and the job ended on
        attempt 1 having produced nothing.
        """
        provider = _Provider([LengthFinishReasonError("truncated"), "RESPONSE"])
        with patch.object(provider, "_parse_structured_response", return_value="PARSED"):
            result = _call(provider)

        self.assertEqual(result, "PARSED")
        # None = "send the stage's configured mode"; the override only appears
        # on the retry.
        self.assertEqual(provider.seen_reasoning_modes, [None, "disabled"])

    def test_it_does_not_loop_when_the_retry_truncates_too(self) -> None:
        """Reasoning is already off on attempt 2, so a second truncation means
        the budget itself is too small - retrying again cannot help."""
        provider = _Provider(
            [LengthFinishReasonError("truncated"), LengthFinishReasonError("truncated again")]
        )
        with self.assertRaises(AiReviewError):
            _call(provider)
        self.assertEqual(provider.seen_reasoning_modes, [None, "disabled"])

    def test_an_unrelated_error_still_fails_on_the_first_attempt(self) -> None:
        """The fallback must not turn every error into a retry: only a
        truncation or a wall bail earns the extra attempt."""
        provider = _Provider([ValueError("not retryable"), "RESPONSE"])
        with self.assertRaises(AiReviewError):
            _call(provider)
        self.assertEqual(provider.seen_reasoning_modes, [None])

    def test_a_wall_timeout_drops_the_reasoning_too(self) -> None:
        """Load-bearing, not a refinement. A timeout's name already matched
        `_is_transient`, so without this clause the bail below would retry WITH
        reasoning, burn the cap a second time and fail - a faster failure
        instead of a result.
        """
        provider = _Provider([WallTimeoutError("wall clock"), "RESPONSE"])
        with patch.object(provider, "_parse_structured_response", return_value="PARSED"):
            result = _call(provider)

        self.assertEqual(result, "PARSED")
        self.assertEqual(provider.seen_reasoning_modes, [None, "disabled"])


class ReasoningAttemptIsBailedEarlyTests(unittest.TestCase):
    def test_attempt_one_is_capped_and_the_retry_gets_the_full_clock(self) -> None:
        """The bail bounds what an operator waits; the reasoning-off retry is
        the attempt that actually has to produce a result, so it keeps the
        stage's own timeout."""
        provider = _Provider([WallTimeoutError("wall clock"), "RESPONSE"])
        with patch.object(provider, "_parse_structured_response", return_value="PARSED"):
            _call(provider, timeout_seconds=300.0)

        self.assertEqual(
            provider.seen_timeouts,
            [settings.ai_review_reasoning_timeout_seconds, 300.0],
        )

    def test_a_stage_faster_than_the_bail_keeps_its_own_limit(self) -> None:
        """Capped, not substituted: the compare stage's 90s must not be
        stretched to the reasoning bail."""
        provider = _Provider(["RESPONSE"])
        with patch.object(provider, "_parse_structured_response", return_value="PARSED"):
            _call(provider, timeout_seconds=30.0)

        self.assertEqual(provider.seen_timeouts, [30.0])


if __name__ == "__main__":
    unittest.main()
