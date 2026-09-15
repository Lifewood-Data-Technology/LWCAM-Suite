"""A contradictory `not_visible` verdict is repaired, not fatal.

The compare stage can return `not_visible` for a field the extract stage did
produce observations for. Both calls succeeded and the JSON was schema-valid;
an internal contract check then threw the whole job away with
`AiReviewOutputError`, leaving the folder with no result and parked from the
preanalysis sweep by its own failed job - recoverable only by a human pressing
Run again.

Every comparable violation around it was already repaired rather than failed
(a field with no observations is normalized to not_visible/0.0/[], a mismatch
with no suggested value is downgraded to uncertain, an unresolvable citation is
dropped). This pins the same treatment for the `not_visible` case, and the
evidence restore that has to come with it: the comparer that believed a field
was not visible cited nothing, so the field would otherwise reach the reviewer
as a bare `uncertain` with the very observations that contradict it discarded.

unittest.TestCase, like the rest of this tree, so `python -m unittest discover`
and pytest both collect it.
"""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import patch

from app.services import ai_review
from app.services.ai_review import (
    AiReviewImageSource,
    AiReviewOutputError,
    AiReviewSnapshot,
    BatchObservation,
    ModelComparison,
    ModelEvidence,
    ModelFieldReview,
    OpenRouterReviewProvider,
)

OBSERVATION = {
    "fieldKey": "volume",
    "candidateValue": None,
    "confidence": 0.4,
    "imageId": 900101,
    "filename": "page1.jpg",
    "observation": "This image appears to be the cover of the folder.",
}


def _snapshot() -> AiReviewSnapshot:
    return AiReviewSnapshot(
        folder_id=9,
        user_id="op",
        source_hash="0" * 64,
        input_hash="1" * 64,
        metadata={"volume": "7777 8888-9999 file no. 1"},
        template={"fields": [{"key": "volume", "input": "text"}]},
        images=(),
    )


class _Provider(OpenRouterReviewProvider):
    """`compare`'s normalization only - no API key, no client, no HTTP."""

    def __init__(self, comparison: ModelComparison) -> None:  # noqa: D107 - see class docstring
        self.comparison = comparison
        self.request_semaphore = None
        self.cancellation_event = None
        self.job_id = "test"
        self._effective_reasoning: dict[str, str] = {}

    def _call_parse(self, **kwargs: object) -> ModelComparison:  # type: ignore[override]
        return self.comparison


def _compare(comparison: ModelComparison) -> ModelComparison:
    return _Provider(comparison).compare(_snapshot(), [OBSERVATION])


class NotVisibleWithObservationsTests(unittest.TestCase):
    def test_it_is_downgraded_to_uncertain_instead_of_failing_the_job(self) -> None:
        result = _compare(ModelComparison(fieldReviews=[ModelFieldReview(
            key="volume",
            suggestedValue=None,
            verdict="not_visible",
            confidence=0.0,
            evidence=[],
        )]))

        review = result.fieldReviews[0]
        self.assertEqual(review.verdict, "uncertain")
        self.assertIsNone(review.suggestedValue)

    def test_the_contradicting_observations_are_restored_as_evidence(self) -> None:
        """The second half of the repair, and not optional: a comparer that
        believes a field is not visible cites nothing, so without this the
        downgraded field reaches the reviewer with no evidence at all."""
        result = _compare(ModelComparison(fieldReviews=[ModelFieldReview(
            key="volume",
            suggestedValue=None,
            verdict="not_visible",
            confidence=0.0,
            evidence=[],
        )]))

        evidence = result.fieldReviews[0].evidence
        self.assertEqual(len(evidence), 1)
        self.assertEqual(evidence[0].observation, OBSERVATION["observation"])
        self.assertEqual(evidence[0].imageId, OBSERVATION["imageId"])

    def test_a_mismatch_that_cited_nothing_still_gets_its_evidence_back(self) -> None:
        """The repair this one was modelled on must keep working."""
        result = _compare(ModelComparison(fieldReviews=[ModelFieldReview(
            key="volume",
            suggestedValue="7777 8888-9999 file no. 2",
            verdict="mismatch",
            confidence=0.9,
            evidence=[],
        )]))

        review = result.fieldReviews[0]
        self.assertEqual(review.verdict, "mismatch")
        self.assertEqual(len(review.evidence), 1)

    def test_a_resolvable_citation_is_left_exactly_as_the_model_sent_it(self) -> None:
        """The repair must not reach fields that never went wrong."""
        cited = ModelEvidence(
            imageId=900101,
            filename="page1.jpg",
            observation=str(OBSERVATION["observation"]),
        )
        result = _compare(ModelComparison(fieldReviews=[ModelFieldReview(
            key="volume",
            suggestedValue=None,
            verdict="match",
            confidence=0.9,
            evidence=[cited],
        )]))

        review = result.fieldReviews[0]
        self.assertEqual(review.verdict, "match")
        self.assertEqual(list(review.evidence), [cited])

    def test_a_field_with_no_observations_at_all_is_still_normalized(self) -> None:
        """`not_visible` with nothing extracted is the CORRECT answer, and the
        branch that handles it runs before the repair - it must not be
        disturbed by it."""
        with patch.object(ai_review, "_template_fields", return_value={"volume": {"key": "volume"}}):
            result = _Provider(ModelComparison(fieldReviews=[ModelFieldReview(
                key="volume",
                suggestedValue="something",
                verdict="not_visible",
                confidence=0.8,
                evidence=[],
            )])).compare(_snapshot(), [])

        review = result.fieldReviews[0]
        self.assertEqual(review.verdict, "not_visible")
        self.assertIsNone(review.suggestedValue)
        self.assertEqual(review.confidence, 0.0)
        self.assertEqual(list(review.evidence), [])

    def test_the_output_contract_still_rejects_a_missing_field(self) -> None:
        """The repair removes one check, not the contract around it."""
        with self.assertRaises(AiReviewOutputError):
            _compare(ModelComparison(fieldReviews=[]))


