"""Memória conversacional em memória por sessão com TTL, limite de sessões e isolamento por dono."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import hmac
import threading
import time
from typing import Any


class SessionAccessDeniedError(PermissionError):
    """Lançada quando uma sessão existente pertence a outro token de cliente."""


@dataclass
class _SessionEntry:
    updated_at: float
    messages: deque[dict[str, Any]]
    owner_token_hash: str | None = None


class ConversationMemoryStore:
    def __init__(
        self,
        max_messages: int = 20,
        ttl_seconds: int = 3600,
        max_sessions: int = 1000,
    ) -> None:
        self._max_messages = max(4, max_messages)
        self._ttl_seconds = max(60, ttl_seconds)
        self._max_sessions = max(10, max_sessions)
        self._lock = threading.Lock()
        self._sessions: dict[str, _SessionEntry] = {}

    def _purge_expired_locked(self, now: float) -> None:
        expired = [
            sid
            for sid, entry in self._sessions.items()
            if now - entry.updated_at > self._ttl_seconds
        ]
        for sid in expired:
            del self._sessions[sid]

    def _evict_if_full_locked(self) -> None:
        while len(self._sessions) >= self._max_sessions:
            oldest_sid = min(
                self._sessions,
                key=lambda sid: self._sessions[sid].updated_at,
            )
            del self._sessions[oldest_sid]

    @staticmethod
    def _assert_owner(entry: _SessionEntry, owner_token_hash: str | None) -> None:
        if entry.owner_token_hash is None:
            return
        if not owner_token_hash:
            raise SessionAccessDeniedError("Sessão protegida exige X-Session-Token.")
        if not hmac.compare_digest(entry.owner_token_hash, owner_token_hash):
            raise SessionAccessDeniedError("Sessão pertence a outro cliente.")

    def active_count(self) -> int:
        now = time.monotonic()
        with self._lock:
            self._purge_expired_locked(now)
            return len(self._sessions)

    def get_history(
        self,
        session_id: str,
        owner_token_hash: str | None = None,
    ) -> list[dict[str, Any]]:
        now = time.monotonic()
        with self._lock:
            self._purge_expired_locked(now)
            entry = self._sessions.get(session_id)
            if entry is None:
                return []
            self._assert_owner(entry, owner_token_hash)
            entry.updated_at = now
            return list(entry.messages)

    def append_turn(
        self,
        session_id: str,
        user_text: str,
        assistant_text: str,
        owner_token_hash: str | None = None,
    ) -> None:
        now = time.monotonic()
        with self._lock:
            self._purge_expired_locked(now)
            entry = self._sessions.get(session_id)
            if entry is None:
                self._evict_if_full_locked()
                entry = _SessionEntry(
                    updated_at=now,
                    messages=deque(maxlen=self._max_messages),
                    owner_token_hash=owner_token_hash,
                )
                self._sessions[session_id] = entry
            else:
                self._assert_owner(entry, owner_token_hash)
                entry.updated_at = now
            entry.messages.append({"role": "user", "content": user_text})
            entry.messages.append({"role": "assistant", "content": assistant_text})

    def clear_session(
        self,
        session_id: str,
        owner_token_hash: str | None = None,
    ) -> bool:
        with self._lock:
            entry = self._sessions.get(session_id)
            if entry is None:
                return False
            self._assert_owner(entry, owner_token_hash)
            del self._sessions[session_id]
            return True
