# McQueen AI — Backend FastAPI Cloud

Gateway conversacional seguro, com **Tool Calling** e suporte ao deploy em nuvem (**Render**), permitindo que o aplicativo Flutter **McQueen** converse com uma IA real pela internet (Wi-Fi ou 4G/5G), mantendo o controle físico do robô restrito localmente ao app Flutter via Bluetooth Low Energy (BLE).

## Arquitetura

- **FastAPI + Uvicorn (`main.py`, `app/`)**:
  - `app/config.py`: leitura segura de variáveis de ambiente (`ENVIRONMENT`, `LLM_API_KEY` / `OPENAI_API_KEY`, `LLM_BASE_URL`, `LLM_MODEL`, `LLM_TIMEOUT_SECONDS`, `ALLOWED_ORIGINS`, `MCQUEEN_CLIENT_TOKEN`, rate limit e limites de sessão).
  - `app/models.py`: contratos Pydantic validados (`ChatRequest`, `ChatResponse`, `HealthResponse`, `StatusResponse`, `ErrorResponse`).
  - `app/security.py`: remoção automática de chaves/tokens nos logs (`scrub_secrets`), rate limiter por IP + sessão (`SlidingWindowRateLimiter`), verificação de token do cliente e isolamento de sessão (`X-Session-Token`).
  - `app/services/llm_service.py`: chamada real ao modelo LLM com timeout, tool calling (`tools_schema.py`), prioridade de parada (`stop_robot`), mapeamento limpo de erros (`401`, `429`, `502`, `503`, `504`) e streaming SSE.
  - `app/routes/health.py` e `app/routes/chat.py`: rotas HTTP moduladas.
- **Segurança Física**: o backend nunca envia comandos diretos ao ESP32-C3; ele devolve apenas intenções estruturadas validadas (`intents`) para o app Flutter validar novamente (`AiCommandExecutor`) antes de enviar ao BLE.

## Endpoints

| Método | Rota | Descrição |
|---|---|---|
| `GET` | `/` | Informações resumidas do serviço e endpoints disponíveis |
| `GET` | `/health` | Health check leve para Render e verificação de disponibilidade no app (sem expor segredos) |
| `GET` | `/status` | Telemetria operacional (uptime, sessões ativas, provedor, modelo, limites) |
| `POST` | `/chat` | Turno conversacional + Tool Calling seguro |
| `POST` | `/chat/stream` | Versão em streaming SSE (`status`, `intents`, `delta`, `done`, `error`) |
| `DELETE` | `/sessions/{session_id}` | Encerra a memória da sessão do usuário |

## Modelos Recomendados (Econômicos)

- **OpenAI (padrão):** `LLM_MODEL=gpt-4o-mini` com `OPENAI_API_KEY` (ou `LLM_API_KEY`).
- **Google Gemini (API OpenAI-compatível):**
  - `LLM_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai/`
  - `LLM_MODEL=gemini-2.5-flash`
  - `LLM_API_KEY=<sua-chave-google-ai-studio>`
- **Groq:**
  - `LLM_BASE_URL=https://api.groq.com/openai/v1`
  - `LLM_MODEL=llama-3.3-70b-versatile`

## Execução Local (Desenvolvimento)

```bash
cd backend/mcqueen_ai
python -m venv .venv
# Windows: .venv\Scripts\activate
# Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt
copy .env.example .env
# Preencha OPENAI_API_KEY ou LLM_API_KEY no arquivo .env
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

Rodar testes automatizados:

```bash
pytest -v test_mcqueen_ai_backend.py
```

## Deploy no Render (Nuvem HTTPS)

1. Crie um repositório no GitHub contendo este projeto (nunca envie `.env` ou `.venv/` — o `.gitignore` já bloqueia).
2. No painel do **Render** (`https://dashboard.render.com`):
   - Escolha **New + > Blueprint** (para detectar automaticamente o `render.yaml`) ou **Web Service**.
   - Se o repositório for a raiz do projeto `mcqueen`, mantenha **Root Directory**: `backend/mcqueen_ai` (já definido no `render.yaml` da raiz).
   - **Runtime**: `Python 3` (`PYTHON_VERSION=3.11.9`).
   - **Build Command**: `pip install --upgrade pip && pip install -r requirements.txt`
   - **Start Command**: `uvicorn main:app --host 0.0.0.0 --port $PORT --proxy-headers --forwarded-allow-ips="*"`
   - **Health Check Path**: `/health`
3. Configure as variáveis secretas diretamente no painel **Environment** do Render:
   - `ENVIRONMENT=production`
   - `LLM_API_KEY` (ou `OPENAI_API_KEY`): sua chave secreta (marcada como *Secret*, fora do código).
   - `LLM_MODEL`: `gpt-4o-mini` (ou `gemini-2.5-flash` se configurar `LLM_BASE_URL`).
   - `LLM_BASE_URL`: vazio para OpenAI, ou URL do provedor compatível.
   - `MCQUEEN_CLIENT_TOKEN` (opcional): token adicional caso queira restringir o endpoint apenas ao app autenticado.
4. Após o deploy, copie a URL HTTPS gerada pelo Render (`https://...onrender.com`), teste `GET <URL>/health` e configure essa URL no aplicativo Flutter (ou no `--dart-define=MCQUEEN_AI_URL=https://...` ao compilar o APK).

### Comportamento do Plano Gratuito (Cold Start / Hibernação)

No plano gratuito (`free`) do Render, o servidor entra em repouso (*sleep*) após cerca de **15 minutos sem requisições**. Ao receber a primeira mensagem ou `/health` depois do repouso, a inicialização leva normalmente de **15 a 50 segundos** (*cold start*). O aplicativo Flutter já reconhece esse estado como **"Servidor McQueen AI acordando na nuvem"** em vez de tratá-lo erroneamente como offline definitivo, aplicando timeout estendido e retentativas automáticas.
