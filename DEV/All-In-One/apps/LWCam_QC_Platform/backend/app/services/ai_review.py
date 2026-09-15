from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import random
import re
import shutil
import tempfile
import threading
import time
import unicodedata
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import suppress
from dataclasses import dataclass, replace
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
from hashlib import sha256
from pathlib import Path
from typing import Any, Callable, Literal, NoReturn

from PIL import Image
from pydantic import BaseModel, ConfigDict, Field, ValidationError, create_model

from app.core.config import settings
from app.core.paths import fs_path
from app.services.previews import normalize_preview_frame


logger = logging.getLogger("uvicorn.error")
AiReviewTrigger = Literal["manual", "preanalysis"]
AiReviewStage = Literal["queued", "extracting", "comparing"]
AiReviewReasoningMode = Literal["auto", "enabled", "disabled"]
AiReviewOutputMode = Literal["json_schema", "json_object", "prompt_json"]
AI_REVIEW_PROMPT_VERSION = "5"
BACKEND_ROOT = Path(__file__).resolve().parents[2]
ANALYZED_FIELDS = (
    "coverTag",
    "imageTags",
    "title",
    "volume",
    "startDate",
    "endDate",
    "archivalRefNo",
)
DATE_FIELDS = {"startDate", "endDate"}
# Archive coverage is free text now ("1914", "1914-06", "1877-Mar-05"; see
# test_pre_1901_dates.py) - not necessarily a bare year. These are the shapes
# worth trusting from a model: a year, a year-month, a year-month-day, a
# year-Mon-day with an English abbreviation, or a plain year range. Narrow on
# purpose - prose still has to fail this, which a bare "len() < 24" would not.
_MONTH_ABBR = "Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec"
_ARCHIVE_DATE_RE = re.compile(
    rf"^\d{{4}}(?:-\d{{2}}(?:-\d{{2}})?|-(?:{_MONTH_ABBR})-\d{{2}}|-\d{{4}})?$",
    re.IGNORECASE,
)


def is_plausible_archive_date(text: str) -> bool:
    """Whether [text] is a shape an archive date field is allowed to take."""
    return bool(text) and len(text) <= 24 and bool(_ARCHIVE_DATE_RE.fullmatch(text))
APPLY_CONFIDENCE = 0.8
CANCELLATION_POLL_SECONDS = 0.05
CLIENT_CLOSE_TIMEOUT_SECONDS = 5.0
ATOMIC_WRITE_RETRY_SECONDS = 0.01
ATOMIC_WRITE_ATTEMPTS = 5


def describe_provider_failure(error: Exception | None) -> str:
    """The operator's sentence for a failed OpenRouter call.

    The job record used to say only "AI analysis failed. Retry later." while the
    real reason - a revoked key, an unknown model, an exhausted balance - went
    to a log that an installed station never shows anyone. Diagnosing one
    revoked key took ruling out the model, the network and the images first.
    So the sentence names the cause where one is recoverable and says what to
    check; anything else keeps the status and the exception type.
    """
    status = getattr(error, "status_code", None)
    body = getattr(error, "body", None)
    payload = body.get("error", body) if isinstance(body, dict) else None
    message = str(payload.get("message") or "").strip() if isinstance(payload, dict) else ""
    if status == 401:
        return "The AI provider rejected the API key."
    if status == 402:
        return "The AI provider account has no credit left."
    if status == 404:
        return "The AI provider does not know the configured model. Check the model names in Station Setup."
    if status == 429:
        return "The AI provider is rate-limiting requests. Retry later."
    if isinstance(status, int):
        return f"The AI provider returned HTTP {status}" + (f": {message}" if message else ".")
    if error is None:
        return "OpenRouter analysis failed."
    name = type(error).__name__
    if "connection" in name.lower():
        return "The AI provider could not be reached. Check the network connection."
    return f"OpenRouter analysis failed ({name})."


class AiReviewError(RuntimeError):
    pass


class AiReviewDisabledError(AiReviewError):
    pass


class AiReviewNotFoundError(AiReviewError):
    pass


class AiReviewTimeoutError(AiReviewError):
    pass


class AiReviewCancelledError(AiReviewError):
    def __init__(self, cancellation_point: str) -> None:
        super().__init__("AI review was cancelled.")
        self.cancellation_point = cancellation_point


class AiReviewOutputError(AiReviewError):
    def __init__(self, failure_type: str) -> None:
        super().__init__("OpenRouter returned an invalid structured result.")
        self.failure_type = failure_type


@dataclass(frozen=True)
class AiReviewRequestPolicy:
    model: str
    reasoning_mode: AiReviewReasoningMode
    output_mode: AiReviewOutputMode


@dataclass(frozen=True)
class AiReviewImageSource:
    id: int
    filename: str
    path: Path
    size: int
    mtime_ns: int

    @classmethod
    def from_path(cls, image_id: int, filename: str, path: Path) -> "AiReviewImageSource":
        resolved = path.expanduser().resolve()
        stat = fs_path(resolved).stat()
        return cls(image_id, filename, resolved, stat.st_size, stat.st_mtime_ns)

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "AiReviewImageSource":
        return cls(
            id=int(value["id"]),
            filename=str(value["filename"]),
            path=Path(value["path"]).resolve(),
            size=int(value["size"]),
            mtime_ns=int(value["mtimeNs"]),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "filename": self.filename,
            "path": str(self.path),
            "size": self.size,
            "mtimeNs": self.mtime_ns,
        }


@dataclass(frozen=True)
class AiReviewSnapshot:
    folder_id: int
    user_id: str
    source_hash: str
    input_hash: str
    metadata: dict[str, Any]
    template: dict[str, Any]
    images: tuple[AiReviewImageSource, ...]
    draft_version: int | None = None

    @classmethod
    def create(
        cls,
        *,
        folder_id: int,
        user_id: str,
        source_hash: str,
        metadata: dict[str, Any],
        template: dict[str, Any],
        images: list[tuple[int, str, Path]],
        draft_version: int | None,
    ) -> "AiReviewSnapshot":
        sources = tuple(AiReviewImageSource.from_path(*image) for image in images)
        input_hash = calculate_input_hash(metadata, template, sources, draft_version)
        return cls(
            folder_id=folder_id,
            user_id=user_id,
            source_hash=source_hash,
            input_hash=input_hash,
            metadata=metadata,
            template=template,
            images=sources,
            draft_version=draft_version,
        )

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "AiReviewSnapshot":
        return cls(
            folder_id=int(value["folderId"]),
            user_id=str(value["userId"]),
            source_hash=str(value["sourceHash"]),
            input_hash=str(value["inputHash"]),
            metadata=dict(value["metadata"]),
            template=dict(value["template"]),
            images=tuple(AiReviewImageSource.from_dict(item) for item in value["images"]),
            draft_version=value.get("draftVersion"),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "folderId": self.folder_id,
            "userId": self.user_id,
            "sourceHash": self.source_hash,
            "inputHash": self.input_hash,
            "metadata": self.metadata,
            "template": self.template,
            "images": [image.to_dict() for image in self.images],
            "draftVersion": self.draft_version,
        }


class StrictReviewModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class BatchObservation(StrictReviewModel):
    fieldKey: str = Field(
        min_length=1,
        description="Exact metadata field key from the supplied fieldContract.",
    )
    candidateValue: str | None = Field(
        description="Metadata value directly supported by the image, or null when no value is readable.",
    )
    confidence: float = Field(
        ge=0,
        le=1,
        description="Confidence that the visible image evidence supports candidateValue.",
    )
    imageId: int = Field(description="Exact image ID from the request.")
    filename: str = Field(min_length=1, description="Exact filename paired with imageId in the request.")
    observation: str = Field(
        min_length=1,
        description="The actual visible text or visual basis; it must not merely repeat candidateValue.",
    )


class BatchExtraction(StrictReviewModel):
    observations: list[BatchObservation] = Field(
        description="Direct visual metadata observations. Use an explicit empty array when none are found.",
    )


def batch_extraction_model(field_keys: tuple[str, ...]) -> type[BatchExtraction]:
    """Build an extraction schema whose fieldKey enum matches this template exactly."""
    if not field_keys:
        return BatchExtraction
    field_key_type = Literal[*field_keys]
    observation_model = create_model(
        "TemplateBatchObservation",
        __base__=BatchObservation,
        fieldKey=(
            field_key_type,
            Field(description="Exact metadata field key from the supplied fieldContract."),
        ),
    )
    extraction_model = create_model(
        "TemplateBatchExtraction",
        __base__=BatchExtraction,
        observations=(
            list[observation_model],
            Field(
                description=(
                    "Direct visual metadata observations. Use an explicit empty array when none are found."
                ),
            ),
        ),
    )
    setattr(extraction_model, "__allowed_field_keys__", frozenset(field_keys))
    return extraction_model


class ModelEvidence(StrictReviewModel):
    imageId: int = Field(description="Image ID copied from an input observation.")
    filename: str = Field(min_length=1, description="Filename copied from the same input observation.")
    observation: str = Field(
        min_length=1,
        description="Observation text copied from an input observation.",
    )


class ModelFieldReview(StrictReviewModel):
    key: str = Field(min_length=1, description="Exact metadata field key from fieldContract.")
    suggestedValue: str | None = Field(
        description="Concrete replacement value for mismatch; explicitly null for every other verdict.",
    )
    verdict: Literal["match", "mismatch", "uncertain", "not_visible"] = Field(
        description="Comparison outcome under the supplied verdict rules.",
    )
    confidence: float = Field(
        ge=0,
        le=1,
        description="Confidence that the evidence supports this verdict.",
    )
    evidence: list[ModelEvidence] = Field(
        description="Zero or more exact references to the supplied input observations.",
    )


class ModelComparison(StrictReviewModel):
    fieldReviews: list[ModelFieldReview] = Field(
        description="Exactly one review for every field in fieldContract.",
    )


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def utc_now_iso() -> str:
    return utc_now().isoformat()


# Typographic characters an extraction observation routinely contains, folded to
# their plain equivalents before evidence is matched. NFKC leaves dashes and
# curly quotes alone, and those are exactly what a model retypes differently.
_EVIDENCE_FOLD = str.maketrans({
    "—": "-", "–": "-", "‒": "-", "−": "-",
    "‘": "'", "’": "'", "‚": "'", "′": "'",
    "“": '"', "”": '"', "„": '"', "″": '"',
    " ": " ",
})


def evidence_match_key(image_id: int, filename: str, observation: str) -> tuple[int, str, str]:
    """Identity of one observation, tolerant of how a model retypes it.

    The comparing stage cites evidence by copying an observation back from the
    extracting stage, and that citation used to be compared byte for byte. Real
    observations carry typography - the failure that prompted this held an em
    dash, "G.P.-S.9943—1940—150,000" - and a model answering with a hyphen,
    a straight quote or one extra space has invented nothing; it has retyped.

    Folding case, unicode form, dashes, quotes and runs of whitespace keeps the
    contract that matters (evidence must correspond to an observation the
    extractor actually made) without also making it a typing test that any model
    may fail at any time.
    """
    text = unicodedata.normalize("NFKC", observation).translate(_EVIDENCE_FOLD)
    text = re.sub(r"\s+", " ", text).strip().casefold()
    return (image_id, filename.strip().casefold(), text)


