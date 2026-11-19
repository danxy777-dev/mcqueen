"""Testes unitários e de integração do backend McQueen AI em nuvem."""

from __future__ import annotations

import json
from types import SimpleNamespace

from fastapi.testclient import TestClient
import httpx
from openai import (
    APIConnectionError,
    APITimeoutError,
    AuthenticationError,
    InternalServerError,
    NotFoundError,
    RateLimitError,
)

import main as backend_main
from app.security import scrub_secrets


def _fake_choice(content: str | None = None, tool_calls=None):
    msg = SimpleNamespace(content=content, tool_calls=tool_calls or [])
    return SimpleNamespace(choices=[SimpleNamespace(message=msg)])


def _fake_tc(tc_id: str, name: str, args: dict):
    return SimpleNamespace(
        id=tc_id,
        function=SimpleNamespace(name=name, arguments=json.dumps(args)),
    )


def _reset_runtime_state(monkeypatch):
    backend_main.rate_limiter.reset()
    monkeypatch.delenv("MCQUEEN_CLIENT_TOKEN", raising=False)
    monkeypatch.delenv("APP_SHARED_SECRET", raising=False)
    monkeypatch.delenv("RATE_LIMIT_REQUESTS", raising=False)
    monkeypatch.delenv("RATE_LIMIT_WINDOW_SECONDS", raising=False)


def test_health_unconfigured(monkeypatch):
    _reset_runtime_state(monkeypatch)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_ALLOW_EMPTY_KEY", raising=False)

    client = TestClient(backend_main.app)
    res = client.get("/health")
    assert res.status_code == 200
    data = res.json()
    assert data["ok"] is True
    assert data["configured"] is False
    assert data["status"] == "degraded"
    assert "api_key" not in data


def test_health_and_status_configured_never_expose_secrets(monkeypatch):
    _reset_runtime_state(monkeypatch)
    monkeypatch.setenv("LLM_API_KEY", "sk-secret-value-123456789")
    monkeypatch.setenv("LLM_MODEL", "gpt-4o-mini")

    client = TestClient(backend_main.app)
    h = client.get("/health")
    assert h.status_code == 200
    assert h.json()["configured"] is True
    assert h.json()["status"] == "ok"
    assert "sk-secret" not in h.text

    s = client.get("/status")
    assert s.status_code == 200
    s_json = s.json()
    assert s_json["status"] == "online"
    assert s_json["model"] == "gpt-4o-mini"
    assert s_json["stream_supported"] is True
    assert s_json["tool_count"] == 7
    assert "sk-secret" not in s.text


def test_chat_returns_503_when_no_api_key_never_fakes_ai(monkeypatch):
    _reset_runtime_state(monkeypatch)
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    monkeypatch.delenv("LLM_API_KEY", raising=False)
    monkeypatch.delenv("LLM_ALLOW_EMPTY_KEY", raising=False)

    client = TestClient(backend_main.app)
    res = client.post(
        "/chat",
        json={"session_id": "s1", "message": "Oi McQueen!"},
    )
    assert res.status_code == 503
    assert res.json()["error_code"] == "missing_api_key"


def test_chat_clamps_move_duration_and_preserves_session_memory(monkeypatch):
    _reset_runtime_state(monkeypatch)
    backend_main.memory_store.clear_session("mem-test")
    captured_calls = []

    class FakeCompletions:
        async def create(self, **kwargs):
            captured_calls.append(kwargs)
            if len(captured_calls) == 1:
                return _fake_choice(
                    tool_calls=[
                        _fake_tc(
                            "call_1",
                            "move_robot",
                            {"direction": "forward", "duration_ms": 99999, "speed_percent": 180},
                        )
                    ]
                )
            if len(captured_calls) == 2:
                return _fake_choice(content="Acelerando por 2,5 segundos com segurança!")
            return _fake_choice(content="Albert Einstein desenvolveu a teoria da relatividade.")

    fake_client = SimpleNamespace(
        chat=SimpleNamespace(completions=FakeCompletions())
    )
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"}),
    )

    client = TestClient(backend_main.app)
    r1 = client.post(
        "/chat",
        json={
            "session_id": "mem-test",
            "message": "Continue andando para frente!",
            "robot_state": {"ble_connected": True, "speed_mode": "Normal", "speed_percent": 60},
        },
    )
    assert r1.status_code == 200
    body1 = r1.json()
    assert len(body1["intents"]) == 1
    assert body1["intents"][0]["tool"] == "move_robot"
    assert body1["intents"][0]["arguments"]["duration_ms"] == 2500
    assert body1["intents"][0]["arguments"]["speed_percent"] == 100

    # Segunda chamada deve incluir histórico anterior
    r2 = client.post(
        "/chat",
        json={"session_id": "mem-test", "message": "Quem é Albert Einstein?"},
    )
    assert r2.status_code == 200
    sent_msgs = captured_calls[2]["messages"]
    assert any(m.get("content") == "Continue andando para frente!" for m in sent_msgs)

    del_res = client.delete("/sessions/mem-test")
    assert del_res.status_code == 200
    assert del_res.json()["cleared"] is True


