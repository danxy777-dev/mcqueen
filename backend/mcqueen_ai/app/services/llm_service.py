"""Orquestração LLM, validação de ferramentas BLE e streaming SSE para o McQueen AI."""

from __future__ import annotations

from collections.abc import AsyncIterator
import json
import logging
from typing import Any

from openai import (
    APIConnectionError,
    APIError,
    APIStatusError,
    APITimeoutError,
    AuthenticationError,
    BadRequestError,
    InternalServerError,
    NotFoundError,
    PermissionDeniedError,
    RateLimitError,
    UnprocessableEntityError,
)

from prompts import BASE_SYSTEM_PROMPT, build_state_context
from session_store import ConversationMemoryStore
from tools_schema import ROBOT_TOOLS, ValidatedIntent, validate_tool_call

from app.security import scrub_secrets

logger = logging.getLogger("mcqueen_ai.llm")

_PREFERRED_GEMINI_FLASH_MODELS: tuple[str, ...] = (
    "gemini-3.8-flash",
    "gemini-3-flash-preview",
    "gemini-3.6-flash",
    "gemini-3.5-flash",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemini-2.0-flash",
)
_EXCLUDED_GEMINI_MODEL_PARTS: tuple[str, ...] = (
    "embedding",
    "imagen",
    "veo",
    "tts",
    "audio",
    "image",
    "omni",
    "aqa",
    "robotics",
    "computer-use",
    "deep-research",
)
_gemini_model_cache: dict[str, str] = {}


