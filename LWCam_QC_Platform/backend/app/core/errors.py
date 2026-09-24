from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError
from sqlalchemy.exc import IntegrityError


class ApiCodes:
    SUCCESS = 0
    BAD_REQUEST = 400
    UNAUTHORIZED = 401
    FORBIDDEN = 403
    NOT_FOUND = 404
    CONFLICT = 409
    INTERNAL_ERROR = 500
    SERVICE_UNAVAILABLE = 503


class BusinessError(Exception):
    def __init__(
        self,
        code: int,
        message: str,
        http_status: int = status.HTTP_400_BAD_REQUEST,
        data: Any = None,
    ):
        self.code = code
        self.message = message
        self.http_status = http_status
        self.data = data


def error_response(code: int, message: str, http_status: int, data: Any = None) -> JSONResponse:
    return JSONResponse(
        status_code=http_status,
        content={"code": code, "message": message, "data": data},
    )


def register_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(BusinessError)
    async def handle_business_error(_: Request, exc: BusinessError) -> JSONResponse:
        return error_response(exc.code, exc.message, exc.http_status, exc.data)

    @app.exception_handler(RequestValidationError)
    async def handle_request_validation(_: Request, exc: RequestValidationError) -> JSONResponse:
        messages = [str(err.get("msg", "Invalid parameter")) for err in exc.errors()]
        return error_response(ApiCodes.BAD_REQUEST, "; ".join(messages), status.HTTP_400_BAD_REQUEST)

    @app.exception_handler(ValidationError)
    async def handle_validation(_: Request, exc: ValidationError) -> JSONResponse:
        messages = [str(err.get("msg", "Invalid parameter")) for err in exc.errors()]
        return error_response(ApiCodes.BAD_REQUEST, "; ".join(messages), status.HTTP_400_BAD_REQUEST)

    @app.exception_handler(IntegrityError)
    async def handle_integrity(_: Request, __: IntegrityError) -> JSONResponse:
        return error_response(
            ApiCodes.CONFLICT, "A unique constraint was violated.", status.HTTP_409_CONFLICT
        )

    @app.exception_handler(Exception)
    async def handle_unexpected(_: Request, __: Exception) -> JSONResponse:
        return error_response(
            ApiCodes.INTERNAL_ERROR,
            "Internal server error.",
            status.HTTP_500_INTERNAL_SERVER_ERROR,
        )

