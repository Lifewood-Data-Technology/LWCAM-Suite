"""Server settings for the QC Platform backend (the `settings` singleton).

One Settings class holds every tunable: database login, JWT, preview/work/audit
folders, AI review, export, and network binding/TLS. Values come from defaults,
then a dev .env, then the config.txt overrides that
app.core.server_settings.load_server_settings_overrides() returns (config.txt
keys are camelCase, fields here are snake_case). Settings are read once at
process start. Secrets have no usable default on purpose. The long comments on
the AI review fields record measurements behind the chosen defaults.
"""
from functools import cached_property
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import URL

from app.core.server_settings import load_server_settings_overrides


DEVELOPMENT_JWT_SECRET = "lwcam-dev-secret-change-in-production-min-32-chars"
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def is_loopback_bind_host(host: str) -> bool:
    return host.strip().lower() in _LOOPBACK_HOSTS


def db_sslmode(host: str, use_ssl: bool = False) -> str:
    """TLS is required for every non-local database host (encrypted, certificate
    not verified - the server's is self-signed). Only loopback may fall back to
    plain text, and only when dbUseSsl is not true."""
    local = str(host).strip().strip("[]").lower() in ("localhost", "127.0.0.1", "::1")
    return "require" if use_ssl or not local else "prefer"


