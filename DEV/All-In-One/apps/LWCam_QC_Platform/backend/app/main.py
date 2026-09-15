from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.core.config import settings
from app.core.errors import register_exception_handlers
from app.routers import api_router
from app.services.ai_preanalysis import ai_preanalysis_scheduler
from app.services.ai_review import ai_review_coordinator
from app.services.export import (
    export_auto_scheduler,
    export_coordinator,
    shutdown_conversion_pool,
)
from app.services.upload import upload_scheduler


@asynccontextmanager
async def lifespan(_: FastAPI):
    export_coordinator.resume_if_needed()
    ai_preanalysis_scheduler.reconcile_active_jobs()
    ai_review_coordinator.resume_if_needed()
    ai_preanalysis_scheduler.start()
    export_auto_scheduler.start()
    upload_scheduler.start()
    try:
        yield
    finally:
        ai_preanalysis_scheduler.stop()
        export_auto_scheduler.stop()
        upload_scheduler.stop()
        shutdown_conversion_pool()
        ai_review_coordinator.shutdown()


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        debug=settings.app_debug,
        openapi_url=f"{settings.api_prefix}/openapi.json",
        docs_url="/docs",
        redoc_url="/redoc",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origin_regex=r"http://(localhost|127\.0\.0\.1):\d+",
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    register_exception_handlers(app)
    app.include_router(api_router, prefix=settings.api_prefix)
    return app


app = create_app()

