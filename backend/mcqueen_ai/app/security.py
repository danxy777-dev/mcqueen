"""Utilitários de segurança: saneamento de logs, rate limit, CORS e isolamento de sessão."""

from __future__ import annotations

from collections import deque
import hashlib
import hmac
import json
import logging
import re
import threading
import time
from typing import Any

from fastapi import Request

_SECRET_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{8,}"), "[REDACTED_OPENAI_KEY]"),
    (re.compile(r"\bAIza[A-Za-z0-9_-]{8,}"), "[REDACTED_GOOGLE_KEY]"),
    (re.compile(r"\bAQ\.[A-Za-z0-9._-]{8,}"), "[REDACTED_GOOGLE_AUTH_KEY]"),
    (re.compile(r"\bgsk_[A-Za-z0-9_-]{8,}"), "[REDACTED_GROQ_KEY]"),
    (re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"), "Bearer [REDACTED_TOKEN]"),
    (re.compile(r"(?i)(api_key|token|secret|password)=([^\s&\"']+)"), r"\1=[REDACTED]"),
)


def scrub_secrets(text: str) -> str:
    """Remove possíveis chaves/tokens de mensagens antes de logar."""
    cleaned = text
    for pattern, replacement in _SECRET_PATTERNS:
        cleaned = pattern.sub(replacement, cleaned)
    return cleaned


class _StructuredLogFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%SZ"),
            "level": record.levelname,
            "logger": record.name,
            "msg": scrub_secrets(record.getMessage()),
        }
        request_id = getattr(record, "request_id", None)
        if request_id:
            payload["request_id"] = request_id
        return json.dumps(payload, ensure_ascii=False)


def configure_logging(level_name: str = "INFO") -> logging.Logger:
    """Configura logger estruturado do serviço sem vazar segredos."""
    level = getattr(logging, level_name.upper(), logging.INFO)
    logger = logging.getLogger("mcqueen_ai")
    logger.setLevel(level)
    if not logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(_StructuredLogFormatter())
        logger.addHandler(handler)
    logger.propagate = False
    return logger


def get_client_ip(request: Request) -> str:
    """Obtém identificador de rede considerando proxy reverso HTTPS (Render)."""
    forwarded = request.headers.get("x-forwarded-for", "").strip()
    if forwarded:
        first_hop = forwarded.split(",")[0].strip()
        if first_hop:
            return first_hop[:64]
    if request.client and request.client.host:
        return str(request.client.host)[:64]
    return "unknown"


def hash_token(token: str) -> str:
    """Gera hash SHA-256 irreversível para comparação e posse de sessão."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def extract_session_owner_hash(request: Request) -> str | None:
    """Extrai o token opaco do cliente (`X-Session-Token`) em forma hasheada."""
    raw = (request.headers.get("x-session-token") or "").strip()
    if not raw:
        return None
    if len(raw) > 256:
        raw = raw[:256]
    return hash_token(raw)


def verify_optional_client_token(request: Request, configured_token: str) -> bool:
    """Valida token opcional de acesso do app caso configurado no ambiente."""
    if not configured_token:
        return True
    header_token = (request.headers.get("x-client-token") or "").strip()
    if not header_token:
        auth_header = (request.headers.get("authorization") or "").strip()
        if auth_header.lower().startswith("bearer "):
            header_token = auth_header[7:].strip()
    if not header_token:
        return False
    return hmac.compare_digest(header_token.encode("utf-8"), configured_token.encode("utf-8"))


class SlidingWindowRateLimiter:
    """Rate limiter thread-safe em memória para proteger contra abuso e excesso de chamadas."""

    def __init__(self, max_requests: int = 30, window_seconds: int = 60, max_keys: int = 5000) -> None:
        self._max_requests = max(1, max_requests)
        self._window_seconds = max(1, window_seconds)
        self._max_keys = max(100, max_keys)
        self._lock = threading.Lock()
        self._buckets: dict[str, deque[float]] = {}

    def configure(self, max_requests: int, window_seconds: int) -> None:
        with self._lock:
            self._max_requests = max(1, max_requests)
            self._window_seconds = max(1, window_seconds)

    def reset(self) -> None:
        with self._lock:
            self._buckets.clear()

    def check(self, key: str) -> tuple[bool, int]:
        """Verifica se a requisição é permitida; retorna `(allowed, retry_after_seconds)`."""
        now = time.monotonic()
        cutoff = now - self._window_seconds

        with self._lock:
            if len(self._buckets) >= self._max_keys and key not in self._buckets:
                self._prune_empty_locked(cutoff)

            bucket = self._buckets.setdefault(key, deque())
            while bucket and bucket[0] <= cutoff:
                bucket.popleft()

            if len(bucket) >= self._max_requests:
                oldest = bucket[0]
                retry_after = max(1, int((oldest + self._window_seconds) - now) + 1)
                return False, retry_after

            bucket.append(now)
            return True, 0

    def _prune_empty_locked(self, cutoff: float) -> None:
        stale_keys = [
            k
            for k, dq in self._buckets.items()
            if not dq or dq[-1] <= cutoff
        ]
        for k in stale_keys:
            del self._buckets[k]
        if len(self._buckets) >= self._max_keys:
            # Remove a chave mais ociosa para manter uso de RAM limitado.
            oldest_key = min(
                self._buckets,
                key=lambda k: self._buckets[k][-1] if self._buckets[k] else 0.0,
            )
            del self._buckets[oldest_key]