def canonical_metadata_value(key: str, value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    if key in DATE_FIELDS:
        # Whole-string comparison, case-folded. Truncating to the leading 4
        # digits used to let "1877" and "1877-Mar-05" compare equal - fine
        # when startDate/endDate really were bare years, wrong now that the
        # archive's own free-text notation is what is being compared.
        return text.casefold()
    return text


def calculate_input_hash(
    metadata: dict[str, Any],
    template: dict[str, Any],
    images: tuple[AiReviewImageSource, ...],
    draft_version: int | None,
) -> str:
    payload = {
        "provider": "openrouter",
        "api": "chat.completions",
        "promptVersion": AI_REVIEW_PROMPT_VERSION,
        "models": _configured_models(),
        "reasoningModes": {
            "extracting": settings.ai_review_extract_reasoning_mode,
            "comparing": settings.ai_review_compare_reasoning_mode,
        },
        "outputModes": {
            "extracting": settings.ai_review_extract_output_mode,
            "comparing": settings.ai_review_compare_output_mode,
        },
        "metadata": metadata,
        "template": template,
        "draftVersion": draft_version,
        "images": [
            {
                "id": image.id,
                "filename": image.filename,
                "size": image.size,
                "mtimeNs": image.mtime_ns,
            }
            for image in images
        ],
    }
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)
    return sha256(raw.encode("utf-8")).hexdigest()


def _configured_models() -> dict[str, str]:
    return {
        "extracting": settings.openrouter_extract_model,
        "comparing": settings.openrouter_compare_model,
    }


def _stage_request_settings(
    stage: Literal["extracting", "comparing"],
) -> AiReviewRequestPolicy:
    if stage == "extracting":
        return AiReviewRequestPolicy(
            model=settings.openrouter_extract_model,
            reasoning_mode=settings.ai_review_extract_reasoning_mode,
            output_mode=settings.ai_review_extract_output_mode,
        )
    return AiReviewRequestPolicy(
        model=settings.openrouter_compare_model,
        reasoning_mode=settings.ai_review_compare_reasoning_mode,
        output_mode=settings.ai_review_compare_output_mode,
    )


def api_key_configured() -> bool:
    """Whether an OpenRouter key is present. The key stays in .env, never the UI."""
    key = settings.openrouter_api_key
    return bool(key and key.get_secret_value().strip())


def ai_review_available() -> bool:
    """Stage 1: may this station send images to OpenRouter at all?

    Settable from the Admin console (`AI_REVIEW_ENABLED` in .env is only the
    default), because whether scans leave the site is an operational decision
    rather than a deployment one. The key itself is never settable from the UI.
    """
    return bool(settings.ai_review_enabled and api_key_configured())


def ai_review_root() -> Path:
    root = Path(settings.ai_review_cache_dir).expanduser()
    if not root.is_absolute():
        root = BACKEND_ROOT / root
    root = root.resolve()
    fs_path(root).mkdir(parents=True, exist_ok=True)
    return root


def _atomic_json_write(path: Path, value: dict[str, Any]) -> None:
    fs_path(path.parent).mkdir(parents=True, exist_ok=True)
    temp_path = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        fs_path(temp_path).write_text(
            json.dumps(value, ensure_ascii=False, indent=2, default=str), encoding="utf-8"
        )
        for attempt in range(ATOMIC_WRITE_ATTEMPTS):
            try:
                os.replace(fs_path(temp_path), fs_path(path))
                return
            except PermissionError:
                if attempt >= ATOMIC_WRITE_ATTEMPTS - 1:
                    raise
                time.sleep(ATOMIC_WRITE_RETRY_SECONDS)
    finally:
        with suppress(OSError):
            fs_path(temp_path).unlink(missing_ok=True)


