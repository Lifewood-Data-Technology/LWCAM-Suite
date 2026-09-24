from fastapi import APIRouter

from app.routers import admin, auth, export, qc

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(admin.router)
api_router.include_router(export.router)
api_router.include_router(qc.router)