IMAGES = [
    AiReviewImageSource(id=57, filename="page1.jpg", path=Path("page1.jpg"), size=1, mtime_ns=1),
    AiReviewImageSource(id=58, filename="page2.jpg", path=Path("page2.jpg"), size=1, mtime_ns=1),
]


def _observation(**overrides: object) -> BatchObservation:
    fields = {
        "fieldKey": "volume",
        "candidateValue": None,
        "confidence": 0.5,
        "imageId": 57,
        "filename": "page1.jpg",
        "observation": "The cover reads Volume 3.",
    }
    fields.update(overrides)
    return BatchObservation(**fields)  # type: ignore[arg-type]


class _ExtractProvider(_Provider):
    """`extract_batch`'s per-observation handling only."""

    def __init__(self, extraction: object) -> None:  # noqa: D107 - see class docstring
        super().__init__(ModelComparison(fieldReviews=[]))
        self.extraction = extraction

    def _call_parse(self, **kwargs: object) -> object:  # type: ignore[override]
        return self.extraction

    def _encoded_image(self, path: Path) -> str:  # type: ignore[override]
        return ""


def _extract(*observations: BatchObservation) -> list[dict[str, object]]:
    extraction = ai_review.BatchExtraction(observations=list(observations))
    return _ExtractProvider(extraction).extract_batch(_snapshot(), IMAGES)


class ExtractDropsBadObservationsTests(unittest.TestCase):
    """One bad reference used to sink the whole job - a 208s reasoning attempt
    and every other observation with it - while the comparing stage twenty
    lines away already dropped unresolvable citations and carried on."""

    def test_a_good_observation_survives_unchanged(self) -> None:
        [observation] = _extract(_observation())
        self.assertEqual(observation["imageId"], 57)
        self.assertEqual(observation["filename"], "page1.jpg")
        self.assertEqual(observation["observation"], "The cover reads Volume 3.")

    def test_an_unknown_field_is_dropped_not_fatal(self) -> None:
        self.assertEqual(_extract(_observation(fieldKey="notAField")), [])

    def test_an_unknown_image_id_is_recovered_from_the_filename(self) -> None:
        """A model that numbers images 1..n still names the file correctly, and
        the filename check exists precisely because the two agree."""
        [observation] = _extract(_observation(imageId=2, filename="page2.jpg"))
        self.assertEqual(observation["imageId"], 58)
        self.assertEqual(observation["filename"], "page2.jpg")

    def test_an_unknown_id_with_an_unknown_filename_is_dropped(self) -> None:
        self.assertEqual(_extract(_observation(imageId=999, filename="nope.jpg")), [])

    def test_an_id_that_contradicts_its_filename_is_dropped(self) -> None:
        """Both resolve and they disagree; there is no way to tell which the
        model meant."""
        self.assertEqual(_extract(_observation(imageId=57, filename="page2.jpg")), [])

    def test_an_empty_observation_is_dropped(self) -> None:
        self.assertEqual(_extract(_observation(observation="   ")), [])

    def test_one_bad_observation_no_longer_costs_the_good_ones(self) -> None:
        """The whole point: folder 15 died on a single bad reference after
        already spending a 208s reasoning attempt."""
        observations = _extract(
            _observation(fieldKey="notAField"),
            _observation(observation="The cover reads Volume 3."),
            _observation(imageId=999, filename="nope.jpg"),
        )
        self.assertEqual(len(observations), 1)
        self.assertEqual(observations[0]["observation"], "The cover reads Volume 3.")


if __name__ == "__main__":
    unittest.main()