def _read_json(path: Path) -> dict[str, Any] | None:
    for attempt in range(3):
        try:
            value = json.loads(fs_path(path).read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else None
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            if attempt < 2:
                time.sleep(0.002)
    return None


# Field input types the reviewer cannot type into, so there is nothing for the
# AI to suggest: "fixed" is pinned by the project, "mapped" is derived from
# another field. Analysing them produces findings that cannot be applied - and
# worse, applying a suggested value for a mapped field is silently undone by the
# mapping on the next save.
UNSUGGESTABLE_INPUTS = frozenset({"fixed", "mapped"})


def _template_fields(snapshot: AiReviewSnapshot) -> dict[str, dict[str, Any]]:
    """The fields the AI is asked to judge: keyed by the operator, in this template.

    A derived field is excluded even though its key is analyzable. When Start
    Date is mapped from Title, the answer to "the pages say 1940 but this says
    1914" is to correct the TITLE - which the AI already analyses - not the date,
    which the operator cannot set. Leaving them in also put an `input` value in
    the field contract that the prompt never explains, and the model responded
    with mismatches it would not substantiate, failing the whole job on
    `incomplete_mismatch`.
    """
    raw_fields = snapshot.template.get("fields") or []
    return {
        str(field.get("key")): field
        for field in raw_fields
        if isinstance(field, dict)
        and str(field.get("key")) in ANALYZED_FIELDS
        and str(field.get("input") or "text") not in UNSUGGESTABLE_INPUTS
    }


def _job_stage(job: dict[str, Any]) -> AiReviewStage | None:
    stage = job.get("stage")
    if stage in {"queued", "extracting", "comparing"}:
        return stage
    if job.get("status") == "queued":
        return "queued"
    if job.get("status") != "running":
        return None
    progress = job.get("progress") or {}
    total = int(progress.get("totalImages") or 0)
    processed = int(progress.get("processedImages") or 0)
    return "comparing" if total > 0 and processed >= total else "extracting"


def _public_job(job: dict[str, Any], *, stale: bool = False) -> dict[str, Any]:
    models = job.get("models")
    return {
        "jobId": job["jobId"],
        "folderId": job["folderId"],
        "inputHash": job["inputHash"],
        "status": job["status"],
        "stage": _job_stage(job),
        "stageStartedAt": job.get("stageStartedAt"),
        "trigger": job.get("trigger") or "manual",
        "cancelReason": job.get("cancelReason"),
        "model": job.get("model") or (models or {}).get("extracting") or "unknown",
        "models": models,
        "createdAt": job["createdAt"],
        "updatedAt": job["updatedAt"],
        "progress": job.get("progress") or {"processedImages": 0, "totalImages": 0},
        "stale": stale,
        "error": job.get("error"),
        "result": job.get("result"),
    }


def output_contract_instruction(
    text_format: type[BaseModel],
    output_mode: AiReviewOutputMode,
) -> str:
    if output_mode == "json_schema":
        return (
            "Return exactly one JSON object that conforms to the response JSON Schema supplied with this "
            "request. Include every required field, use the exact field names and types, and do not add "
            "properties that are not present in the Schema. Return no explanation or Markdown."
        )

    schema = json.dumps(
        text_format.model_json_schema(),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    instruction = (
        "Return exactly one JSON object that conforms to the complete JSON Schema below. Include every "
        "required field, use the exact field names and types, and do not rename, omit, or add properties. "
        "Return no explanation, commentary, or text before or after the JSON object."
    )
    if output_mode == "prompt_json":
        instruction += " Do not use Markdown or code fences."
    return f"{instruction}\nComplete JSON Schema:\n{schema}"


def messages_with_output_contract(
    messages: list[dict[str, Any]],
    text_format: type[BaseModel],
    output_mode: AiReviewOutputMode,
) -> list[dict[str, Any]]:
    prepared = [dict(message) for message in messages]
    instruction = output_contract_instruction(text_format, output_mode)
    for message in prepared:
        if message.get("role") == "system" and isinstance(message.get("content"), str):
            message["content"] = f"{message['content'].rstrip()}\n\n{instruction}"
            break
    else:
        prepared.insert(0, {"role": "system", "content": instruction})
    return prepared


class OpenRouterReviewProvider:
    def __init__(self) -> None:
        key = settings.openrouter_api_key.get_secret_value() if settings.openrouter_api_key else ""
        if not key:
            raise AiReviewDisabledError("OpenRouter API key is not configured.")
        try:
            from openai import AsyncOpenAI
        except ImportError as error:
            raise AiReviewDisabledError("The OpenAI Python package is not installed.") from error
        self._async_client_type = AsyncOpenAI
        self._client_kwargs = {
            "api_key": key,
            "base_url": settings.openrouter_base_url.rstrip("/"),
            "timeout": max(
                settings.ai_review_extract_timeout_seconds,
                settings.ai_review_compare_timeout_seconds,
            ),
            "max_retries": 0,
        }
        self.client_factory: Callable[[], Any] = self._new_client
        self.request_semaphore: threading.BoundedSemaphore | None = None
        self.cancellation_event: threading.Event | None = None
        self.job_id: str | None = None
        # The reasoning mode each stage's LAST request actually went out with,
        # which is not the configured one once the reasoning-off retry has fired.
        self._effective_reasoning: dict[str, AiReviewReasoningMode] = {}

    def _new_client(self) -> Any:
        return self._async_client_type(**self._client_kwargs)

    def _raise_if_cancelled(self, cancellation_point: str) -> None:
        if self.cancellation_event is not None and self.cancellation_event.is_set():
            raise AiReviewCancelledError(cancellation_point)

    def _acquire_request_slot(self) -> bool:
        semaphore = self.request_semaphore
        if semaphore is None:
            self._raise_if_cancelled("capacity_wait")
            return False
        while True:
            self._raise_if_cancelled("capacity_wait")
            if semaphore.acquire(timeout=CANCELLATION_POLL_SECONDS):
                try:
                    self._raise_if_cancelled("capacity_wait")
                except BaseException:
                    semaphore.release()
                    raise
                return True

    async def _wait_for_cancellation(self) -> None:
        while self.cancellation_event is not None and not self.cancellation_event.is_set():
            await asyncio.sleep(CANCELLATION_POLL_SECONDS)

    async def _call_parse_attempt(
        self,
        *,
        messages: list[dict[str, Any]],
        text_format: type[BaseModel],
        stage: Literal["extracting", "comparing"],
        timeout_seconds: float,
        attempt: int,
        attempts: int,
        reasoning_mode: AiReviewReasoningMode | None = None,
    ) -> Any:
        policy = _stage_request_settings(stage)
        # Set by the retry loop when a previous attempt exhausted the output budget
        # mid-JSON. Overriding it here rather than at each use keeps every log line
        # below reporting the mode the request was ACTUALLY sent with.
        if reasoning_mode is not None:
            policy = replace(policy, reasoning_mode=reasoning_mode)
        self._effective_reasoning[stage] = policy.reasoning_mode
        client = self.client_factory()
        wall_timed_out = False
        cancelled = False
        cleanup_outcome = "closed"
        request_started = time.monotonic()
        request_task: asyncio.Task[Any] | None = None
        cancellation_task: asyncio.Task[None] | None = None
        try:
            self._raise_if_cancelled("provider_call")
            prepared_messages = messages_with_output_contract(messages, text_format, policy.output_mode)
            extra_body: dict[str, Any] = {
                "provider": {
                    "require_parameters": True,
                    "sort": settings.ai_review_provider_sort,
                },
            }
            if policy.reasoning_mode == "enabled":
                extra_body["reasoning"] = {
                    "enabled": True,
                    "exclude": True,
                    # Without an explicit budget, `enabled` means "medium effort",
                    # which a budget-style model derives as ~50% of the top-level
                    # max_tokens - so raising that ceiling raised the thinking
                    # allowance in lockstep and the answer was still truncated.
                    # Bounding the deliberation is what leaves the answer room.
                    "max_tokens": settings.ai_review_reasoning_max_tokens,
                }
            elif policy.reasoning_mode == "disabled":
                extra_body["reasoning"] = {"enabled": False}

            request_kwargs: dict[str, Any] = {
                "model": policy.model,
                "messages": prepared_messages,
                # Sent on BOTH stages. Nothing was sent before, so the provider's
                # own default applied and the same eight pages produced 8, 16 and
                # 1 observations across three runs. The comparison stage inherits
                # that: the run with one observation could only reach "uncertain".
                "temperature": settings.ai_review_temperature,
                "top_p": settings.ai_review_top_p,
                # Also sent on BOTH stages, and for the same reason: unset, the
                # provider's own ceiling applied and a reasoning extract ran out
                # of output tokens mid-JSON. See the note on the setting for why
                # this is not the model's true maximum.
                "max_tokens": settings.ai_review_max_tokens,
                "timeout": timeout_seconds,
                "extra_headers": {"X-OpenRouter-Metadata": "enabled"},
                "extra_body": extra_body,
            }
            # Only when explicitly configured - see the note on the setting: with
            # provider.require_parameters, an unsupported `seed` narrows the pool.
            if settings.ai_review_seed is not None:
                request_kwargs["seed"] = settings.ai_review_seed
            if policy.output_mode == "json_schema":
                request = client.chat.completions.parse(
                    response_format=text_format,
                    **request_kwargs,
                )
            else:
                if policy.output_mode == "json_object":
                    request_kwargs["response_format"] = {"type": "json_object"}
                request = client.chat.completions.create(**request_kwargs)
            request_task = asyncio.create_task(
                request
            )
            waiters: set[asyncio.Task[Any]] = {request_task}
            if self.cancellation_event is not None:
                cancellation_task = asyncio.create_task(self._wait_for_cancellation())
                waiters.add(cancellation_task)
            done, _ = await asyncio.wait(
                waiters,
                timeout=timeout_seconds,
                return_when=asyncio.FIRST_COMPLETED,
            )
            if cancellation_task is not None and cancellation_task in done:
                cancelled = True
                request_task.cancel()
                with suppress(asyncio.CancelledError, Exception):
                    await request_task
                raise AiReviewCancelledError("provider_call")
            if request_task not in done:
                wall_timed_out = True
                request_task.cancel()
                with suppress(asyncio.CancelledError, Exception):
                    await request_task
                raise TimeoutError("AI review provider wall-clock timeout")
            return request_task.result()
        finally:
            if cancellation_task is not None and not cancellation_task.done():
                cancellation_task.cancel()
                with suppress(asyncio.CancelledError):
                    await cancellation_task
            try:
                await asyncio.wait_for(client.close(), timeout=CLIENT_CLOSE_TIMEOUT_SECONDS)
            except TimeoutError:
                cleanup_outcome = "close_timeout"
                logger.warning(
                    "AI review OpenRouter client close timed out; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s cleanup_timeout_seconds=%.2f",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt,
                    attempts,
                    CLIENT_CLOSE_TIMEOUT_SECONDS,
                )
            except Exception as error:
                cleanup_outcome = f"close_failed:{type(error).__name__}"
                logger.warning(
                    "AI review OpenRouter client close failed; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s exception_type=%s",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt,
                    attempts,
                    type(error).__name__,
                )
            if wall_timed_out:
                logger.warning(
                    "AI review OpenRouter call timed out; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s "
                    "outcome=wall_timeout wall_timeout_seconds=%.2f elapsed_seconds=%.2f "
                    "cancellation_cleanup=%s",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt,
                    attempts,
                    timeout_seconds,
                    time.monotonic() - request_started,
                    cleanup_outcome,
                )
            elif cancelled:
                logger.info(
                    "AI review OpenRouter call cancelled; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s "
                    "cancellation_point=provider_call elapsed_seconds=%.2f cancellation_cleanup=%s",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt,
                    attempts,
                    time.monotonic() - request_started,
                    cleanup_outcome,
                )

    @staticmethod
    def _first_json_object(content: str) -> dict[str, Any]:
        decoder = json.JSONDecoder()
        for match in re.finditer(r"\{", content):
            try:
                value, _ = decoder.raw_decode(content[match.start():])
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                return value
        raise AiReviewOutputError("invalid_json")

    @classmethod
    def _parse_structured_response(
        cls,
        response: Any,
        text_format: type[BaseModel],
        output_mode: AiReviewOutputMode,
    ) -> BaseModel:
        choices = getattr(response, "choices", None) or []
        if not choices:
            raise AiReviewOutputError("missing_choice")
        message = choices[0].message
        if output_mode == "json_schema":
            parsed = getattr(message, "parsed", None)
            if parsed is None:
                raise AiReviewOutputError("missing_parsed_result")
            # Do not trust the SDK/provider's parsed instance as proof that the
            # response respected the schema. Some OpenRouter providers return a
            # constructed Pydantic object whose values (notably Literal enums)
            # were never validated locally.
            payload = parsed.model_dump(mode="python") if isinstance(parsed, BaseModel) else parsed
        else:
            content = getattr(message, "content", None)
            if not isinstance(content, str) or not content.strip():
                raise AiReviewOutputError("missing_content")
            if output_mode == "json_object":
                try:
                    payload = json.loads(content)
                except json.JSONDecodeError as error:
                    raise AiReviewOutputError("invalid_json") from error
                if not isinstance(payload, dict):
                    raise AiReviewOutputError("json_not_object")
            else:
                payload = cls._first_json_object(content)

        allowed_field_keys = getattr(text_format, "__allowed_field_keys__", None)
        if isinstance(payload, dict) and allowed_field_keys is not None:
            raw_observations = payload.get("observations")
            if isinstance(raw_observations, list):
                discarded_keys = sorted({
                    str(item.get("fieldKey"))
                    for item in raw_observations
                    if isinstance(item, dict) and item.get("fieldKey") not in allowed_field_keys
                })
                if discarded_keys:
                    logger.warning(
                        "AI review discarded observations with unknown field references; field_keys=%s",
                        discarded_keys,
                    )
                    payload = dict(payload)
                    payload["observations"] = [
                        item
                        for item in raw_observations
                        if not isinstance(item, dict) or item.get("fieldKey") in allowed_field_keys
                    ]
        try:
            return text_format.model_validate(payload)
        except ValidationError as error:
            raise AiReviewOutputError("schema_validation") from error

    def _call_parse(
        self,
        *,
        messages: list[dict[str, Any]],
        text_format: type[BaseModel],
        stage: Literal["extracting", "comparing"],
        timeout_seconds: float,
    ) -> BaseModel:
        policy = _stage_request_settings(stage)
        last_error: Exception | None = None
        attempts = settings.ai_review_request_attempts
        # Set to "disabled" after an attempt runs out of output tokens mid-JSON or
        # burns its reasoning wall clock, so the retry spends the whole budget on
        # the answer instead of on thinking.
        reasoning_override: AiReviewReasoningMode | None = None
        for attempt in range(attempts):
            # A reasoning attempt is bailed early; the reasoning-off retry that
            # follows gets the stage's full timeout, because it is the one that
            # actually has to produce the result. Capped rather than substituted,
            # so a stage configured faster than the reasoning bail keeps its own
            # shorter limit.
            attempt_timeout = timeout_seconds
            if reasoning_override is None and policy.reasoning_mode == "enabled":
                attempt_timeout = min(
                    timeout_seconds, settings.ai_review_reasoning_timeout_seconds
                )
            request_started: float | None = None
            acquired_request_slot = False
            try:
                acquired_request_slot = self._acquire_request_slot()
                request_started = time.monotonic()
                try:
                    response = asyncio.run(
                        self._call_parse_attempt(
                            messages=messages,
                            text_format=text_format,
                            stage=stage,
                            timeout_seconds=attempt_timeout,
                            attempt=attempt + 1,
                            attempts=attempts,
                            reasoning_mode=reasoning_override,
                        )
                    )
                finally:
                    if acquired_request_slot and self.request_semaphore is not None:
                        self.request_semaphore.release()
                        acquired_request_slot = False
                self._raise_if_cancelled("provider_call")
                parsed = self._parse_structured_response(response, text_format, policy.output_mode)
                usage = getattr(response, "usage", None)
                completion_details = getattr(usage, "completion_tokens_details", None)
                logger.info(
                    "AI review OpenRouter call completed; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s "
                    "elapsed_seconds=%.2f request_id=%s input_tokens=%s output_tokens=%s reasoning_tokens=%s",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt + 1,
                    attempts,
                    time.monotonic() - request_started,
                    getattr(response, "id", None),
                    getattr(usage, "prompt_tokens", None),
                    getattr(usage, "completion_tokens", None),
                    getattr(completion_details, "reasoning_tokens", None),
                )
                return parsed
            except AiReviewCancelledError as error:
                logger.info(
                    "AI review OpenRouter request cancelled; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s "
                    "cancellation_point=%s elapsed_seconds=%.2f",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt + 1,
                    attempts,
                    error.cancellation_point,
                    time.monotonic() - request_started if request_started is not None else 0.0,
                )
                raise
            except Exception as error:
                last_error = error
                body = getattr(error, "body", None)
                error_payload = body.get("error", body) if isinstance(body, dict) else None
                error_code = error_payload.get("code") if isinstance(error_payload, dict) else None
                metadata = error_payload.get("metadata") if isinstance(error_payload, dict) else None
                metadata = metadata if isinstance(metadata, dict) else {}
                validation_failure = (
                    error.failure_type if isinstance(error, AiReviewOutputError) else None
                )
                # LengthFinishReasonError carries the truncated completion, and its
                # usage is the only place the reasoning spend of a FAILED attempt
                # is visible - the success log cannot report what never returned.
                # Without it, tuning ai_review_reasoning_max_tokens is guesswork:
                # a run that stops AT the quota means the cap bound, one that
                # stops well short means something else did.
                failed_usage = getattr(getattr(error, "completion", None), "usage", None)
                failed_details = getattr(failed_usage, "completion_tokens_details", None)
                logger.warning(
                    "AI review OpenRouter call failed; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s attempt=%s/%s "
                    "elapsed_seconds=%.2f status=%s request_id=%s error_code=%s "
                    "error_type=%s provider=%s model=%s output_validation=%s exception_type=%s "
                    "output_tokens=%s reasoning_tokens=%s",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt + 1,
                    attempts,
                    time.monotonic() - request_started if request_started is not None else 0.0,
                    getattr(error, "status_code", None),
                    getattr(error, "request_id", None),
                    error_code,
                    metadata.get("error_type"),
                    metadata.get("provider_name"),
                    metadata.get("model_slug"),
                    validation_failure,
                    type(error).__name__,
                    getattr(failed_usage, "completion_tokens", None),
                    getattr(failed_details, "reasoning_tokens", None),
                )
                retryable_output_error = (
                    policy.output_mode == "json_schema" and isinstance(error, AiReviewOutputError)
                )
                # Running out of output tokens mid-JSON is neither transient nor an
                # AiReviewOutputError, so it used to end the job on attempt 1 having
                # produced nothing. Retrying it UNCHANGED would truncate identically,
                # which is why it was excluded - but retrying with the thinking
                # turned off frees the whole budget for the answer and is known to
                # complete this workload. Matched by name so the SDK's exception
                # class does not have to be imported here.
                # Once only: if it truncates again with reasoning already off, the
                # budget really is too small and retrying cannot help.
                #
                # A reasoning attempt fails in two ways that mean the same thing -
                # it never converged: it exhausts the output budget mid-JSON, or
                # it burns the wall clock still deliberating. Both are answered by
                # dropping the thinking, and the timeout case MUST be here: with
                # ai_review_reasoning_timeout_seconds capping attempt 1, a
                # timeout that only counted as transient would retry WITH
                # reasoning, burn the cap again and fail - the bail would just
                # reach the same dead end sooner.
                length_exhausted = type(error).__name__ == "LengthFinishReasonError"
                retry_without_reasoning = (
                    (length_exhausted or self._is_timeout(error))
                    and reasoning_override is None
                    and policy.reasoning_mode != "disabled"
                )
                if retry_without_reasoning:
                    reasoning_override = "disabled"
                    policy = replace(policy, reasoning_mode="disabled")
                if attempt >= attempts - 1 or not (
                    self._is_transient(error) or retryable_output_error or retry_without_reasoning
                ):
                    break
                delay = self._retry_delay(error, attempt)
                logger.info(
                    "AI review OpenRouter retry scheduled; job_id=%s stage=%s model=%s "
                    "reasoning_mode=%s output_mode=%s next_attempt=%s/%s "
                    "delay_seconds=%.2f",
                    self.job_id,
                    stage,
                    policy.model,
                    policy.reasoning_mode,
                    policy.output_mode,
                    attempt + 2,
                    attempts,
                    delay,
                )
                if self.cancellation_event is not None:
                    if self.cancellation_event.wait(delay):
                        raise AiReviewCancelledError("retry_backoff")
                else:
                    time.sleep(delay)
            finally:
                if acquired_request_slot and self.request_semaphore is not None:
                    self.request_semaphore.release()
        if last_error is not None and self._is_timeout(last_error):
            raise AiReviewTimeoutError("AI analysis timed out.") from last_error
        raise AiReviewError(describe_provider_failure(last_error)) from last_error

    @staticmethod
    def _is_timeout(error: Exception) -> bool:
        return "timeout" in type(error).__name__.lower()

    @staticmethod
    def _is_transient(error: Exception) -> bool:
        status_code = getattr(error, "status_code", None)
        if status_code == 429 or (isinstance(status_code, int) and status_code >= 500):
            return True
        name = type(error).__name__.lower()
        return any(part in name for part in ("timeout", "ratelimit", "connection", "internalserver"))

    @staticmethod
    def _retry_delay(error: Exception, attempt: int) -> float:
        response = getattr(error, "response", None)
        headers = getattr(response, "headers", None) or getattr(error, "headers", None)
        retry_after = (headers.get("retry-after") or headers.get("Retry-After")) if headers else None
        if retry_after:
            try:
                return max(0.0, min(float(retry_after), 120.0))
            except (TypeError, ValueError):
                try:
                    target = parsedate_to_datetime(str(retry_after))
                    if target.tzinfo is None:
                        target = target.replace(tzinfo=timezone.utc)
                    return max(0.0, min((target - utc_now()).total_seconds(), 120.0))
                except (TypeError, ValueError, OverflowError):
                    pass
        return (2 ** attempt) + random.uniform(0.0, 0.5)

    @staticmethod
    def _encoded_image(path: Path) -> str:
        temp_root = ai_review_root() / "tmp"
        fs_path(temp_root).mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="image-", dir=fs_path(temp_root)) as directory:
            jpeg_path = Path(directory) / "preview.jpg"
            with Image.open(fs_path(path)) as source:
                if getattr(source, "n_frames", 1) > 1:
                    source.seek(0)
                frame = normalize_preview_frame(source)
            max_edge = settings.ai_review_image_max_edge
            frame.thumbnail((max_edge, max_edge), Image.Resampling.LANCZOS)
            frame.save(jpeg_path, format="JPEG", quality=88, optimize=True)
            return base64.b64encode(jpeg_path.read_bytes()).decode("ascii")

    def _raise_output_contract_error(
        self,
        stage: Literal["extracting", "comparing"],
        failure_type: str,
    ) -> NoReturn:
        policy = _stage_request_settings(stage)
        logger.warning(
            "AI review output contract failed; job_id=%s stage=%s model=%s reasoning_mode=%s "
            "output_mode=%s output_validation=%s",
            self.job_id,
            stage,
            policy.model,
            self._effective_reasoning.get(stage, policy.reasoning_mode),
            policy.output_mode,
            failure_type,
        )
        raise AiReviewOutputError(failure_type)

    def extract_batch(
        self,
        snapshot: AiReviewSnapshot,
        images: list[AiReviewImageSource],
    ) -> list[dict[str, Any]]:
        fields = _template_fields(snapshot)
        if not fields:
            logger.warning(
                "AI review skipped extraction because the metadata template has no analyzable fields; "
                "job_id=%s folder_id=%s",
                self.job_id,
                snapshot.folder_id,
            )
            return []
        field_contract = [
            {
                "key": key,
                "label": field.get("label") or key,
                "input": field.get("input") or "text",
                "options": field.get("options") or [],
            }
            for key, field in fields.items()
        ]
        positive_example = {
            "fieldKey": "archivalRefNo",
            "candidateValue": "2313",
            "confidence": 0.94,
            "imageId": 900001,
            "filename": "illustrative-example.jpg",
            "observation": "The printed label 'Regtl. No.' is followed by '2313'.",
        }
        content: list[dict[str, Any]] = [{
            "type": "text",
            "text": (
                "Inspect every supplied document image and perform OCR on all readable text. Extract only "
                "archival metadata directly supported by visible text or visual evidence; never infer or "
                "guess from general knowledge. Use only a fieldKey from fieldContract, an imageId present "
                "in this request, and that image's exact filename. Every observation must explicitly include "
                "fieldKey, candidateValue, confidence, imageId, filename, and observation. The observation "
                "must describe the actual visible text or visual basis and must not merely repeat the "
                "candidateValue. "
                "Check EVERY image against EVERY field in fieldContract. When a field is legible on more "
                "than one image, report it once for each of those images rather than only the clearest one. "
                "Confidence rubric: 0.90-1.00 means clear text and a complete value; "
                "0.60-0.89 means mostly readable with minor blur; 0.30-0.59 means partially readable or "
                "meaningfully ambiguous. Below 0.30, do not produce a candidate value and do not guess. "
                "archivalRefNo is the number printed under a label such as 'No.', 'Reg. No.' or "
                "'Regtl. No.', often in the block that also carries Rank and Surname. It appears on most "
                "pages of a folder and is usually - though not always - the same on each, so report what "
                "each page actually shows rather than forcing the pages to agree. Identify it by that label "
                "alone: never take it from the volume line, and never from a printer's form code such as "
                "'G.P.-S.9943-1940-150,000', which is part of the blank form. If no labelled number is "
                "legible on a page, report no archivalRefNo for that page rather than substituting another "
                "number from it. "
                "coverTag records whether a COVER PAGE is present among these images, and is the one "
                "field judged across the folder rather than page by page. 'Cover Will Be Captured' means a "
                "cover page IS present; 'Cover Will not Be Captured' and 'Cover Unavailable or Missing' "
                "both mean none is. If one of the images is a cover page, report coverTag once for THAT "
                "image with candidateValue 'Cover Will Be Captured'. If none of them is, report coverTag "
                "exactly once, on any one image, with candidateValue 'Cover Unavailable or Missing' and an "
                "observation saying no cover page appears among the supplied images. Never repeat coverTag "
                "for every image, and never infer it from anything other than whether a cover is there. "
                "volume normally appears on the folder's cover page as the identifier printed for the "
                "whole folder - a reference, a register name, a run of numbers, or a mixture. Report the "
                "whole string as printed, never a fragment of it and never a part you judge to be the "
                "significant one. Projects number differently, so do not expect any particular shape. "
                "The examples below are illustrative only. They are not part of the current request. Never "
                "copy their values, image IDs, filenames, or observations into the response. Positive "
                "example: if an illustrative image shows 'Regtl. No. 2313', an allowed "
                "observation is "
                f"{json.dumps(positive_example, ensure_ascii=False)}. "
                "No-evidence example: after checking every image, if no relevant evidence exists, return the "
                'explicit JSON object {"observations":[]}. '
                f"fieldContract: {json.dumps(field_contract, ensure_ascii=False)}"
            ),
        }]
        for image in images:
            content.append({
                "type": "text",
                "text": f"Image ID {image.id}; filename {image.filename}",
            })
            content.append({
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/jpeg;base64,{self._encoded_image(image.path)}",
                    "detail": "high",
                },
            })
        extraction_model = batch_extraction_model(tuple(fields))
        parsed = self._call_parse(
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You are an archival-document OCR and evidence extraction system. Examine every image "
                        "individually, preserve the source image identity, and report only direct visual evidence."
                    ),
                },
                {"role": "user", "content": content},
            ],
            text_format=extraction_model,
            stage="extracting",
            timeout_seconds=settings.ai_review_extract_timeout_seconds,
        )
        image_map = {image.id: image for image in images}
        # A model that numbers images 1..n still names the file correctly, and the
        # filename check below exists precisely because id and name are expected
        # to agree - so a bad id is recoverable from the name it came with.
        by_filename = {image.filename.strip().casefold(): image for image in images}
        observations: list[dict[str, Any]] = []
        for item in parsed.observations:
            # Per-observation faults are DROPPED, not fatal. Each of these used to
            # sink the whole job - a 208s reasoning attempt and every other
            # observation with it - over one bad reference, while the comparing
            # stage twenty lines away already drops unresolvable citations and
            # carries on. If every observation goes the extraction is empty and
            # comparing normalizes each field to not_visible: a 'nothing found'
            # review rather than a crash.
            if item.fieldKey not in fields:
                logger.info(
                    "AI review discarded observation citing an unknown field; "
                    "job_id=%s field_key=%s",
                    self.job_id,
                    item.fieldKey,
                )
                continue
            source = image_map.get(item.imageId)
            if source is None:
                source = by_filename.get(item.filename.strip().casefold())
                if source is None:
                    logger.info(
                        "AI review discarded observation citing an unknown image; "
                        "job_id=%s image_id=%s filename=%s",
                        self.job_id,
                        item.imageId,
                        item.filename,
                    )
                    continue
                logger.info(
                    "AI review resolved observation by filename; "
                    "job_id=%s image_id=%s filename=%s resolved_image_id=%s",
                    self.job_id,
                    item.imageId,
                    item.filename,
                    source.id,
                )
            elif item.filename != source.filename:
                # Both references resolve and they disagree; there is no way to
                # tell which one the model meant, so the observation goes.
                logger.info(
                    "AI review discarded observation whose filename contradicts its image id; "
                    "job_id=%s image_id=%s filename=%s expected=%s",
                    self.job_id,
                    item.imageId,
                    item.filename,
                    source.filename,
                )
                continue
            observation = item.observation.strip()
            if not observation:
                logger.info(
                    "AI review discarded an empty observation; "
                    "job_id=%s field_key=%s image_id=%s",
                    self.job_id,
                    item.fieldKey,
                    source.id,
                )
                continue
            candidate = canonical_metadata_value(item.fieldKey, item.candidateValue)
            observations.append({
                "fieldKey": item.fieldKey,
                "candidateValue": candidate,
                "confidence": max(0.0, min(1.0, float(item.confidence))),
                "imageId": source.id,
                "filename": source.filename,
                "observation": observation[:500],
            })
        return observations

    def compare(
        self,
        snapshot: AiReviewSnapshot,
        observations: list[dict[str, Any]],
    ) -> ModelComparison:
        fields = _template_fields(snapshot)
        current = {
            key: canonical_metadata_value(key, snapshot.metadata.get(key))
            for key in fields
        }
        comparison_input = {
            "currentMetadata": current,
            "fieldContract": fields,
            "observations": observations,
        }
        comparison_examples = [
            {
                "case": "match",
                "input": {
                    "currentMetadata": {"startDate": "1939"},
                    "fieldContract": {"startDate": {"key": "startDate"}},
                    "observations": [{
                        "fieldKey": "startDate",
                        "candidateValue": "1939",
                        "confidence": 0.95,
                        "imageId": 900101,
                        "filename": "illustrative-match.jpg",
                        "observation": "The year 1939 is clearly visible.",
                    }],
                },
                "output": {"fieldReviews": [{
                    "key": "startDate",
                    "suggestedValue": None,
                    "verdict": "match",
                    "confidence": 0.95,
                    "evidence": [{
                        "imageId": 900101,
                        "filename": "illustrative-match.jpg",
                        "observation": "The year 1939 is clearly visible.",
                    }],
                }]},
            },
            {
                "case": "mismatch",
                "input": {
                    "currentMetadata": {"startDate": "1914"},
                    "fieldContract": {"startDate": {"key": "startDate"}},
                    "observations": [{
                        "fieldKey": "startDate",
                        "candidateValue": "1939",
                        "confidence": 0.95,
                        "imageId": 900102,
                        "filename": "illustrative-mismatch.jpg",
                        "observation": "The year 1939 is clearly visible.",
                    }],
                },
                "output": {"fieldReviews": [{
                    "key": "startDate",
                    "suggestedValue": "1939",
                    "verdict": "mismatch",
                    "confidence": 0.95,
                    "evidence": [{
                        "imageId": 900102,
                        "filename": "illustrative-mismatch.jpg",
                        "observation": "The year 1939 is clearly visible.",
                    }],
                }]},
            },
            {
                "case": "uncertain",
                "input": {
                    "currentMetadata": {"startDate": "1939"},
                    "fieldContract": {"startDate": {"key": "startDate"}},
                    "observations": [{
                        "fieldKey": "startDate",
                        "candidateValue": None,
                        "confidence": 0.45,
                        "imageId": 900103,
                        "filename": "illustrative-uncertain.jpg",
                        "observation": "A partially obscured year appears to begin with 193.",
                    }],
                },
                "output": {"fieldReviews": [{
                    "key": "startDate",
                    "suggestedValue": None,
                    "verdict": "uncertain",
                    "confidence": 0.45,
                    "evidence": [{
                        "imageId": 900103,
                        "filename": "illustrative-uncertain.jpg",
                        "observation": "A partially obscured year appears to begin with 193.",
                    }],
                }]},
            },
            {
                "case": "not_visible",
                "input": {
                    "currentMetadata": {"volume": "4"},
                    "fieldContract": {"volume": {"key": "volume"}},
                    "observations": [],
                },
                "output": {"fieldReviews": [{
                    "key": "volume",
                    "suggestedValue": None,
                    "verdict": "not_visible",
                    "confidence": 0.0,
                    "evidence": [],
                }]},
            },
            {
                "case": "cross_field_observation_does_not_count",
                "input": {
                    "currentMetadata": {
                        "title": "WWII Medical Files",
                        "startDate": "1939",
                    },
                    "fieldContract": {
                        "title": {"key": "title"},
                        "startDate": {"key": "startDate"},
                    },
                    "observations": [{
                        "fieldKey": "title",
                        "candidateValue": "WWII Medical Files",
                        "confidence": 0.95,
                        "imageId": 900104,
                        "filename": "illustrative-cross-field.jpg",
                        "observation": "A medical record title is visible and its text also mentions 1944.",
                    }],
                },
                "output": {"fieldReviews": [
                    {
                        "key": "title",
                        "suggestedValue": None,
                        "verdict": "match",
                        "confidence": 0.95,
                        "evidence": [{
                            "imageId": 900104,
                            "filename": "illustrative-cross-field.jpg",
                            "observation": "A medical record title is visible and its text also mentions 1944.",
                        }],
                    },
                    {
                        "key": "startDate",
                        "suggestedValue": None,
                        "verdict": "not_visible",
                        "confidence": 0.0,
                        "evidence": [],
                    },
                ]},
            },
        ]
        parsed = self._call_parse(
            messages=[
                {
                    "role": "system",
                    "content": (
                        "You compare current archival metadata with visual observations produced by an earlier "
                        "image OCR and extraction stage. Those observations are the visual evidence; you do not "
                        "need to see the original images. Return exactly one fieldReview for every fieldContract "
                        "field, with no missing or duplicate keys. If a field has any observation, never return "
                        "not_visible: use uncertain when evidence is weak, incomplete, ambiguous, or conflicting. "
                        "Use match only when evidence supports the current value. Use mismatch only when strong "
                        "evidence supports a different concrete value; mismatch requires a non-null suggestedValue "
                        "and evidence. Use not_visible only when that field has no observation. suggestedValue must "
                        "be explicitly null for match, uncertain, and not_visible. Evidence may only copy an exact "
                        "imageId, filename, and observation from the supplied observations. Current metadata is not "
                        "evidence. Never copy currentMetadata into suggestedValue. For match, uncertain, and "
                        "For coverTag, 'Cover Will not Be Captured' and 'Cover Unavailable or Missing' "
                        "both mean no cover page is present, so an observation reporting no cover MATCHES "
                        "either of them; suggest a change only when the current value claims a cover is "
                        "present and the observation says none is, or the reverse. "
                        "not_visible, suggestedValue must always be null. For mismatch, suggestedValue must be "
                        "concrete and different from currentMetadata. For a fieldReview with key K, use only "
                        "observations whose fieldKey is exactly K. An observation assigned to another field does "
                        "not count for K, even when its observation text mentions a date, number, title, or other "
                        "potentially relevant content. If no observation has fieldKey K, the only valid review for "
                        "K is verdict not_visible, suggestedValue null, confidence 0, and empty evidence. Do not "
                        "infer a verdict from currentMetadata, field options, related fields, or observations "
                        "belonging to another field. The examples below are illustrative only; "
                        "they are not part of the current request and must never be cited as evidence. Each example "
                        "uses a complete mini input and output. Illustrative examples: "
                        f"{json.dumps(comparison_examples, ensure_ascii=False)}. Return the structured result as JSON."
                    ),
                },
                {
                    "role": "user",
                    "content": json.dumps(comparison_input, ensure_ascii=False, default=str),
                },
            ],
            text_format=ModelComparison,
            stage="comparing",
            timeout_seconds=settings.ai_review_compare_timeout_seconds,
        )
        expected_keys = set(fields)
        review_keys = [review.key for review in parsed.fieldReviews]
        if len(review_keys) != len(set(review_keys)):
            self._raise_output_contract_error("comparing", "duplicate_field_review")
        if set(review_keys) != expected_keys:
            self._raise_output_contract_error("comparing", "field_review_coverage")

        observations_by_key: dict[str, list[dict[str, Any]]] = {key: [] for key in fields}
        # Keyed by a folded form so a retyped citation still resolves, and mapped
        # to the observation itself so the reviewer is shown the text the
        # EXTRACTOR produced rather than the comparer's copy of it.
        evidence_index: dict[tuple[int, str, str], dict[str, Any]] = {}
        for observation in observations:
            field_key = str(observation.get("fieldKey") or "")
            image_id = observation.get("imageId")
            filename = str(observation.get("filename") or "")
            observation_text = str(observation.get("observation") or "").strip()
            if field_key not in fields or not isinstance(image_id, int) or not filename or not observation_text:
                self._raise_output_contract_error("comparing", "invalid_input_observation")
            observations_by_key[field_key].append(observation)
            evidence_index[evidence_match_key(image_id, filename, observation_text)] = observation

        normalized_reviews: list[ModelFieldReview] = []
        normalized_output = False
        for review in parsed.fieldReviews:
            field_observations = observations_by_key[review.key]
            if not field_observations:
                if (
                    review.verdict != "not_visible"
                    or review.suggestedValue is not None
                    or float(review.confidence) != 0.0
                    or bool(review.evidence)
                ):
                    logger.info(
                        "AI review normalized field without observation; job_id=%s field_key=%s",
                        self.job_id,
                        review.key,
                    )
                    review = review.model_copy(update={
                        "suggestedValue": None,
                        "verdict": "not_visible",
                        "confidence": 0.0,
                        "evidence": [],
                    })
                    normalized_output = True
                normalized_reviews.append(review)
                continue
            # field_observations is non-empty from here on: the branch above
            # returns every field the extractor said nothing about.
            downgraded_not_visible = False
            if review.verdict == "not_visible":
                # The extractor DID produce observations for this field, so
                # "not visible" is the claim that is wrong - and it is the only
                # claim here that no evidence supports. Failing sank the whole
                # job over one contradictory verdict on one field: the extraction
                # itself survives on completedBatches, but the folder is left with
                # no result, parked from the preanalysis sweep by its failed job,
                # and recoverable only by a human pressing Run again. "uncertain"
                # keeps the field and the observations that contradict it in
                # front of the reviewer, exactly as the mismatch repair below
                # does for its own case.
                logger.info(
                    "AI review downgraded not_visible on a field with observations; "
                    "job_id=%s field_key=%s observations=%s",
                    self.job_id,
                    review.key,
                    len(field_observations),
                )
                review = review.model_copy(update={
                    "verdict": "uncertain",
                    "suggestedValue": None,
                })
                downgraded_not_visible = True
                normalized_output = True
            if review.verdict == "mismatch":
                # A mismatch the model would not put a value to cannot be applied,
                # but it is still a real concern about the field, and "uncertain"
                # is exactly that state. Downgrading keeps the finding in front of
                # the reviewer; failing here threw the whole folder away. Missing
                # EVIDENCE is not checked now - it is repaired further down from
                # this field's own observations.
                if canonical_metadata_value(review.key, review.suggestedValue) is None:
                    logger.info(
                        "AI review downgraded a mismatch with no suggested value; "
                        "job_id=%s field_key=%s",
                        self.job_id,
                        review.key,
                    )
                    review = review.model_copy(update={
                        "verdict": "uncertain",
                        "suggestedValue": None,
                    })
                    normalized_output = True
            elif review.suggestedValue is not None:
                logger.info(
                    "AI review discarded suggested value for non-mismatch verdict; "
                    "job_id=%s field_key=%s verdict=%s",
                    self.job_id,
                    review.key,
                    review.verdict,
                )
                review = review.model_copy(update={"suggestedValue": None})
                normalized_output = True
            # An unresolvable citation is DROPPED, not fatal. Every other way a
            # model can miss this contract is already normalized and logged a few
            # lines up; failing the whole folder over one evidence line meant a
            # single retyped character threw away a completed extraction and both
            # comparison attempts.
            resolved: list[ModelEvidence] = []
            for evidence in review.evidence:
                source = evidence_index.get(
                    evidence_match_key(evidence.imageId, evidence.filename, evidence.observation)
                )
                if source is None:
                    logger.info(
                        "AI review discarded unresolvable evidence; job_id=%s field_key=%s image_id=%s",
                        self.job_id,
                        review.key,
                        evidence.imageId,
                    )
                    normalized_output = True
                    continue
                resolved.append(ModelEvidence(
                    imageId=int(source["imageId"]),
                    filename=str(source["filename"]),
                    observation=str(source["observation"]).strip(),
                ))
            if not resolved and (review.verdict == "mismatch" or downgraded_not_visible):
                # A mismatch must carry evidence - the contract check above says
                # so - and field_observations cannot be empty here, because a
                # mismatch on a field without observations was normalized away
                # earlier. So fall back to the observations for this very field:
                # the pool the comparer was citing from, and the only evidence
                # that exists. Better than dropping a real mismatch on the floor.
                # A field downgraded from not_visible needs the same treatment for
                # a different reason: the comparer thought there was nothing to
                # see, so it cited nothing, and the observations that prove
                # otherwise are precisely what the reviewer has to be shown.
                logger.info(
                    "AI review restored evidence for a field that cited none resolvable; "
                    "job_id=%s field_key=%s verdict=%s observations=%s",
                    self.job_id,
                    review.key,
                    review.verdict,
                    len(field_observations),
                )
                resolved = [
                    ModelEvidence(
                        imageId=int(item["imageId"]),
                        filename=str(item["filename"]),
                        observation=str(item["observation"]).strip(),
                    )
                    for item in field_observations
                ]
                normalized_output = True
            if list(review.evidence) != resolved:
                review = review.model_copy(update={"evidence": resolved})
                normalized_output = True
            normalized_reviews.append(review)
        if normalized_output:
            return parsed.model_copy(update={"fieldReviews": normalized_reviews})
        return parsed


