"""Modelos Pydantic de entrada e saída da API McQueen AI."""

from __future__ import annotations

import re
from typing import Any

from pydantic import BaseModel, Field, field_validator

_SESSION_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")


class RobotStatePayload(BaseModel):
    ble_connected: bool = False
    speed_mode: str = "Normal"
    speed_percent: int = Field(default=60, ge=0, le=100)
    turn_signal: str = "OFF"
    expression: str = "NORMAL"
    sounds_enabled: bool = True
    is_moving: bool = False


class ChatRequest(BaseModel):
    session_id: str = Field(default="default", min_length=1, max_length=64)
    message: str = Field(..., min_length=1, max_length=1000)
    robot_state: RobotStatePayload = Field(default_factory=RobotStatePayload)

    @field_validator("session_id")
    @classmethod
    def validate_session_id(cls, v: str) -> str:
        cleaned = v.strip()
        if not _SESSION_ID_RE.fullmatch(cleaned):
            raise ValueError(
                "session_id deve conter apenas letras, números, '_', '.', ':' ou '-' (até 64 chars)."
            )
        return cleaned

    @field_validator("message")
    @classmethod
    def validate_message(cls, v: str) -> str:
        cleaned = v.strip()
        if not cleaned:
            raise ValueError("A mensagem não pode ser vazia.")
        return cleaned


class ChatResponse(BaseModel):
    reply: str
    intents: list[dict[str, Any]] = Field(default_factory=list)
    blocked_intents: list[dict[str, Any]] = Field(default_factory=list)
    model: str
    provider: str = "openai"
    session_id: str


class HealthResponse(BaseModel):
    ok: bool = True
    status: str
    configured: bool
    provider: str
    model: str
    environment: str
    version: str
    timestamp_utc: str
    capabilities: dict[str, bool] = Field(default_factory=dict)
    limits: dict[str, int | float] = Field(default_factory=dict)


class StatusResponse(BaseModel):
    ok: bool = True
    service: str = "mcqueen-ai-backend"
    status: str
    configured: bool
    provider: str
    model: str
    environment: str
    version: str
    uptime_seconds: float
    active_sessions: int
    memory_max_turns: int
    session_ttl_seconds: int
    rate_limit_requests: int
    rate_limit_window_seconds: int
    cors_restricted: bool
    stream_supported: bool = True
    tool_count: int


class SessionClearResponse(BaseModel):
    ok: bool = True
    session_id: str
    cleared: bool


class ErrorResponse(BaseModel):
    error_code: str
    detail: str