def test_ble_disconnected_blocks_physical_intents(monkeypatch):
    _reset_runtime_state(monkeypatch)
    backend_main.memory_store.clear_session("disc-test")
    call_idx = 0

    class FakeCompletions:
        async def create(self, **kwargs):
            nonlocal call_idx
            call_idx += 1
            if call_idx == 1:
                return _fake_choice(
                    tool_calls=[_fake_tc("c1", "move_robot", {"direction": "forward"})]
                )
            return _fake_choice(content="Queria acelerar, mas estou desconectado do controle!")

    fake_client = SimpleNamespace(chat=SimpleNamespace(completions=FakeCompletions()))
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"}),
    )

    client = TestClient(backend_main.app)
    res = client.post(
        "/chat",
        json={
            "session_id": "disc-test",
            "message": "McQueen, avance!",
            "robot_state": {"ble_connected": False},
        },
    )
    assert res.status_code == 200
    body = res.json()
    assert body["intents"] == []
    assert len(body["blocked_intents"]) == 1
    assert "desconectado" in body["blocked_intents"][0]["reason"].lower()


def test_stop_robot_prioritizes_over_move_in_same_turn(monkeypatch):
    _reset_runtime_state(monkeypatch)
    backend_main.memory_store.clear_session("stop-prio")
    call_idx = 0

    class FakeCompletions:
        async def create(self, **kwargs):
            nonlocal call_idx
            call_idx += 1
            if call_idx == 1:
                return _fake_choice(
                    tool_calls=[
                        _fake_tc("c1", "move_robot", {"direction": "forward"}),
                        _fake_tc("c2", "stop_robot", {}),
                    ]
                )
            return _fake_choice(content="Freio total acionado!")

    fake_client = SimpleNamespace(chat=SimpleNamespace(completions=FakeCompletions()))
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"}),
    )

    client = TestClient(backend_main.app)
    res = client.post(
        "/chat",
        json={
            "session_id": "stop-prio",
            "message": "Avance... não, pare!",
            "robot_state": {"ble_connected": True},
        },
    )
    assert res.status_code == 200
    body = res.json()
    assert [i["tool"] for i in body["intents"]] == ["stop_robot"]
    assert body["blocked_intents"][0]["tool"] == "move_robot"


def test_session_isolation_blocks_hijack_and_delete(monkeypatch):
    _reset_runtime_state(monkeypatch)
    backend_main.memory_store._sessions.clear()

    class FakeCompletions:
        async def create(self, **kwargs):
            return _fake_choice(content="Tudo ótimo!")

    fake_client = SimpleNamespace(chat=SimpleNamespace(completions=FakeCompletions()))
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"}),
    )

    client = TestClient(backend_main.app)
    r_owner = client.post(
        "/chat",
        headers={"X-Session-Token": "token-usuario-A-seguro"},
        json={"session_id": "shared-id", "message": "Oi!"},
    )
    assert r_owner.status_code == 200

    # Outro usuário tentando usar mesmo session_id deve ser bloqueado (403)
    r_attacker = client.post(
        "/chat",
        headers={"X-Session-Token": "token-usuario-B-invasor"},
        json={"session_id": "shared-id", "message": "Qual foi a conversa?"},
    )
    assert r_attacker.status_code == 403
    assert r_attacker.json()["error_code"] == "session_forbidden"

    r_del_attacker = client.delete(
        "/sessions/shared-id",
        headers={"X-Session-Token": "token-usuario-B-invasor"},
    )
    assert r_del_attacker.status_code == 403

    r_del_owner = client.delete(
        "/sessions/shared-id",
        headers={"X-Session-Token": "token-usuario-A-seguro"},
    )
    assert r_del_owner.status_code == 200
    assert r_del_owner.json()["cleared"] is True