class Settings(BaseSettings):
    # hide_input_in_errors: a jwtSecret that fails min_length would otherwise be
    # echoed verbatim in the startup error, SecretStr or not.
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="ignore", hide_input_in_errors=True
    )

    app_name: str = "LWCam Python Backend"
    app_env: str = "production"
    app_debug: bool = False
    api_prefix: str = "/api"

    db_host: str = "localhost"
    db_port: int = 5432
    db_name: str = "lwcam"
    db_user: str = "postgres"
    # No default. It comes from dbPassword in config.txt (or DB_PASSWORD in a
    # dev .env). A baked-in default is a credential in source control, and one
    # that silently "works" is worse than a connection error saying what to set.
    db_password: SecretStr = SecretStr("")
    db_use_ssl: bool = False

    jwt_secret: SecretStr = Field(min_length=32, default=SecretStr(DEVELOPMENT_JWT_SECRET))
    jwt_algorithm: str = "HS256"
    # Honoured in app/core/security.py's create_access_token (the `exp` claim),
    # overridable per server as jwtExpireMinutes in config.txt. 480 (8h) was
    # sized for one operator logging in once a shift. Left as-is: shortening it
    # is a security/usability trade for a LAN deployment that belongs to
    # whoever runs the site, not a default to change silently.
    jwt_expire_minutes: int = Field(default=480, ge=5, le=1440)
    preview_cache_dir: str = ".cache/previews"
    # The cache self-invalidates (the key includes source path/size/mtime AND
    # the pending-ops chain), so most of what accumulates here is already
    # unreachable garbage from an earlier edit. previews.py sweeps it back
    # under this cap by mtime rather than leaving it to grow forever.
    preview_cache_max_mb: int = Field(default=2048, ge=1)
    qc_work_dir: str = ".cache/qc_work"
    qc_audit_dir: str = ".cache/qc_audit"
    ai_review_cache_dir: str = ".cache/ai_review"
    luminance_enabled: bool = False
    ai_review_enabled: bool = False
    ai_review_max_images: int = Field(default=200, ge=1)
    ai_review_batch_size: int = Field(default=5, ge=1, le=20)
    ai_review_cache_retention_days: int = Field(default=30, ge=1)
    ai_review_image_max_edge: int = Field(default=2048, ge=512, le=4096)
    ai_preanalysis_enabled: bool = False
    ai_preanalysis_scan_interval_seconds: int = Field(default=30, ge=5)
    ai_preanalysis_queue_limit: int = Field(default=20, ge=1)
    ai_preanalysis_scan_batch_size: int = Field(default=20, ge=1)
    ai_preanalysis_task_concurrency: int = Field(default=1, ge=1, le=8)
    ai_review_manual_task_concurrency: int = Field(default=2, ge=1, le=8)
    ai_review_batch_concurrency: int = Field(default=2, ge=1, le=8)
    ai_review_max_concurrent_requests: int = Field(default=4, ge=1, le=32)
    ai_review_extract_timeout_seconds: float = Field(default=300.0, gt=0)
    # The wall clock for a REASONING attempt only, and the thing that bounds what
    # an operator waits. The reasoning-off retry still gets the full
    # ai_review_extract_timeout_seconds above, so a slow-but-working fallback is
    # never cut short by this.
    # Reasoning either converges quickly on a folder or not at all: folder 7
    # finished in 77s, folders 13 and 15 were still deliberating at 186s and
    # 208s and produced nothing. Waiting the full 300s to discover that costs the
    # operator three minutes and still ends in the fallback. Bailing at 80s costs
    # 80s + the ~11s the reasoning-off retry takes, and the worst case becomes a
    # result in ~91s instead of an error in ~200s.
    # This ONLY works because a wall timeout now triggers the same reasoning-off
    # retry as a length failure; without that the cap just fails sooner.
    ai_review_reasoning_timeout_seconds: float = Field(default=80.0, gt=0)
    ai_review_compare_timeout_seconds: float = Field(default=90.0, gt=0)
    ai_review_request_attempts: int = Field(default=2, ge=1, le=5)
    # Sampling. Extraction returned 8, 16 and 1 observations on the SAME eight
    # pages under the same field contract - a 16x swing - because no sampling
    # parameter was ever sent and the provider's own default (typically 0.7-1.0)
    # applied. Reading a page and judging whether it matches the metadata has no
    # use for improvisation, and without a fixed value a prompt change cannot be
    # told apart from luck.
    # 0.6/0.95 are this model family's own recommended values, NOT zero. Greedy
    # decoding was tried and is actively harmful here: the extract model emits
    # reasoning tokens, and with no sampling randomness it deliberates instead of
    # converging - extraction went from ~36s to 90s to two consecutive 180s
    # wall-clock timeouts, while returning FEWER observations. A pinned known
    # value still beats the provider's unknown default, which is what shipped
    # before; bit-identical runs are simply not available from a reasoning model.
    ai_review_temperature: float = Field(default=0.6, ge=0.0, le=2.0)
    ai_review_top_p: float = Field(default=0.95, gt=0.0, le=1.0)
    # Sent on BOTH stages. Nothing was sent before, so the provider's own default
    # applied: job 292d36adc3fc4ae999791ce106e01532 (folder 3, 4 images) spent
    # 173.65s reasoning, ran out of output tokens mid-JSON and raised
    # LengthFinishReasonError - which the retry filter below does not classify as
    # retryable, so the job failed outright having produced nothing.
    # 32768 is ~5x the largest ANSWER this workload has been observed to need
    # (5667 tokens, folder 7). It is deliberately NOT the model's maximum
    # (235929): asking for far more than the work needs concentrates routing on
    # fewer providers for no gain.
    ai_review_max_tokens: int = Field(default=32768, ge=256)
    # The thinking budget, and the reason raising ai_review_max_tokens alone did
    # NOT fix LengthFinishReasonError. Sending `reasoning: {"enabled": True}` with
    # no budget means "medium effort", which for a budget-style model (Qwen maps
    # this to thinking_budget) is derived as ~50% of the top-level max_tokens - so
    # every increase to that ceiling handed half of it straight back to the
    # deliberation, and job e3f2c89e5f91484ca49b32b32060c709 still truncated after
    # 188.40s on a 4-image folder. OpenRouter's own rule is that the top-level
    # max_tokens "must be strictly higher than the reasoning budget", which an
    # implied 50% share only barely satisfies.
    # Raised 8192 -> 10240 to give a folder that nearly converges the room to
    # finish: folder 7 landed at 7358, close enough to the old cap that a
    # slightly harder page would not have made it. Kept modest on purpose - it is
    # taken out of the same ai_review_max_tokens ceiling the answer draws on, and
    # a reasoning attempt is now bailed at ai_review_reasoning_timeout_seconds
    # anyway, so quota beyond what fits in that window buys nothing.
    # This does NOT prevent LengthFinishReasonError. Folders 13 and 15 wanted far
    # more deliberation than any sane quota; what keeps them producing a result
    # is the reasoning-off retry, not this number.
    ai_review_reasoning_max_tokens: int = Field(default=10240, ge=1024)
    # Off by default ON PURPOSE. `provider.require_parameters` is sent as True to
    # guarantee json_schema support, which means OpenRouter routes only to
    # providers supporting EVERY parameter in the request - and `seed` is not
    # universally supported. Setting it shrinks the eligible pool, concentrating
    # load on fewer backends and inviting the 429s already seen in production.
    # Turn it on deliberately, and watch the rate-limit rate when you do.
    ai_review_seed: int | None = None
    ai_review_provider_sort: Literal["price", "throughput", "latency"] = "throughput"
    # "enabled", not "auto": under "auto" no `reasoning` key is sent at all and
    # the provider's default behaviour applies, which is what produced the
    # original untracked failure. Explicit means the request states its intent
    # and the reasoning_mode= field in the log reports something meaningful.
    ai_review_extract_reasoning_mode: Literal["auto", "enabled", "disabled"] = "enabled"
    ai_review_compare_reasoning_mode: Literal["auto", "enabled", "disabled"] = "disabled"
    ai_review_extract_output_mode: Literal["json_schema", "json_object", "prompt_json"] = "json_schema"
    ai_review_compare_output_mode: Literal["json_schema", "json_object", "prompt_json"] = "json_schema"
    openrouter_api_key: SecretStr | None = None
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    openrouter_extract_model: str = "qwen/qwen3-vl-8b-instruct"
    openrouter_compare_model: str = "qwen/qwen3.5-flash-02-23"
    export_temp_dir: str = ""
    export_output_dir: str = ""
    export_csv_encoding: str = "utf-8"
    export_csv_line_ending: str = "CRLF"
    # Worker processes for the export's TIFF conversion and hashing. 0 means
    # size it from the hardware, using LWIP's own rule so the two agree on what
    # this machine can take: every core but one, capped at 61 (Windows cannot
    # wait on more handles than that).
    #
    # Deliberately unconstrained here. It is hand-typed (config.txt), and a
    # Field(ge=0, le=61) would turn a typo into a failed ENGINE STARTUP - the
    # whole of QC down because someone typed 200. export_worker_count() clamps
    # it into range instead.
    export_worker_count: int = 0
    # True publishes one <GroupID>.zip; False publishes a <GroupID>/ folder with
    # the same contents. Which one a project needs is the ingest team's call, not
    # a station's, so it is per-station configuration rather than a code branch.
    export_zip_output: bool = True
    # Whether export converts to TIFF at all. True is lossless delivery, what
    # every station produced before the toggle existed, so any other default
    # would silently change the output of every station that upgrades onto
    # this field. False re-encodes edited pages as q100 JPEG.
    export_tiff_output: bool = True
    export_temp_retention_hours: int = Field(default=24, ge=1)
    # Approving a folder is the operator's last act; nothing else on the station
    # can start an export (every export route is admin-gated, and QC operators
    # are not admins), so the server exports approved folders itself.
    export_auto_enabled: bool = True
    export_auto_interval_seconds: int = Field(default=30, ge=5)

    # Where QC finds captured folders when it is not the machine that captured
    # them. Empty - the default, and correct on a single-PC station - means use
    # the path LWCAM recorded. Set it to the share the images are reachable at
    # (\nas\LWCamCapture) and paths.relocate_under keeps each folder's own
    # date-and-name tail while replacing the head. One setting rather than the
    # host/container pair, because the engine does not need to be told what the
    # capture PC used to call the folder - only where it is now.
    qc_images_root: str = ""

    # The old host/container remap pair, which only Station Setup's node config
    # ever set. Retired in favour of qc_images_root: config.txt has no key for
    # them, so they stay blank and paths.to_local passes paths through.
    capture_image_host_path: str = ""
    capture_image_container_path: str = ""

    # --- Who can reach this process, and how ---------------------------------
    # Read once at process start: the process is already listening and
    # CORS-checking under the old values, so a live change would do nothing
    # until restart. A restart is the honest way to change a trust boundary.
    # The installer sets bindHost = 0.0.0.0 to serve the LAN; the loopback
    # default keeps a dev checkout private. main.py refuses a non-loopback bind
    # while jwt_secret is still the development default.
    bind_host: str = "127.0.0.1"
    port: int = 8080
    # https: both set = serve https (run_server.py); blank = plain http.
    tls_cert_file: str = ""
    tls_key_file: str = ""
    # Comma-separated explicit origins. The console is same-origin (it calls
    # /api on the server that served it) and dev uses the Vite proxy, so this
    # is normally blank: loopback then keeps the localhost-any-port regex, and
    # a LAN bind gets no CORS at all rather than a regex any page could match
    # by claiming to be localhost.
    cors_allowed_origins: str = ""
    # The built SPA (frontend/dist, sibling to backend/ in the repo and the
    # install). Relative to the working directory; main.py mounts it only if it
    # exists, so a backend-only checkout still starts.
    frontend_dist_dir: str = "../frontend/dist"

    @cached_property
    def database_url(self) -> URL:
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password.get_secret_value(),
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
            query={"sslmode": db_sslmode(self.db_host, self.db_use_ssl)},
        )


settings = Settings(**load_server_settings_overrides())