def sanitize_comparison(snapshot: AiReviewSnapshot, comparison: ModelComparison) -> dict[str, Any]:
    fields = _template_fields(snapshot)
    image_map = {image.id: image for image in snapshot.images}
    reviews_by_key = {review.key: review for review in comparison.fieldReviews if review.key in fields}
    result_fields: list[dict[str, Any]] = []

    for key, field in fields.items():
        current = canonical_metadata_value(key, snapshot.metadata.get(key))
        review = reviews_by_key.get(key)
        if review is None:
            result_fields.append({
                "key": key,
                "currentValue": current,
                "suggestedValue": None,
                "verdict": "not_visible",
                "confidence": 0.0,
                "evidence": [],
            })
            continue

        confidence = max(0.0, min(1.0, float(review.confidence)))
        verdict = review.verdict
        suggested = canonical_metadata_value(key, review.suggestedValue)
        evidence = []
        for item in review.evidence:
            image = image_map.get(item.imageId)
            if image is None:
                continue
            evidence.append({
                "imageId": image.id,
                "filename": image.filename,
                "observation": item.observation.strip()[:500],
            })

        if key in DATE_FIELDS and suggested and not is_plausible_archive_date(suggested):
            suggested = None
            verdict = "uncertain"
        options = [str(value) for value in field.get("options") or []]
        if field.get("input") == "select" and suggested and suggested not in options:
            suggested = None
            verdict = "uncertain"
        if suggested and len(suggested) > 255:
            suggested = None
            verdict = "uncertain"
        if verdict == "mismatch" and (confidence < APPLY_CONFIDENCE or not suggested or suggested == current):
            verdict = "uncertain" if suggested != current else "match"
            suggested = None
        if verdict == "match" and confidence < APPLY_CONFIDENCE:
            verdict = "uncertain"
        if verdict in {"uncertain", "not_visible", "match"}:
            suggested = None

        result_fields.append({
            "key": key,
            "currentValue": current,
            "suggestedValue": suggested,
            "verdict": verdict,
            "confidence": confidence,
            "evidence": evidence,
        })

    if any(item["verdict"] == "mismatch" for item in result_fields):
        overall = "needs_review"
    elif result_fields and all(item["verdict"] == "match" for item in result_fields):
        overall = "consistent"
    else:
        overall = "insufficient_evidence"
    return {"overallStatus": overall, "fieldReviews": result_fields, "acceptedFields": []}


