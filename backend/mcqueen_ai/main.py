"""Entrypoint FastAPI de produção e desenvolvimento para o backend McQueen AI."""

from __future__ import annotations

import os
import time
from typing import Any
import uuid

from fastapi import FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from openai import AsyncOpenAI
import uvicorn

from app.config import SERVICE_VERSION, get_llm_public_config, load_settings
from app.models import ChatRequest, ChatResponse, RobotStatePayload
from app.routes.chat import router as chat_router
from app.routes.health import router as health_router
from app.security import SlidingWindowRateLimiter, configure_logging
from session_store import ConversationMemoryStore

_settings = load_settings()
logger = configure_logging(_settings.log_level)

memory_store = ConversationMemoryStore(
    max_messages=_settings.session_max_turns * 2,
    ttl_seconds=_settings.session_ttl_seconds,
    max_sessions=_settings.max_sessions,
)
rate_limiter = SlidingWindowRateLimiter(
    max_requests=_settings.rate_limit_requests,
    window_seconds=_settings.rate_limit_window_seconds,
)


def _get_llm_config() -> dict[str, Any]:
    settings = load_settings()
    return {
        "api_key": settings.api_key,
        "base_url": settings.base_url,
        "model": settings.model,
        "provider": settings.provider,
        "configured": settings.configured,
        "timeout_seconds": settings.llm_timeout_seconds,
    }


def create_llm_client() -> tuple[AsyncOpenAI | None, dict[str, Any]]:
    cfg = _get_llm_config()
    if not cfg["configured"]:
        return None, cfg
    kwargs: dict[str, Any] = {
        "api_key": str(cfg["api_key"]),
        "timeout": float(cfg["timeout_seconds"]),
    }
    if cfg["base_url"]:
        kwargs["base_url"] = str(cfg["base_url"])
    return AsyncOpenAI(**kwargs), cfg


def create_app() -> FastAPI:
    settings = load_settings()
    application = FastAPI(
        title="McQueen AI Backend",
        version=SERVICE_VERSION,
        description="Gateway HTTPS seguro e conversacional (Tool Calling) para o robô McQueen.",
        docs_url=None if settings.is_production else "/docs",
        redoc_url=None if settings.is_production else "/redoc",
    )

    application.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
        allow_headers=[
            "Content-Type",
            "Authorization",
            "X-Client-Token",
            "X-Session-Token",
            "X-Request-ID",
        ],
    )

    # Mantém compatibilidade com monkeypatches em `main.create_llm_client`.
    application.state.memory_store = memory_store
    application.state.rate_limiter = rate_limiter
    application.state.create_llm_client = lambda: create_llm_client()
    application.state.get_llm_config = lambda: get_llm_public_config()

    @application.middleware("http")
    async def structured_request_logging(request: Request, call_next: Any) -> Any:
        request_id = (request.headers.get("x-request-id") or uuid.uuid4().hex[:12]).strip()
        started = time.perf_counter()
        response = await call_next(request)
        elapsed_ms = round((time.perf_counter() - started) * 1000.0, 1)
        response.headers["X-Request-ID"] = request_id
        logger.info(
            "%s %s -> %s (%.1f ms)",
            request.method,
            request.url.path,
            response.status_code,
            elapsed_ms,
            extra={"request_id": request_id},
        )
        return response

    @application.exception_handler(HTTPException)
    async def http_exception_handler(_: Request, exc: HTTPException) -> JSONResponse:
        error_code = "http_error"
        if exc.status_code == 401:
            error_code = "unauthorized_client"
        elif exc.status_code == 403:
            error_code = "forbidden"
        elif exc.status_code == 404:
            error_code = "not_found"
        elif exc.status_code == 429:
            error_code = "rate_limit_exceeded"
        return JSONResponse(
            status_code=exc.status_code,
            content={"error_code": error_code, "detail": str(exc.detail)},
        )

    @application.exception_handler(RequestValidationError)
    async def validation_exception_handler(_: Request, __: RequestValidationError) -> JSONResponse:
        return JSONResponse(
            status_code=422,
            content={
                "error_code": "validation_error",
                "detail": "Dados da requisição inválidos ou fora dos limites permitidos.",
            },
        )

    @application.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        logger.error("Unhandled error on %s: %s", request.url.path, type(exc).__name__)
        return JSONResponse(
            status_code=500,
            content={
                "error_code": "internal_server_error",
                "detail": "Erro interno no servidor McQueen AI. Tente novamente em instantes.",
            },
        )

    application.include_router(health_router)
    application.include_router(chat_router)
    return application


app = create_app()

__all__ = [
    "ChatRequest",
    "ChatResponse",
    "RobotStatePayload",
    "app",
    "create_app",
    "create_llm_client",
    "memory_store",
    "rate_limiter",
]


if __name__ == "__main__":
    host = os.getenv("MCQUEEN_AI_HOST", "0.0.0.0").strip() or "0.0.0.0"
    port = int(os.getenv("PORT", os.getenv("MCQUEEN_AI_PORT", "8000")))
    uvicorn.run("main:app", host=host, port=port, proxy_headers=True)
