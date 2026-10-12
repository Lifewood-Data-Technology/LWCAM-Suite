"""FastAPI application entry point for the QC Platform server.

Builds the app: CORS rules, error handlers, the /api routers, and the built
console (frontend/dist) served as a single-page app. The lifespan hook starts
the background sweeps (resume interrupted work, AI pre-analysis, auto export,
heartbeat). Normally launched through run_server.py (see the backend AGENTS.md
for why); running this file directly is plain http on settings.bind_host.
Router mounting order matters, see the SPA mount comment in create_app().
"""
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core import netlogin, server_settings
from app.core.config import DEVELOPMENT_JWT_SECRET, is_loopback_bind_host, settings
from app.core.errors import register_exception_handlers
from app.routers import api_router
from app.services.ai_preanalysis import ai_preanalysis_scheduler
from app.services.ai_review import ai_review_coordinator
from app.services import schema_check
from app.services.heartbeat import heartbeat_sweep
from app.services.sweep import PeriodicSweep
from app.services.export import (
    export_auto_scheduler,
    export_coordinator,
    shutdown_conversion_pool,
)


class _SpaStaticFiles(StaticFiles):
    """Static files, plus the history-mode fallback `html=True` does not give.

    The console's routes (/qc/tasks, /admin/exports, ...) exist only in the
    browser's router. The operator still reaches them directly - a refresh, a
    bookmark, a pasted link - and the server must answer those with index.html
    and let the client route, rather than 404ing a page that genuinely exists.

    The /api guard matters: this mount is registered last, so a real API route
    is matched before it ever gets here, but a MISTYPED one would otherwise
    fall through and be answered with the web app as a 200. An API that
    returns HTML for a wrong path is far harder to debug than one that 404s,
    so anything under the API prefix is left to fail as itself.
    """

    async def get_response(self, path: str, scope):
        # StaticFiles RAISES on a miss rather than returning a 404 response, so
        # this has to be a try/except - checking response.status_code never sees
        # it and the fallback silently never fires.
        try:
            return await super().get_response(path, scope)
        except StarletteHTTPException as exc:
            if exc.status_code != 404:
                raise
            # `path` arrives mount-relative, so the leading slash is gone.
            # Compared as a SEGMENT, not a prefix: a bare startswith("api")
            # would also swallow a real client route like /apiary or /api-docs
            # and 404 it as JSON instead of loading the console.
            api_segment = settings.api_prefix.strip("/")
            if api_segment and (path == api_segment or path.startswith(f"{api_segment}/")):
                raise
            return await super().get_response("index.html", scope)


_resumed = False


def resume_pending_work() -> None:
    """Picks up the export / AI jobs a restart interrupted, once, and only when
    the schema gate is open (they read the DB)."""
    global _resumed
    if _resumed or not schema_check.gate_ok("resume"):
        return
    export_coordinator.resume_if_needed()
    ai_preanalysis_scheduler.reconcile_active_jobs()
    ai_review_coordinator.resume_if_needed()
    _resumed = True


resume_sweep = PeriodicSweep("resume", tick=resume_pending_work, interval=lambda: 60.0)


@asynccontextmanager
async def lifespan(_: FastAPI):
    # First: the export resume below may already need a network folder.
    netlogin.start_keeper()
    resume_pending_work()
    resume_sweep.start()  # retries the resume if the DB was too old / away at start
    ai_preanalysis_scheduler.start()
    export_auto_scheduler.start()
    heartbeat_sweep.start()
    try:
        yield
    finally:
        ai_preanalysis_scheduler.stop()
        export_auto_scheduler.stop()
        heartbeat_sweep.stop()
        resume_sweep.stop()
        shutdown_conversion_pool()
        ai_review_coordinator.shutdown()


def create_app() -> FastAPI:
    if "jwtSecret" in server_settings.SECRET_PROBLEMS:
        # Falling back to the development secret would sign tokens with a
        # public key; say what is wrong instead.
        raise RuntimeError(server_settings.SECRET_PROBLEMS["jwtSecret"])
    if (
        not is_loopback_bind_host(settings.bind_host)
        and settings.jwt_secret.get_secret_value() == DEVELOPMENT_JWT_SECRET
    ):
        raise RuntimeError("Set jwtSecret before binding the QC server beyond loopback.")

    app = FastAPI(
        title=settings.app_name,
        debug=settings.app_debug,
        openapi_url=f"{settings.api_prefix}/openapi.json" if settings.app_debug else None,
        # The API map is for developers: off unless app_debug.
        docs_url="/docs" if settings.app_debug else None,
        redoc_url="/redoc" if settings.app_debug else None,
        lifespan=lifespan,
    )

    # The console is same-origin. Keep the localhost regex for Vite development;
    # a LAN bind with no configured origins does not enable cross-origin access.
    origins = [o.strip() for o in settings.cors_allowed_origins.split(",") if o.strip()]
    if origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=origins,
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )
    elif is_loopback_bind_host(settings.bind_host):
        app.add_middleware(
            CORSMiddleware,
            allow_origin_regex=r"http://(localhost|127\.0\.0\.1):\d+",
            allow_credentials=True,
            allow_methods=["*"],
            allow_headers=["*"],
        )

    # No TLS here, deliberately. This process may listen beyond loopback, but
    # terminating HTTPS is a reverse proxy's job, not this app's - do not read
    # "it now serves a LAN" as "it is safe to expose directly to anything less
    # trusted than that LAN."
    register_exception_handlers(app)
    app.include_router(api_router, prefix=settings.api_prefix)

    # SPA mount - MUST be added last, after include_router above.
    #
    # StaticFiles(..., html=True) does NOT give history-mode routing on its
    # own, which is easy to assume and wrong: `html=True` serves index.html
    # for a DIRECTORY request and 404s anything else, so /qc/tasks - a real
    # client-side route the operator reaches by refreshing or from a bookmark
    # - came back a raw JSON 404. Hence _SpaStaticFiles above.
    # Starlette matches routes in REGISTRATION order, and this mount's
    # catch-all "/" would happily "match" "/api/anything" too. `/docs`,
    # `/redoc` and `/openapi.json` are safe regardless of where this mount
    # sits - FastAPI registers them inside __init__, before create_app's body
    # (this function) ever runs - but every app.include_router(api_router,
    # ...) route is NOT safe: mount this before it and every "/api/*" call
    # would be swallowed by the SPA fallback and come back a 200 of
    # index.html instead of reaching a router or ever 404ing. Do not move
    # this above include_router, even to "tidy" the app-building order.
    frontend_dir = Path(settings.frontend_dist_dir).expanduser()
    if frontend_dir.is_dir():
        app.mount("/", _SpaStaticFiles(directory=frontend_dir, html=True), name="frontend")

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host=settings.bind_host, port=settings.port)