class AiReviewCoordinator:
    def __init__(self, provider_factory: Callable[[], OpenRouterReviewProvider] = OpenRouterReviewProvider) -> None:
        self.provider_factory = provider_factory
        self._manual_executor: ThreadPoolExecutor | None = self._new_executor("manual")
        self._preanalysis_executor: ThreadPoolExecutor | None = self._new_executor("preanalysis")
        self._request_semaphore = threading.BoundedSemaphore(settings.ai_review_max_concurrent_requests)
        self._lock = threading.RLock()
        self._running_job_ids: set[str] = set()
        self._resubmit_after_current_job_ids: set[str] = set()
        self._job_cancel_events: dict[str, threading.Event] = {}

    @staticmethod
    def _new_executor(trigger: AiReviewTrigger) -> ThreadPoolExecutor:
        workers = (
            settings.ai_review_manual_task_concurrency
            if trigger == "manual"
            else settings.ai_preanalysis_task_concurrency
        )
        return ThreadPoolExecutor(
            max_workers=workers,
            thread_name_prefix=f"lwcam-ai-{trigger}",
        )

    @staticmethod
    def _job_path(job_id: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise AiReviewNotFoundError("AI review job was not found.")
        return ai_review_root() / "jobs" / f"{job_id}.json"

    @staticmethod
    def _result_path(folder_id: int, input_hash: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{64}", input_hash):
            raise AiReviewNotFoundError("AI review result was not found.")
        return ai_review_root() / "results" / str(folder_id) / f"{input_hash}.json"

    def _load_job(self, job_id: str) -> dict[str, Any] | None:
        return _read_json(self._job_path(job_id))

    def _save_job(self, job: dict[str, Any]) -> None:
        job["updatedAt"] = utc_now_iso()
        _atomic_json_write(self._job_path(job["jobId"]), job)

    def _submit(self, job_id: str, *, resubmit_after_current: bool = False) -> None:
        with self._lock:
            if job_id in self._running_job_ids:
                if resubmit_after_current:
                    self._resubmit_after_current_job_ids.add(job_id)
                return
            job = self._load_job(job_id)
            if not job:
                return
            trigger: AiReviewTrigger = "preanalysis" if job.get("trigger") == "preanalysis" else "manual"
            executor = self._preanalysis_executor if trigger == "preanalysis" else self._manual_executor
            if executor is None:
                executor = self._new_executor(trigger)
                if trigger == "preanalysis":
                    self._preanalysis_executor = executor
                else:
                    self._manual_executor = executor
            self._job_cancel_events[job_id] = threading.Event()
            self._running_job_ids.add(job_id)
            executor.submit(self._run_job, job_id)

    def _request_job_cancellation(self, job: dict[str, Any], reason: str) -> None:
        job_id = str(job["jobId"])
        job["cancelRequested"] = True
        job["cancelReason"] = reason
        if job.get("status") == "queued":
            job["status"] = "cancelled"
        self._save_job(job)
        cancellation_event = self._job_cancel_events.get(job_id)
        if cancellation_event is not None:
            cancellation_event.set()

    def _cancel_superseded_manual_jobs(self, folder_id: int, input_hash: str) -> int:
        cancelled = 0
        jobs_dir = ai_review_root() / "jobs"
        for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).exists() else []:
            job = _read_json(path)
            if (
                not job
                or int(job.get("folderId", -1)) != folder_id
                or job.get("inputHash") == input_hash
                or (job.get("trigger") or "manual") != "manual"
                or job.get("status") not in {"queued", "running"}
            ):
                continue
            self._request_job_cancellation(job, "superseded_by_new_manual_check")
            cancelled += 1
        if cancelled:
            logger.info(
                "AI review superseded older manual jobs; folder_id=%s jobs=%s",
                folder_id,
                cancelled,
            )
        return cancelled

    def enqueue(
        self,
        snapshot: AiReviewSnapshot,
        *,
        trigger: AiReviewTrigger = "manual",
        force: bool = False,
    ) -> dict[str, Any]:
        if not settings.ai_review_enabled:
            raise AiReviewDisabledError("AI metadata review is disabled.")
        if not api_key_configured():
            raise AiReviewDisabledError("OpenRouter API key is not configured.")
        if not snapshot.images:
            raise AiReviewError("This task has no images to analyze.")
        if len(snapshot.images) > settings.ai_review_max_images:
            raise AiReviewError(
                f"AI metadata review supports at most {settings.ai_review_max_images} images per task."
            )

        with self._lock:
            self.cleanup_expired()
            result = _read_json(self._result_path(snapshot.folder_id, snapshot.input_hash))
            if result and not force:
                return _public_job(result)

            matching_failed: dict[str, Any] | None = None
            jobs_dir = ai_review_root() / "jobs"
            for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).exists() else []:
                job = _read_json(path)
                if not job or job.get("folderId") != snapshot.folder_id or job.get("inputHash") != snapshot.input_hash:
                    continue
                if job.get("status") in {"queued", "running"}:
                    self._submit(str(job["jobId"]))
                    return _public_job(job)
                if job.get("status") == "failed":
                    matching_failed = job

            if matching_failed and force:
                if trigger == "manual":
                    self._cancel_superseded_manual_jobs(snapshot.folder_id, snapshot.input_hash)
                matching_failed["status"] = "queued"
                matching_failed["trigger"] = trigger
                matching_failed["stage"] = "queued"
                matching_failed["stageStartedAt"] = utc_now_iso()
                matching_failed["cancelRequested"] = False
                matching_failed["cancelReason"] = None
                matching_failed["error"] = None
                self._save_job(matching_failed)
                self._submit(str(matching_failed["jobId"]), resubmit_after_current=True)
                return _public_job(matching_failed)
            if matching_failed and not force:
                return _public_job(matching_failed)

            now = utc_now_iso()
            if trigger == "manual":
                self._cancel_superseded_manual_jobs(snapshot.folder_id, snapshot.input_hash)
            job_id = uuid.uuid4().hex
            job = {
                "jobId": job_id,
                "folderId": snapshot.folder_id,
                "inputHash": snapshot.input_hash,
                "status": "queued",
                "stage": "queued",
                "stageStartedAt": now,
                "trigger": trigger,
                "cancelRequested": False,
                "cancelReason": None,
                "model": settings.openrouter_extract_model,
                "models": _configured_models(),
                "createdAt": now,
                "updatedAt": now,
                "progress": {"processedImages": 0, "totalImages": len(snapshot.images)},
                "error": None,
                "result": None,
                "snapshot": snapshot.to_dict(),
                "completedBatches": {},
            }
            self._save_job(job)
            self._submit(job_id)
            return _public_job(job)

    def active_preanalysis_count(self) -> int:
        return len(self.active_preanalysis_folder_ids(include_duplicates=True))

    def active_preanalysis_folder_ids(self, *, include_duplicates: bool = False) -> list[int]:
        folder_ids: list[int] = []
        with self._lock:
            jobs_dir = ai_review_root() / "jobs"
            for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).exists() else []:
                job = _read_json(path)
                if (
                    job
                    and job.get("trigger") == "preanalysis"
                    and job.get("status") in {"queued", "running"}
                    and not job.get("cancelRequested")
                ):
                    folder_ids.append(int(job["folderId"]))
        return folder_ids if include_duplicates else list(dict.fromkeys(folder_ids))

    def active_job_descriptors(self) -> list[dict[str, Any]]:
        """Return the minimum private job data needed for startup reconciliation."""
        descriptors: list[dict[str, Any]] = []
        with self._lock:
            jobs_dir = ai_review_root() / "jobs"
            for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).exists() else []:
                job = _read_json(path)
                if (
                    not job
                    or job.get("status") not in {"queued", "running"}
                    or job.get("cancelRequested")
                ):
                    continue
                snapshot = job.get("snapshot") or {}
                descriptors.append({
                    "jobId": str(job["jobId"]),
                    "folderId": int(job["folderId"]),
                    "trigger": job.get("trigger") or "manual",
                    "userId": snapshot.get("userId"),
                })
        return descriptors

    def has_known_preanalysis(self, snapshot: AiReviewSnapshot) -> bool:
        with self._lock:
            if _read_json(self._result_path(snapshot.folder_id, snapshot.input_hash)):
                return True
            jobs_dir = ai_review_root() / "jobs"
            for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).exists() else []:
                job = _read_json(path)
                if (
                    job
                    and int(job.get("folderId", -1)) == snapshot.folder_id
                    and job.get("inputHash") == snapshot.input_hash
                    and job.get("status") in {"queued", "running", "succeeded", "failed"}
                ):
                    return True
        return False

    def cancel_active_jobs(
        self,
        folder_id: int,
        *,
        reason: str,
        triggers: set[AiReviewTrigger] | None = None,
    ) -> int:
        cancelled = 0
        with self._lock:
            jobs_dir = ai_review_root() / "jobs"
            for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).exists() else []:
                job = _read_json(path)
                if (
                    not job
                    or int(job.get("folderId", -1)) != folder_id
                    or job.get("status") not in {"queued", "running"}
                    or (triggers is not None and (job.get("trigger") or "manual") not in triggers)
                ):
                    continue
                self._request_job_cancellation(job, reason)
                cancelled += 1
        if cancelled:
            logger.info(
                "AI review cancellation requested; folder_id=%s jobs=%s triggers=%s reason=%s",
                folder_id,
                cancelled,
                sorted(triggers) if triggers is not None else "all",
                reason,
            )
        return cancelled

    def cancel_job(self, job_id: str, *, reason: str) -> int:
        """Cancel one active job without affecting another job for the same folder."""
        with self._lock:
            job = self._load_job(job_id)
            if not job or job.get("status") not in {"queued", "running"}:
                return 0
            self._request_job_cancellation(job, reason)
            folder_id = int(job["folderId"])
            trigger = job.get("trigger") or "manual"
        logger.info(
            "AI review cancellation requested; folder_id=%s job_id=%s trigger=%s reason=%s",
            folder_id,
            job_id,
            trigger,
            reason,
        )
        return 1

    def cancel_preanalysis(self, folder_id: int, *, reason: str) -> int:
        """Compatibility wrapper for callers that only target background jobs."""
        return self.cancel_active_jobs(folder_id, reason=reason, triggers={"preanalysis"})

    def get_job(self, folder_id: int, job_id: str, *, current_input_hash: str | None = None) -> dict[str, Any]:
        job = self._load_job(job_id)
        if not job or int(job.get("folderId", -1)) != folder_id:
            raise AiReviewNotFoundError("AI review job was not found.")
        stale = bool(current_input_hash and job.get("inputHash") != current_input_hash)
        return _public_job(job, stale=stale)

    def queue_visibility(self, folder_ids: list[int]) -> dict[int, str]:
        """Per folder: "ready", "failed" or "waiting".

        Decides which pending folders a QC operator may see while the station
        reviews every folder automatically. Reading is deliberately shallow -
        two directory passes, no snapshot and no input-hash per folder - because
        this runs on every queue refresh, and building a snapshot means stat-ing
        every page of every pending folder.

        The cost of that shortcut: a folder whose stored review is STALE still
        counts as ready. For an unclaimed pending folder its inputs barely move,
        and the reviewer is told plainly when findings are out of date, so
        showing it beats stat-ing hundreds of files every thirty seconds.

        "failed" is as visible as "ready" on purpose. A review that has given up
        must not hold work back: the folder appears and is claimed normally, just
        without findings.
        """
        wanted = set(folder_ids)
        state = {folder_id: "waiting" for folder_id in wanted}

        results_root = ai_review_root() / "results"
        for folder_id in wanted:
            folder_dir = results_root / str(folder_id)
            if fs_path(folder_dir).is_dir() and any(fs_path(folder_dir).glob("*.json")):
                state[folder_id] = "ready"

        # One pass over the jobs directory rather than one per folder.
        jobs_dir = ai_review_root() / "jobs"
        live: set[int] = set()
        dead: set[int] = set()
        for path in fs_path(jobs_dir).glob("*.json") if fs_path(jobs_dir).is_dir() else []:
            job = _read_json(path)
            if not job:
                continue
            try:
                folder_id = int(job.get("folderId"))
            except (TypeError, ValueError):
                continue
            if folder_id not in wanted:
                continue
            status = job.get("status")
            if status in {"queued", "running"}:
                live.add(folder_id)
            elif status in {"failed", "cancelled"}:
                dead.add(folder_id)

        for folder_id in wanted:
            if state[folder_id] == "ready":
                continue
            # A job still working outranks an older one that gave up: the
            # in-flight attempt may yet produce findings.
            if folder_id in live:
                state[folder_id] = "waiting"
            elif folder_id in dead:
                state[folder_id] = "failed"
        return state

    def latest(self, snapshot: AiReviewSnapshot) -> dict[str, Any] | None:
        exact_result = _read_json(self._result_path(snapshot.folder_id, snapshot.input_hash))
        if exact_result:
            return _public_job(exact_result)

        jobs_dir = ai_review_root() / "jobs"
        jobs = []
        if fs_path(jobs_dir).exists():
            for path in fs_path(jobs_dir).glob("*.json"):
                job = _read_json(path)
                if job and int(job.get("folderId", -1)) == snapshot.folder_id:
                    jobs.append(job)
        exact_jobs = [job for job in jobs if job.get("inputHash") == snapshot.input_hash]
        if exact_jobs:
            latest = max(exact_jobs, key=lambda item: str(item.get("updatedAt", "")))
            return _public_job(latest)

        result_dir = ai_review_root() / "results" / str(snapshot.folder_id)
        old_results = []
        if fs_path(result_dir).exists():
            for path in fs_path(result_dir).glob("*.json"):
                result = _read_json(path)
                if result:
                    old_results.append(result)
        if old_results:
            latest = max(old_results, key=lambda item: str(item.get("updatedAt", "")))
            return _public_job(latest, stale=True)
        return None

    def result_for_apply(self, folder_id: int, input_hash: str) -> dict[str, Any]:
        result = _read_json(self._result_path(folder_id, input_hash))
        if not result or result.get("status") != "succeeded" or not result.get("result"):
            raise AiReviewNotFoundError("AI review result was not found.")
        return result

    def record_acceptance(self, folder_id: int, input_hash: str, field_keys: list[str], user_id: str) -> None:
        with self._lock:
            path = self._result_path(folder_id, input_hash)
            result = _read_json(path)
            if not result or not result.get("result"):
                return
            accepted = list(result["result"].get("acceptedFields") or [])
            result["result"]["acceptedFields"] = list(dict.fromkeys([*accepted, *field_keys]))
            result.setdefault("acceptanceActions", []).append({
                "at": utc_now_iso(),
                "userId": user_id,
                "fieldKeys": field_keys,
            })
            result["updatedAt"] = utc_now_iso()
            _atomic_json_write(path, result)
            job_path = self._job_path(str(result["jobId"]))
            job = _read_json(job_path)
            if job:
                job["result"] = result["result"]
                self._save_job(job)

    def resume_if_needed(self) -> None:
        with self._lock:
            self.cleanup_expired()
            self._cleanup_temp_files()
            jobs_dir = ai_review_root() / "jobs"
            if not fs_path(jobs_dir).exists():
                return
            can_resume = ai_review_available()
            for path in fs_path(jobs_dir).glob("*.json"):
                job = _read_json(path)
                if not job or job.get("status") not in {"queued", "running"}:
                    continue
                if job.get("cancelRequested"):
                    job["status"] = "cancelled"
                    self._save_job(job)
                    continue
                if not can_resume:
                    continue
                try:
                    snapshot = AiReviewSnapshot.from_dict(job.get("snapshot") or {})
                    current_input_hash = calculate_input_hash(
                        snapshot.metadata,
                        snapshot.template,
                        snapshot.images,
                        snapshot.draft_version,
                    )
                except (KeyError, TypeError, ValueError, OSError):
                    job["status"] = "cancelled"
                    job["cancelRequested"] = True
                    job["cancelReason"] = "no_longer_reviewable_on_resume"
                    job["result"] = None
                    job["error"] = None
                    self._save_job(job)
                    continue
                if current_input_hash != job.get("inputHash"):
                    job["status"] = "cancelled"
                    job["cancelRequested"] = True
                    job["cancelReason"] = "analysis_configuration_changed_on_resume"
                    job["result"] = None
                    job["error"] = None
                    self._save_job(job)
                    continue
                job["model"] = settings.openrouter_extract_model
                job["models"] = _configured_models()
                job["status"] = "queued"
                job["stage"] = "queued"
                job["stageStartedAt"] = utc_now_iso()
                self._save_job(job)
                self._submit(str(job["jobId"]))

    @staticmethod
    def _cleanup_temp_files() -> None:
        temp_root = ai_review_root() / "tmp"
        if not fs_path(temp_root).exists():
            return
        # Walked from the prefixed root, so `path` below is already
        # extended-form for every syscall - no need to re-wrap it.
        for path in fs_path(temp_root).iterdir():
            try:
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink(missing_ok=True)
            except OSError:
                logger.warning("AI review temporary file cleanup failed; path=%s", path.name)

    def cleanup_expired(self) -> None:
        root = ai_review_root()
        cutoff = utc_now() - timedelta(days=settings.ai_review_cache_retention_days)
        for directory in (root / "jobs", root / "results"):
            if not fs_path(directory).exists():
                continue
            for path in fs_path(directory).rglob("*.json"):
                try:
                    modified = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
                    if modified < cutoff:
                        path.unlink(missing_ok=True)
                except OSError:
                    continue

    def shutdown(self) -> None:
        with self._lock:
            manual_executor = self._manual_executor
            preanalysis_executor = self._preanalysis_executor
            self._manual_executor = None
            self._preanalysis_executor = None
            self._resubmit_after_current_job_ids.clear()
        for executor in (manual_executor, preanalysis_executor):
            if executor is not None:
                executor.shutdown(wait=True, cancel_futures=False)

    def _set_stage(self, job_id: str, stage: AiReviewStage) -> dict[str, Any] | None:
        with self._lock:
            job = self._load_job(job_id)
            if not job:
                return None
            if job.get("stage") != stage:
                job["stage"] = stage
                job["stageStartedAt"] = utc_now_iso()
                self._save_job(job)
            return job

    def _cancel_if_requested(self, job_id: str) -> bool:
        with self._lock:
            job = self._load_job(job_id)
            if not job:
                return True
            if job.get("status") != "cancelled" and not job.get("cancelRequested"):
                return False
            job["status"] = "cancelled"
            job["cancelRequested"] = True
            job["result"] = None
            job["error"] = None
            self._save_job(job)
            return True

    def _run_job(self, job_id: str) -> None:
        started = time.monotonic()
        cancellation_event: threading.Event | None = None
        try:
            with self._lock:
                cancellation_event = self._job_cancel_events.setdefault(job_id, threading.Event())
                job = self._load_job(job_id)
                if not job:
                    return
                if job.get("status") == "cancelled" or job.get("cancelRequested"):
                    job["status"] = "cancelled"
                    job["cancelRequested"] = True
                    self._save_job(job)
                    return
                job["status"] = "running"
                job["error"] = None
                self._save_job(job)

            snapshot = AiReviewSnapshot.from_dict(job["snapshot"])
            try:
                created_at = datetime.fromisoformat(str(job["createdAt"]))
                queue_wait = max(0.0, (utc_now() - created_at).total_seconds())
            except (KeyError, TypeError, ValueError):
                queue_wait = 0.0
            logger.info(
                "AI review started; folder_id=%s job_id=%s trigger=%s queue_wait_seconds=%.2f images=%s",
                snapshot.folder_id,
                job_id,
                job.get("trigger") or "manual",
                queue_wait,
                len(snapshot.images),
            )
            for image in snapshot.images:
                stat = fs_path(image.path).stat()
                if stat.st_size != image.size or stat.st_mtime_ns != image.mtime_ns:
                    raise AiReviewError("An image changed before AI analysis started.")

            provider = self.provider_factory()
            if hasattr(provider, "request_semaphore"):
                provider.request_semaphore = self._request_semaphore
            if hasattr(provider, "cancellation_event"):
                provider.cancellation_event = cancellation_event
            if hasattr(provider, "job_id"):
                provider.job_id = job_id
            batch_size = settings.ai_review_batch_size
            batches = [list(snapshot.images[index:index + batch_size]) for index in range(0, len(snapshot.images), batch_size)]
            completed = dict(job.get("completedBatches") or {})
            missing_indexes = [index for index in range(len(batches)) if str(index) not in completed]

            wave_size = settings.ai_review_batch_concurrency
            if missing_indexes:
                self._set_stage(job_id, "extracting")
            for wave_start in range(0, len(missing_indexes), wave_size):
                if self._cancel_if_requested(job_id):
                    return
                wave = missing_indexes[wave_start:wave_start + wave_size]
                first_batch_error: Exception | None = None
                with ThreadPoolExecutor(
                    max_workers=min(wave_size, len(wave)),
                    thread_name_prefix="lwcam-ai-batch",
                ) as executor:
                    future_map = {
                        executor.submit(provider.extract_batch, snapshot, batches[index]): index
                        for index in wave
                    }
                    for future in as_completed(future_map):
                        index = future_map[future]
                        try:
                            observations = future.result()
                        except Exception as error:
                            first_batch_error = first_batch_error or error
                            continue
                        if self._cancel_if_requested(job_id):
                            return
                        with self._lock:
                            job = self._load_job(job_id)
                            if not job:
                                return
                            completed = dict(job.get("completedBatches") or {})
                            completed[str(index)] = observations
                            job["completedBatches"] = completed
                            processed = sum(len(batches[int(item)]) for item in completed)
                            job["progress"] = {
                                "processedImages": processed,
                                "totalImages": len(snapshot.images),
                            }
                            self._save_job(job)
                if self._cancel_if_requested(job_id):
                    return
                if first_batch_error is not None:
                    raise first_batch_error

            ordered_observations = []
            for index in range(len(batches)):
                ordered_observations.extend(completed.get(str(index), []))
            if self._cancel_if_requested(job_id):
                return
            self._set_stage(job_id, "comparing")
            comparison = provider.compare(snapshot, ordered_observations)
            result = sanitize_comparison(snapshot, comparison)
            if self._cancel_if_requested(job_id):
                return

            for image in snapshot.images:
                stat = fs_path(image.path).stat()
                if stat.st_size != image.size or stat.st_mtime_ns != image.mtime_ns:
                    raise AiReviewError("An image changed during AI analysis.")

            with self._lock:
                job = self._load_job(job_id)
                if not job:
                    return
                if job.get("status") == "cancelled" or job.get("cancelRequested"):
                    job["status"] = "cancelled"
                    job["result"] = None
                    job["error"] = None
                    self._save_job(job)
                    return
                job["status"] = "succeeded"
                job["progress"] = {
                    "processedImages": len(snapshot.images),
                    "totalImages": len(snapshot.images),
                }
                job["result"] = result
                job["error"] = None
                self._save_job(job)
                _atomic_json_write(self._result_path(snapshot.folder_id, snapshot.input_hash), _public_job(job))
            logger.info(
                "AI review completed; folder_id=%s job_id=%s trigger=%s extract_model=%s "
                "compare_model=%s images=%s elapsed_seconds=%.2f",
                snapshot.folder_id,
                job_id,
                job.get("trigger") or "manual",
                settings.openrouter_extract_model,
                settings.openrouter_compare_model,
                len(snapshot.images),
                time.monotonic() - started,
            )
        except AiReviewCancelledError as error:
            logger.info(
                "AI review cancelled; job_id=%s cancellation_point=%s elapsed_seconds=%.2f",
                job_id,
                error.cancellation_point,
                time.monotonic() - started,
            )
            self._cancel_if_requested(job_id)
        except Exception as error:
            logger.error("AI review failed; job_id=%s error_type=%s", job_id, type(error).__name__)
            with self._lock:
                job = self._load_job(job_id)
                if job:
                    if job.get("status") == "cancelled" or job.get("cancelRequested"):
                        job["status"] = "cancelled"
                        job["result"] = None
                        job["error"] = None
                    else:
                        job["status"] = "failed"
                        if isinstance(error, AiReviewTimeoutError):
                            job["error"] = "AI analysis timed out. Force retry."
                        elif isinstance(error, AiReviewError) and str(error).strip():
                            # Already worded for the operator (see
                            # describe_provider_failure and the image checks).
                            job["error"] = str(error).strip()
                        else:
                            job["error"] = "AI analysis failed. Retry later."
                    self._save_job(job)
        finally:
            with self._lock:
                self._running_job_ids.discard(job_id)
                if self._job_cancel_events.get(job_id) is cancellation_event:
                    self._job_cancel_events.pop(job_id, None)
                should_resubmit = job_id in self._resubmit_after_current_job_ids
                self._resubmit_after_current_job_ids.discard(job_id)
                if should_resubmit:
                    self._submit(job_id)


ai_review_coordinator = AiReviewCoordinator()


__all__ = [
    "ANALYZED_FIELDS",
    "APPLY_CONFIDENCE",
    "AiReviewCoordinator",
    "AiReviewCancelledError",
    "AiReviewDisabledError",
    "AiReviewError",
    "AiReviewNotFoundError",
    "AiReviewSnapshot",
    "AiReviewTimeoutError",
    "OpenRouterReviewProvider",
    "ai_review_coordinator",
    "calculate_input_hash",
    "canonical_metadata_value",
    "is_plausible_archive_date",
    "sanitize_comparison",
]
