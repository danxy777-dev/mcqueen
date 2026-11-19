"""Endpoints públicos de saúde e diagnóstico operacional sem expor credenciais."""

from __future__ import annotations

from datetime import datetime, timezone
import time

from fastapi import APIRouter, HTTPException, Request

from app.config import SERVICE_VERSION, get_llm_public_config, load_settings
from app.models import HealthResponse, StatusResponse
from app.security import verify_optional_client_token
from tools_schema import ROBOT_TOOLS

router = APIRouter()
_STARTED_AT = time.monotonic()


def _resolve_public_cfg(request: Request) -> dict[str, object]:
    resolver = getattr(request.app.state, "get_llm_config", None)
    if callable(resolver):
        return dict(resolver())
    return dict(get_llm_public_config())


@router.get("/")
async def root_info(request: Request) -> dict[str, object]:
    """Resumo leve para acessos diretos ao domínio raiz na nuvem."""
    cfg = _resolve_public_cfg(request)
    return {
        "service": "mcqueen-ai-backend",
        "version": SERVICE_VERSION,
        "status": "ok" if bool(cfg.get("configured")) else "needs_configuration",
        "endpoints": ["/health", "/status", "/chat", "/chat/stream"],
    }


@router.get("/health", response_model=HealthResponse)
async def health(request: Request) -> HealthResponse:
    """Health check para Render e sonda de disponibilidade do aplicativo."""
    settings = load_settings()
    cfg = _resolve_public_cfg(request)
    configured = bool(cfg.get("configured", False))

    return HealthResponse(
        ok=True,
        status="ok" if configured else "degraded",
        configured=configured,
        provider=str(cfg.get("provider", settings.provider)),
        model=str(cfg.get("model", settings.model)),
        environment=settings.environment,
        version=SERVICE_VERSION,
        timestamp_utc=datetime.now(timezone.utc).isoformat(),
        capabilities={
            "chat": True,
            "stream": True,
            "status": True,
        },
        limits={
            "max_message_chars": 1000,
            "rate_limit_requests": settings.rate_limit_requests,
            "rate_limit_window_seconds": settings.rate_limit_window_seconds,
            "llm_timeout_seconds": settings.llm_timeout_seconds,
        },
    )


@router.get("/status", response_model=StatusResponse)
async def status(request: Request) -> StatusResponse:
    """Telemetria operacional segura do serviço em nuvem."""
    settings = load_settings()
    if not verify_optional_client_token(request, settings.client_token):
        raise HTTPException(status_code=401, detail="Token de acesso do cliente inválido ou ausente.")

    cfg = _resolve_public_cfg(request)
    configured = bool(cfg.get("configured", False))
    memory_store = request.app.state.memory_store

    return StatusResponse(
        ok=True,
        status="online" if configured else "needs_configuration",
        configured=configured,
        provider=str(cfg.get("provider", settings.provider)),
        model=str(cfg.get("model", settings.model)),
        environment=settings.environment,
        version=SERVICE_VERSION,
        uptime_seconds=round(time.monotonic() - _STARTED_AT, 2),
        active_sessions=memory_store.active_count(),
        memory_max_turns=settings.session_max_turns,
        session_ttl_seconds=settings.session_ttl_seconds,
        rate_limit_requests=settings.rate_limit_requests,
        rate_limit_window_seconds=settings.rate_limit_window_seconds,
        cors_restricted=bool(settings.allowed_origins),
        stream_supported=True,
        tool_count=len(ROBOT_TOOLS),
    )