class LlmServiceError(Exception):
    """Erro mapeado para resposta HTTP segura sem expor detalhes internos."""

    def __init__(self, status_code: int, error_code: str, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.error_code = error_code
        self.detail = detail


def map_openai_error(exc: Exception) -> LlmServiceError:
    """Converte exceções do SDK OpenAI-compatível em respostas HTTP seguras em pt-BR."""
    safe_msg = scrub_secrets(str(exc))
    provider_status = getattr(exc, "status_code", None)
    logger.warning(
        "LLM provider error (%s, status=%s): %s",
        type(exc).__name__,
        provider_status,
        safe_msg,
    )

    if isinstance(exc, (AuthenticationError, PermissionDeniedError)):
        return LlmServiceError(
            401,
            "invalid_api_key",
            "Chave de API do provedor de IA inválida ou sem permissão no servidor.",
        )
    if isinstance(exc, RateLimitError):
        return LlmServiceError(
            429,
            "llm_rate_limit",
            "Limite de uso ou taxa do provedor de IA atingido temporariamente. Aguarde alguns segundos e tente novamente.",
        )
    if isinstance(exc, APITimeoutError):
        return LlmServiceError(
            504,
            "llm_timeout",
            "O provedor de IA demorou demais para responder. Tente novamente.",
        )
    if isinstance(exc, APIConnectionError):
        return LlmServiceError(
            503,
            "llm_unreachable",
            "Provedor de IA temporariamente inacessível pelo servidor.",
        )
    if isinstance(exc, NotFoundError):
        return LlmServiceError(
            502,
            "llm_model_not_found",
            "Modelo de IA ou endpoint não encontrado no provedor (HTTP 404). Verifique LLM_MODEL e LLM_BASE_URL.",
        )
    if isinstance(exc, (BadRequestError, UnprocessableEntityError)):
        return LlmServiceError(
            502,
            "llm_bad_request",
            f"O provedor de IA rejeitou a requisição (HTTP {provider_status or 400}). Verifique modelo e parâmetros.",
        )
    if isinstance(exc, (InternalServerError, APIStatusError)):
        code_str = f"HTTP {provider_status}" if provider_status else type(exc).__name__
        return LlmServiceError(
            502,
            "llm_api_error",
            f"Erro ao consultar o provedor de IA ({code_str}). Tente novamente em instantes.",
        )
    return LlmServiceError(
        502,
        "llm_api_error",
        "Erro temporário ao consultar o provedor de IA. Tente novamente em instantes.",
    )


def _message_to_assistant_dict(msg: Any) -> dict[str, Any]:
    if hasattr(msg, "model_dump") and callable(msg.model_dump):
        dumped = msg.model_dump(exclude_none=True)
        if isinstance(dumped, dict):
            dumped.setdefault("role", "assistant")
            return dumped

    tool_calls_payload = []
    for tc in getattr(msg, "tool_calls", None) or []:
        tool_calls_payload.append(
            {
                "id": tc.id,
                "type": "function",
                "function": {
                    "name": tc.function.name,
                    "arguments": tc.function.arguments,
                },
            }
        )
    out: dict[str, Any] = {
        "role": "assistant",
        "content": msg.content or "",
    }
    if tool_calls_payload:
        out["tool_calls"] = tool_calls_payload
    return out


def _validate_tool_calls(
    raw_tool_calls: list[Any],
    state_dict: dict[str, Any],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    """Valida tool calls, aplica prioridade de parada e prepara mensagens de retorno."""
    has_stop_priority = any(tc.function.name == "stop_robot" for tc in raw_tool_calls)
    accepted_intents: list[dict[str, Any]] = []
    blocked_intents: list[dict[str, Any]] = []
    tool_messages: list[dict[str, Any]] = []

    for tc in raw_tool_calls:
        try:
            parsed_args = json.loads(tc.function.arguments or "{}")
            if not isinstance(parsed_args, dict):
                parsed_args = {}
        except json.JSONDecodeError:
            parsed_args = {}

        if has_stop_priority and tc.function.name == "move_robot":
            intent = ValidatedIntent(
                tool="move_robot",
                arguments={},
                blocked=True,
                block_reason="Cancelado pela prioridade máxima de PARAR.",
            )
        else:
            intent = validate_tool_call(tc.function.name, parsed_args, state_dict)

        if intent.blocked:
            blocked_payload = {
                "tool": intent.tool,
                "reason": intent.block_reason or "Bloqueado por regra de segurança.",
            }
            blocked_intents.append(blocked_payload)
            tool_result: dict[str, Any] = {
                "accepted_for_ble": False,
                "blocked": True,
                "reason": blocked_payload["reason"],
            }
        else:
            accepted_intents.append(intent.to_api_dict())
            tool_result = {
                "accepted_for_ble": True,
                "validated_arguments": intent.arguments,
                "note": "Será executado pelo serviço BLE do app Flutter agora.",
            }

        tool_messages.append(
            {
                "role": "tool",
                "tool_call_id": tc.id,
                "content": json.dumps(tool_result, ensure_ascii=False),
            }
        )

    return accepted_intents, blocked_intents, tool_messages


def _fallback_tool_reply(
    raw_content: str | None,
    accepted_intents: list[dict[str, Any]],
    blocked_intents: list[dict[str, Any]],
) -> str:
    reply_text = (raw_content or "").strip()
    if reply_text:
        return reply_text
    if blocked_intents and not accepted_intents:
        return str(blocked_intents[0]["reason"])
    return "Combinado! Mandando esse comando para o McQueen agora."


def _build_prompt_messages(
    history: list[dict[str, Any]],
    state_dict: dict[str, Any],
    user_text: str,
) -> list[dict[str, Any]]:
    combined_system = f"{BASE_SYSTEM_PROMPT}\n\n{build_state_context(state_dict)}"
    return [
        {"role": "system", "content": combined_system},
        *history,
        {"role": "user", "content": user_text},
    ]


async def _resolve_gemini_fallback_models(
    client: Any,
    failed_model: str,
) -> list[str]:
    """Consulta `models.list()` na API Gemini e ordena modelos Flash compatíveis disponíveis."""
    models_res = getattr(getattr(client, "models", None), "list", None)
    if not callable(models_res):
        return []
    try:
        listed = await models_res()
    except Exception as exc:
        logger.warning("Gemini models.list() failed: %s", type(exc).__name__)
        return []

    items = getattr(listed, "data", None) or []
    available: list[str] = []
    for item in items:
        raw_id = str(getattr(item, "id", "") or "").strip()
        if not raw_id:
            continue
        clean_id = raw_id.removeprefix("models/")
        lower = clean_id.lower()
        if clean_id == failed_model or clean_id in available:
            continue
        if any(bad in lower for bad in _EXCLUDED_GEMINI_MODEL_PARTS):
            continue
        if "gemini" in lower:
            available.append(clean_id)

    if not available:
        return []

    ordered: list[str] = []
    for preferred in _PREFERRED_GEMINI_FLASH_MODELS:
        if preferred in available and preferred not in ordered:
            ordered.append(preferred)
    for m in available:
        if "flash" in m.lower() and m not in ordered:
            ordered.append(m)
    for m in available:
        if m not in ordered:
            ordered.append(m)
    return ordered[:4]


async def execute_chat_turn(
    *,
    client: Any,
    cfg: dict[str, Any],
    memory_store: ConversationMemoryStore,
    session_id: str,
    user_text: str,
    state_dict: dict[str, Any],
    owner_token_hash: str | None,
) -> dict[str, Any]:
    """Executa um turno completo de conversa + tool calling validado."""
    configured_model = str(cfg["model"])
    provider_name = str(cfg.get("provider", "openai"))
    model_name = (
        _gemini_model_cache.get(configured_model, configured_model)
        if provider_name == "gemini-openai-compat"
        else configured_model
    )
    history = memory_store.get_history(session_id, owner_token_hash=owner_token_hash)
    messages = _build_prompt_messages(history, state_dict, user_text)

    async def _create_completion(target_model: str) -> Any:
        return await client.chat.completions.create(
            model=target_model,
            messages=messages,
            tools=ROBOT_TOOLS,
            tool_choice="auto",
            temperature=0.7,
            max_tokens=650,
        )

    try:
        first = await _create_completion(model_name)
    except NotFoundError as exc:
        candidates = (
            await _resolve_gemini_fallback_models(client, model_name)
            if provider_name == "gemini-openai-compat"
            else []
        )
        if not candidates:
            raise map_openai_error(exc) from exc

        first = None
        last_err: Exception = exc
        for candidate in candidates:
            logger.info(
                "Gemini model '%s' returned 404; trying live available model '%s'",
                model_name,
                candidate,
            )
            try:
                first = await _create_completion(candidate)
                model_name = candidate
                _gemini_model_cache[configured_model] = candidate
                break
            except NotFoundError as next_nf:
                last_err = next_nf
                continue
            except (
                AuthenticationError,
                PermissionDeniedError,
                RateLimitError,
                APITimeoutError,
                APIConnectionError,
                BadRequestError,
                UnprocessableEntityError,
                InternalServerError,
                APIStatusError,
                APIError,
            ) as retry_exc:
                raise map_openai_error(retry_exc) from retry_exc

        if first is None:
            raise map_openai_error(last_err) from last_err
    except (
        AuthenticationError,
        PermissionDeniedError,
        RateLimitError,
        APITimeoutError,
        APIConnectionError,
        BadRequestError,
        UnprocessableEntityError,
        InternalServerError,
        APIStatusError,
        APIError,
    ) as exc:
        raise map_openai_error(exc) from exc

    assistant_msg = first.choices[0].message
    raw_tool_calls = getattr(assistant_msg, "tool_calls", None) or []

    if not raw_tool_calls:
        reply_text = (assistant_msg.content or "").strip()
        if not reply_text:
            reply_text = "Pode repetir? Não captei direito o que você falou."
        memory_store.append_turn(
            session_id,
            user_text,
            reply_text,
            owner_token_hash=owner_token_hash,
        )
        return {
            "reply": reply_text,
            "intents": [],
            "blocked_intents": [],
            "model": model_name,
            "provider": provider_name,
            "session_id": session_id,
        }

    accepted_intents, blocked_intents, tool_messages = _validate_tool_calls(
        raw_tool_calls,
        state_dict,
    )
    followup_messages = [
        *messages,
        _message_to_assistant_dict(assistant_msg),
        *tool_messages,
    ]

    reply_text = ""
    try:
        second = await client.chat.completions.create(
            model=model_name,
            messages=followup_messages,
            temperature=0.7,
            max_tokens=500,
        )
        reply_text = (second.choices[0].message.content or "").strip()
    except (APIError, APITimeoutError, APIConnectionError, RateLimitError) as exc:
        logger.warning("Follow-up LLM skipped (%s): %s", type(exc).__name__, scrub_secrets(str(exc)))
        reply_text = ""

    final_reply = _fallback_tool_reply(
        reply_text or assistant_msg.content,
        accepted_intents,
        blocked_intents,
    )
    memory_store.append_turn(
        session_id,
        user_text,
        final_reply,
        owner_token_hash=owner_token_hash,
    )
    return {
        "reply": final_reply,
        "intents": accepted_intents,
        "blocked_intents": blocked_intents,
        "model": model_name,
        "provider": provider_name,
        "session_id": session_id,
    }


def _format_sse(event: str, payload: dict[str, Any]) -> str:
    return f"event: {event}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"


async def stream_chat_turn(
    *,
    client: Any,
    cfg: dict[str, Any],
    memory_store: ConversationMemoryStore,
    session_id: str,
    user_text: str,
    state_dict: dict[str, Any],
    owner_token_hash: str | None,
) -> AsyncIterator[str]:
    """Transmite progresso, intenções validadas e resposta via Server-Sent Events (SSE)."""
    yield _format_sse("status", {"phase": "thinking"})

    try:
        result = await execute_chat_turn(
            client=client,
            cfg=cfg,
            memory_store=memory_store,
            session_id=session_id,
            user_text=user_text,
            state_dict=state_dict,
            owner_token_hash=owner_token_hash,
        )
    except LlmServiceError as exc:
        yield _format_sse(
            "error",
            {"error_code": exc.error_code, "detail": exc.detail},
        )
        return

    if result["intents"] or result["blocked_intents"]:
        yield _format_sse(
            "intents",
            {
                "intents": result["intents"],
                "blocked_intents": result["blocked_intents"],
            },
        )

    reply = result["reply"]
    if reply:
        yield _format_sse("delta", {"text": reply})

    yield _format_sse("done", result)
