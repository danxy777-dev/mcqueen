"""Configuração centralizada e segura para ambiente local e produção em nuvem (Render)."""

from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent.parent
SERVICE_VERSION = "2.0.0"

_PLACEHOLDER_KEYS = {
    "",
    "coloque-sua-chave-aqui",
    "your-api-key-here",
    "changeme",
    "sua-chave-aqui",
}


def load_local_env() -> None:
    """Carrega `.env` local somente se existir; na nuvem usa env vars da plataforma."""
    env_path = BASE_DIR / ".env"
    if env_path.is_file():
        load_dotenv(dotenv_path=env_path, override=False)


def _clamp_int_env(name: str, default: int, low: int, high: int) -> int:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        val = int(raw)
    except ValueError:
        return default
    return max(low, min(high, val))


def _clamp_float_env(name: str, default: float, low: float, high: float) -> float:
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        val = float(raw)
    except ValueError:
        return default
    return max(low, min(high, val))


def _normalize_base_url(base_url: str) -> str:
    cleaned = base_url.strip()
    if not cleaned:
        return ""
    lower = cleaned.lower().rstrip("/")
    if lower.endswith("/chat/completions"):
        cleaned = cleaned[: -len("/chat/completions")].rstrip("/")
        lower = cleaned.lower()
    if "generativelanguage.googleapis.com" in lower:
        if lower.endswith("/v1beta"):
            cleaned = f"{cleaned.rstrip('/')}/openai/"
        elif lower.endswith("/openai"):
            cleaned = f"{cleaned}/"
    return cleaned


def _detect_provider(base_url: str) -> str:
    lower = base_url.lower()
    if "generativelanguage.googleapis.com" in lower:
        return "gemini-openai-compat"
    if "api.groq.com" in lower:
        return "groq-openai-compat"
    if "11434" in lower or "localhost" in lower or "127.0.0.1" in lower:
        return "local-openai-compat"
    if base_url:
        return "custom-openai-compat"
    return "openai"


def _parse_allowed_origins(raw: str, is_production: bool) -> list[str]:
    items = [o.strip().rstrip("/") for o in raw.split(",") if o.strip()]
    if is_production:
        # Nunca libera CORS wildcard (*) em produção.
        return [o for o in items if o != "*"]
    if items:
        return items
    return [
        "http://localhost",
        "http://localhost:3000",
        "http://localhost:8080",
        "http://127.0.0.1",
        "http://127.0.0.1:8000",
    ]


@dataclass(frozen=True)
class AppSettings:
    environment: str
    is_production: bool
    api_key: str
    base_url: str
    model: str
    provider: str
    configured: bool
    allow_empty_key: bool
    llm_timeout_seconds: float
    allowed_origins: list[str]
    client_token: str
    session_max_turns: int
    session_ttl_seconds: int
    max_sessions: int
    rate_limit_requests: int
    rate_limit_window_seconds: int
    log_level: str


def load_settings() -> AppSettings:
    """Lê configuração atual das variáveis de ambiente sem expor segredos."""
    load_local_env()

    is_render = os.getenv("RENDER", "").strip().lower() == "true"
    raw_env = os.getenv("ENVIRONMENT", "production" if is_render else "development")
    environment = raw_env.strip().lower() or "development"
    is_production = environment in {"production", "prod"}

    api_key = (os.getenv("LLM_API_KEY") or os.getenv("OPENAI_API_KEY") or "").strip()
    if api_key.lower() in _PLACEHOLDER_KEYS:
        api_key = ""

    base_url = _normalize_base_url(os.getenv("LLM_BASE_URL") or "")
    model = (os.getenv("LLM_MODEL") or "gpt-4o-mini").strip() or "gpt-4o-mini"

    raw_allow_empty = os.getenv("LLM_ALLOW_EMPTY_KEY", "false").strip().lower() == "true"
    # Em produção não permite modo sem chave, exceto override explícito para gateway privado.
    allow_empty_key = (not is_production) and raw_allow_empty

    provider = _detect_provider(base_url)
    configured = bool(api_key) or (allow_empty_key and bool(base_url))

    if configured and not api_key:
        effective_key = "local-no-key"
    else:
        effective_key = api_key

    allowed_origins = _parse_allowed_origins(
        os.getenv("ALLOWED_ORIGINS", ""),
        is_production=is_production,
    )
    client_token = (
        os.getenv("MCQUEEN_CLIENT_TOKEN") or os.getenv("APP_SHARED_SECRET") or ""
    ).strip()

    return AppSettings(
        environment=environment,
        is_production=is_production,
        api_key=effective_key,
        base_url=base_url,
        model=model,
        provider=provider,
        configured=configured,
        allow_empty_key=allow_empty_key,
        llm_timeout_seconds=_clamp_float_env("LLM_TIMEOUT_SECONDS", 18.0, 3.0, 60.0),
        allowed_origins=allowed_origins,
        client_token=client_token,
        session_max_turns=_clamp_int_env("MCQUEEN_SESSION_MAX_TURNS", 10, 1, 50),
        session_ttl_seconds=_clamp_int_env("MCQUEEN_SESSION_TTL_SECONDS", 3600, 60, 86400),
        max_sessions=_clamp_int_env("MCQUEEN_MAX_SESSIONS", 1000, 10, 20000),
        rate_limit_requests=_clamp_int_env("RATE_LIMIT_REQUESTS", 30, 3, 600),
        rate_limit_window_seconds=_clamp_int_env("RATE_LIMIT_WINDOW_SECONDS", 60, 10, 3600),
        log_level=(os.getenv("LOG_LEVEL") or "INFO").strip().upper() or "INFO",
    )


def get_llm_public_config(settings: AppSettings | None = None) -> dict[str, str | bool | float]:
    """Retorna apenas metadados não sensíveis sobre a configuração LLM."""
    s = settings or load_settings()
    return {
        "configured": s.configured,
        "provider": s.provider,
        "model": s.model,
        "environment": s.environment,
        "timeout_seconds": s.llm_timeout_seconds,
    }
