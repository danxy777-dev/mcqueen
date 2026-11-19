"""Rotas conversacionais `/chat`, `/chat/stream` e gestão de sessão isolada."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, StreamingResponse

from app.config import load_settings
from app.models import ChatRequest, ChatResponse, SessionClearResponse
from app.security import (
    extract_session_owner_hash,
    get_client_ip,
    verify_optional_client_token,
)
from app.services.llm_service import LlmServiceError, execute_chat_turn, stream_chat_turn
from session_store import SessionAccessDeniedError

router = APIRouter()


def _json_error(
    status_code: int,
    error_code: str,
    detail: str,
    headers: dict[str, str] | None = None,
) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"error_code": error_code, "detail": detail},
        headers=headers,
    )


def _check_access_and_rate_limit(
    request: Request,
    *,
    session_id: str | None = None,
    enforce_rate_limit: bool = True,
) -> JSONResponse | None:
    settings = load_settings()
    if not verify_optional_client_token(request, settings.client_token):
        return _json_error(
            401,
            "unauthorized_client",
            "Token de acesso do aplicativo inválido ou ausente.",
        )

    if enforce_rate_limit:
        limiter = request.app.state.rate_limiter
        limiter.configure(
            settings.rate_limit_requests,
            settings.rate_limit_window_seconds,
        )
        ip = get_client_ip(request)
        owner = extract_session_owner_hash(request)
        scope = owner[:16] if owner else (session_id or "anon")
        allowed, retry_after = limiter.check(f"{ip}:{scope}")
        if not allowed:
            return _json_error(
                429,
                "rate_limit_exceeded",
                "Muitas requisições em sequência. Aguarde alguns segundos antes de enviar outra mensagem.",
                headers={"Retry-After": str(retry_after)},
            )
    return None


@router.delete("/sessions/{session_id}", response_model=SessionClearResponse)
async def clear_session(session_id: str, request: Request) -> Any:
    access_error = _check_access_and_rate_limit(request, enforce_rate_limit=False)
    if access_error is not None:
        return access_error

    owner_hash = extract_session_owner_hash(request)
    memory_store = request.app.state.memory_store
    try:
        cleared = memory_store.clear_session(session_id, owner_token_hash=owner_hash)
    except SessionAccessDeniedError:
        return _json_error(
            403,
            "session_forbidden",
            "Esta sessão pertence a outro dispositivo.",
        )
    return SessionClearResponse(ok=True, session_id=session_id, cleared=cleared)


@router.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest, request: Request) -> Any:
    access_error = _check_access_and_rate_limit(request, session_id=req.session_id)
    if access_error is not None:
        return access_error

    client, cfg = request.app.state.create_llm_client()
    if client is None:
        return _json_error(
            503,
            "missing_api_key",
            "Chave da API de IA não configurada no servidor (defina OPENAI_API_KEY ou LLM_API_KEY nas variáveis de ambiente).",
        )

    owner_hash = extract_session_owner_hash(request)
    memory_store = request.app.state.memory_store

    try:
        result = await execute_chat_turn(
            client=client,
            cfg=cfg,
            memory_store=memory_store,
            session_id=req.session_id,
            user_text=req.message,
            state_dict=req.robot_state.model_dump(),
            owner_token_hash=owner_hash,
        )
    except SessionAccessDeniedError:
        return _json_error(
            403,
            "session_forbidden",
            "Esta sessão pertence a outro dispositivo. Inicie uma nova conversa.",
        )
    except LlmServiceError as exc:
        return _json_error(exc.status_code, exc.error_code, exc.detail)

    return ChatResponse(**result)


@router.post("/chat/stream")
async def chat_stream(req: ChatRequest, request: Request) -> Any:
    access_error = _check_access_and_rate_limit(request, session_id=req.session_id)
    if access_error is not None:
        return access_error

    client, cfg = request.app.state.create_llm_client()
    if client is None:
        return _json_error(
            503,
            "missing_api_key",
            "Chave da API de IA não configurada no servidor (defina OPENAI_API_KEY ou LLM_API_KEY nas variáveis de ambiente).",
        )

    owner_hash = extract_session_owner_hash(request)
    memory_store = request.app.state.memory_store

    # Valida posse da sessão antes de abrir o stream SSE.
    try:
        memory_store.get_history(req.session_id, owner_token_hash=owner_hash)
    except SessionAccessDeniedError:
        return _json_error(
            403,
            "session_forbidden",
            "Esta sessão pertence a outro dispositivo. Inicie uma nova conversa.",
        )

    return StreamingResponse(
        stream_chat_turn(
            client=client,
            cfg=cfg,
            memory_store=memory_store,
            session_id=req.session_id,
            user_text=req.message,
            state_dict=req.robot_state.model_dump(),
            owner_token_hash=owner_hash,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