def test_rate_limit_enforced_with_429_and_retry_after(monkeypatch):
    _reset_runtime_state(monkeypatch)
    monkeypatch.setenv("RATE_LIMIT_REQUESTS", "3")
    monkeypatch.setenv("RATE_LIMIT_WINDOW_SECONDS", "60")

    class FakeCompletions:
        async def create(self, **kwargs):
            return _fake_choice(content="Acelerando!")

    fake_client = SimpleNamespace(chat=SimpleNamespace(completions=FakeCompletions()))
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"}),
    )

    client = TestClient(backend_main.app)
    headers = {"X-Session-Token": "rl-user-1"}
    for _ in range(3):
        ok_res = client.post(
            "/chat",
            headers=headers,
            json={"session_id": "rl-s1", "message": "Oi"},
        )
        assert ok_res.status_code == 200

    blocked = client.post(
        "/chat",
        headers=headers,
        json={"session_id": "rl-s1", "message": "Oi de novo"},
    )
    assert blocked.status_code == 429
    assert blocked.json()["error_code"] == "rate_limit_exceeded"
    assert int(blocked.headers["Retry-After"]) >= 1


def test_provider_errors_map_cleanly_without_leaking_secrets(monkeypatch):
    _reset_runtime_state(monkeypatch)
    dummy_req = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")

    def _raise_factory(exc_obj):
        class BrokenCompletions:
            async def create(self, **kwargs):
                raise exc_obj

        fake_client = SimpleNamespace(chat=SimpleNamespace(completions=BrokenCompletions()))
        return lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"})

    client = TestClient(backend_main.app)

    auth_resp = httpx.Response(401, request=dummy_req)
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        _raise_factory(AuthenticationError("Invalid sk-proj-secret12345678", response=auth_resp, body=None)),
    )
    r_auth = client.post("/chat", json={"session_id": "err-auth", "message": "Oi"})
    assert r_auth.status_code == 401
    assert r_auth.json()["error_code"] == "invalid_api_key"
    assert "sk-proj" not in r_auth.text

    rl_resp = httpx.Response(429, request=dummy_req)
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        _raise_factory(RateLimitError("Quota exceeded", response=rl_resp, body=None)),
    )
    r_rl = client.post("/chat", json={"session_id": "err-rl", "message": "Oi"})
    assert r_rl.status_code == 429
    assert r_rl.json()["error_code"] == "llm_rate_limit"

    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        _raise_factory(APITimeoutError(request=dummy_req)),
    )
    r_to = client.post("/chat", json={"session_id": "err-to", "message": "Oi"})
    assert r_to.status_code == 504
    assert r_to.json()["error_code"] == "llm_timeout"

    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        _raise_factory(APIConnectionError(request=dummy_req)),
    )
    r_conn = client.post("/chat", json={"session_id": "err-conn", "message": "Oi"})
    assert r_conn.status_code == 503
    assert r_conn.json()["error_code"] == "llm_unreachable"

    not_found_resp = httpx.Response(404, request=dummy_req)
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        _raise_factory(NotFoundError("Model not found", response=not_found_resp, body=None)),
    )
    r_nf = client.post("/chat", json={"session_id": "err-nf", "message": "Oi"})
    assert r_nf.status_code == 502
    assert r_nf.json()["error_code"] == "llm_model_not_found"

    srv_resp = httpx.Response(500, request=dummy_req)
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        _raise_factory(InternalServerError("Upstream 500", response=srv_resp, body=None)),
    )
    r_srv = client.post("/chat", json={"session_id": "err-srv", "message": "Oi"})
    assert r_srv.status_code == 502
    assert "HTTP 500" in r_srv.json()["detail"]


def test_gemini_base_url_normalization_and_model_fallback(monkeypatch):
    from app.config import load_settings
    from app.services import llm_service

    llm_service._gemini_model_cache.clear()
    monkeypatch.delenv("LLM_BASE_URL", raising=False)
    monkeypatch.setenv("LLM_MODEL", "gpt-4o-mini")
    monkeypatch.setenv("LLM_API_KEY", "AIzaFakeKeyForAutoDetection123456")
    auto_cfg = load_settings()
    assert auto_cfg.provider == "gemini-openai-compat"
    assert auto_cfg.base_url == "https://generativelanguage.googleapis.com/v1beta/openai/"
    assert auto_cfg.model == "gemini-3-flash-preview"

    monkeypatch.setenv("LLM_API_KEY", "AQ.FakeAuthKeyForAutoDetection123456")
    aq_cfg = load_settings()
    assert aq_cfg.provider == "gemini-openai-compat"
    assert aq_cfg.base_url == "https://generativelanguage.googleapis.com/v1beta/openai/"
    assert aq_cfg.model == "gemini-3-flash-preview"

    monkeypatch.setenv(
        "LLM_BASE_URL",
        "https://generativelanguage.googleapis.com/v1beta/chat/completions",
    )
    cfg = load_settings()
    assert cfg.base_url == "https://generativelanguage.googleapis.com/v1beta/openai/"
    assert cfg.provider == "gemini-openai-compat"

    _reset_runtime_state(monkeypatch)
    dummy_req = httpx.Request("POST", "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
    nf_resp = httpx.Response(404, request=dummy_req)
    called_models: list[str] = []

    class FakeCompletions:
        async def create(self, **kwargs):
            called_models.append(kwargs["model"])
            if kwargs["model"] == "gemini-missing":
                raise NotFoundError("not found", response=nf_resp, body=None)
            return _fake_choice(content="Gemini respondeu no modelo disponivel!")

    class FakeModels:
        async def list(self):
            return SimpleNamespace(
                data=[
                    SimpleNamespace(id="models/text-embedding-004"),
                    SimpleNamespace(id="models/gemini-2.5-flash"),
                ]
            )

    fake_client = SimpleNamespace(
        chat=SimpleNamespace(completions=FakeCompletions()),
        models=FakeModels(),
    )
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (
            fake_client,
            {
                "configured": True,
                "model": "gemini-missing",
                "provider": "gemini-openai-compat",
            },
        ),
    )

    client = TestClient(backend_main.app)
    res = client.post("/chat", json={"session_id": "gem-fb", "message": "Oi!"})
    assert res.status_code == 200
    body = res.json()
    assert body["model"] == "gemini-2.5-flash"
    assert "Gemini respondeu" in body["reply"]
    assert called_models == ["gemini-missing", "gemini-2.5-flash"]


def test_chat_stream_sse_emits_events(monkeypatch):
    _reset_runtime_state(monkeypatch)
    backend_main.memory_store.clear_session("sse-test")

    class FakeCompletions:
        async def create(self, **kwargs):
            return _fake_choice(content="Resposta via stream SSE!")

    fake_client = SimpleNamespace(chat=SimpleNamespace(completions=FakeCompletions()))
    monkeypatch.setattr(
        backend_main,
        "create_llm_client",
        lambda: (fake_client, {"configured": True, "model": "gpt-4o-mini", "provider": "openai"}),
    )

    client = TestClient(backend_main.app)
    res = client.post(
        "/chat/stream",
        json={"session_id": "sse-test", "message": "Oi em stream!"},
    )
    assert res.status_code == 200
    assert "text/event-stream" in res.headers["content-type"]
    assert "event: status" in res.text
    assert "event: delta" in res.text
    assert "event: done" in res.text
    assert "Resposta via stream SSE!" in res.text


def test_optional_client_token_enforced(monkeypatch):
    _reset_runtime_state(monkeypatch)
    monkeypatch.setenv("MCQUEEN_CLIENT_TOKEN", "meu-segredo-app-999")

    client = TestClient(backend_main.app)
    # /health continua acessível para probe do Render
    assert client.get("/health").status_code == 200
    # /status e /chat exigem X-Client-Token quando configurado
    assert client.get("/status").status_code == 401
    res = client.post("/chat", json={"session_id": "tok1", "message": "Oi"})
    assert res.status_code == 401
    assert res.json()["error_code"] == "unauthorized_client"

    assert client.get("/status", headers={"X-Client-Token": "meu-segredo-app-999"}).status_code == 200


def test_scrub_secrets_redacts_api_keys():
    raw = "Fail with sk-proj-abcd12345678, AIzaSyDummyKey12345, AQ.DummyAuthKey123456 and Bearer abcdef123456"
    scrubbed = scrub_secrets(raw)
    assert "sk-proj-abcd" not in scrubbed
    assert "AIzaSyDummy" not in scrubbed
    assert "AQ.DummyAuth" not in scrubbed
    assert "abcdef123456" not in scrubbed
