// lib/ai/ai_backend_client.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/ai_config.dart';
import '../models/ai_models.dart';

/// Contrato HTTP base para comunicação com o backend FastAPI do McQueen AI.
abstract class AiBackendClient {
  Future<AiBackendHealth> checkHealth(String baseUrl);

  Future<AiChatResponse> sendMessage({
    required String baseUrl,
    required String sessionId,
    required String message,
    required Map<String, dynamic> robotState,
  });

  Future<void> clearSession({
    required String baseUrl,
    required String sessionId,
  });
}

/// Contrato estendido para cliente em nuvem com isolamento de sessão e HTTPS/cold-start.
abstract class CloudAiBackendClient implements AiBackendClient {
  Future<AiBackendHealth> checkHealthWithOptions(
    String baseUrl, {
    String? sessionToken,
    String? clientToken,
    bool allowLocalHttp = false,
    bool wakeMode = false,
  });

  Future<AiChatResponse> sendMessageWithOptions({
    required String baseUrl,
    required String sessionId,
    required String message,
    required Map<String, dynamic> robotState,
    String? sessionToken,
    String? clientToken,
    bool allowLocalHttp = false,
  });

  Future<void> clearSessionWithOptions({
    required String baseUrl,
    required String sessionId,
    String? sessionToken,
    String? clientToken,
    bool allowLocalHttp = false,
  });

  void disposeClient();
}

class AiBackendException implements Exception {
  final String message;
  final String? errorCode;
  final AiBackendStatus status;
  final int? httpStatus;
  final int? retryAfterSeconds;

  const AiBackendException(
    this.message, {
    this.errorCode,
    this.status = AiBackendStatus.communicationError,
    this.httpStatus,
    this.retryAfterSeconds,
  });

  @override
  String toString() => message;
}

Future<bool> _defaultInternetProbe() async {
  try {
    final result = await InternetAddress.lookup('dns.google')
        .timeout(AiConfig.internetProbeTimeout);
    return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
  } catch (_) {
    return false;
  }
}

class HttpAiBackendClient implements CloudAiBackendClient {
  final http.Client _http;
  final bool _ownsClient;
  final Future<bool> Function() _internetProbe;

  HttpAiBackendClient({
    http.Client? client,
    Future<bool> Function()? internetProbe,
  })  : _http = client ?? http.Client(),
        _ownsClient = client == null,
        _internetProbe = internetProbe ?? _defaultInternetProbe;

  Uri _buildUri(String normalizedBaseUrl, String path) {
    return Uri.parse('$normalizedBaseUrl$path');
  }

  Map<String, String> _buildHeaders({
    String? sessionToken,
    String? clientToken,
    bool includeJsonContentType = false,
  }) {
    final headers = <String, String>{
      'Accept': 'application/json',
    };
    if (includeJsonContentType) {
      headers['Content-Type'] = 'application/json';
    }
    if (sessionToken != null && sessionToken.trim().isNotEmpty) {
      headers['X-Session-Token'] = sessionToken.trim();
    }
    final effectiveClientToken = (clientToken ?? '').trim().isNotEmpty
        ? clientToken!.trim()
        : AiConfig.compileTimeClientToken;
    if (effectiveClientToken.isNotEmpty) {
      headers['X-Client-Token'] = effectiveClientToken;
    }
    return headers;
  }

  Map<String, dynamic>? _tryDecodeJsonMap(http.Response res) {
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {}
    return null;
  }

  int? _parseRetryAfter(http.Response res) {
    final raw = res.headers['retry-after'] ?? res.headers['Retry-After'];
    if (raw == null) return null;
    return int.tryParse(raw.trim());
  }

  Future<bool> _hasInternet() async {
    try {
      return await _internetProbe();
    } catch (_) {
      return false;
    }
  }

  AiUrlValidationResult _validateUrl(
    String baseUrl, {
    required bool allowLocalHttp,
  }) {
    return AiConfig.validateBackendUrl(
      baseUrl,
      allowLocalHttp: allowLocalHttp || kDebugMode,
    );
  }

  @override
  Future<AiBackendHealth> checkHealth(String baseUrl) {
    return checkHealthWithOptions(baseUrl);
  }

  @override
  Future<AiBackendHealth> checkHealthWithOptions(
    String baseUrl, {
    String? sessionToken,
    String? clientToken,
    bool allowLocalHttp = false,
    bool wakeMode = false,
  }) async {
    final validation = _validateUrl(baseUrl, allowLocalHttp: allowLocalHttp);
    if (!validation.isValid) {
      return AiBackendHealth(
        reachable: false,
        configured: false,
        status: validation.isEmpty
            ? AiBackendStatus.notConfigured
            : AiBackendStatus.communicationError,
        error: validation.errorMessage,
      );
    }

    final normalized = validation.normalizedUrl;
    final timeout = wakeMode ? AiConfig.wakeHealthTimeout : AiConfig.healthTimeout;
    final headers = _buildHeaders(
      sessionToken: sessionToken,
      clientToken: clientToken,
    );

    try {
      final res = await _http
          .get(
            _buildUri(normalized, '/health'),
            headers: headers,
          )
          .timeout(timeout);

      final body = _tryDecodeJsonMap(res);
      if (res.statusCode == 200 && body != null) {
        final configured = body['configured'] as bool? ?? false;
        final provider = body['provider'] as String?;
        final model = body['model'] as String?;

        if (configured) {
          // Valida também `/status` para detectar se `MCQUEEN_CLIENT_TOKEN` está exigido no Render.
          try {
            final statusRes = await _http
                .get(_buildUri(normalized, '/status'), headers: headers)
                .timeout(AiConfig.healthTimeout);
            if (statusRes.statusCode == 401 || statusRes.statusCode == 403) {
              return AiBackendHealth(
                reachable: true,
                configured: false,
                provider: provider,
                model: model,
                status: AiBackendStatus.invalidApiKey,
                httpStatus: statusRes.statusCode,
                error:
                    'Servidor exige Token de Acesso (MCQUEEN_CLIENT_TOKEN). Informe o token em Configurar ou remova a variável no Render.',
              );
            }
          } catch (_) {
            // Não invalida `/health` por oscilação pontual na sonda auxiliar `/status`.
          }
        }

        return AiBackendHealth(
          reachable: true,
          configured: configured,
          provider: provider,
          model: model,
          status: configured
              ? AiBackendStatus.online
              : AiBackendStatus.llmUnavailable,
          httpStatus: 200,
          error: configured
              ? null
              : 'Servidor ativo na nuvem, mas a chave da API de IA não está configurada nas variáveis de ambiente.',
        );
      }

      if (res.statusCode == 401 || res.statusCode == 403) {
        return AiBackendHealth(
          reachable: true,
          configured: false,
          status: AiBackendStatus.invalidApiKey,
          httpStatus: res.statusCode,
          error: 'Falha de autenticação no servidor (HTTP ${res.statusCode}).',
        );
      }

      if (res.statusCode == 429) {
        final retryAfter = _parseRetryAfter(res);
        return AiBackendHealth(
          reachable: true,
          configured: true,
          status: AiBackendStatus.rateLimited,
          httpStatus: 429,
          retryAfterSeconds: retryAfter,
          error: 'Limite de requisições atingido temporariamente (HTTP 429).',
        );
      }

      if ((res.statusCode == 502 || res.statusCode == 503 || res.statusCode == 504) &&
          body == null) {
        // Resposta HTML de gateway 502/503 do Render indica instância acordando após inatividade.
        return AiBackendHealth(
          reachable: false,
          configured: false,
          status: AiBackendStatus.wakingUp,
          httpStatus: res.statusCode,
          error: 'Servidor McQueen AI acordando na nuvem após repouso (HTTP ${res.statusCode}).',
        );
      }

      if (res.statusCode == 404) {
        return AiBackendHealth(
          reachable: false,
          configured: false,
          status: AiBackendStatus.backendUnavailable,
          httpStatus: 404,
          error: 'Endpoint /health não encontrado (HTTP 404). Verifique a URL configurada.',
        );
      }

      final detail = (body?['detail'] as String?)?.trim();
      return AiBackendHealth(
        reachable: res.statusCode < 500,
        configured: false,
        status: res.statusCode >= 500
            ? AiBackendStatus.backendUnavailable
            : AiBackendStatus.communicationError,
        httpStatus: res.statusCode,
        error: detail?.isNotEmpty == true
            ? detail
            : 'Resposta inesperada do servidor (HTTP ${res.statusCode}).',
      );
    } on TimeoutException {
      if (!validation.isLocal) {
        return const AiBackendHealth(
          reachable: false,
          configured: false,
          status: AiBackendStatus.wakingUp,
          error:
              'Servidor na nuvem demorou para responder (pode estar iniciando após inatividade no plano gratuito).',
        );
      }
      return const AiBackendHealth(
        reachable: false,
        configured: false,
        status: AiBackendStatus.backendUnavailable,
        error: 'Tempo esgotado ao tentar conectar ao servidor local.',
      );
    } on HandshakeException {
      return const AiBackendHealth(
        reachable: false,
        configured: false,
        status: AiBackendStatus.communicationError,
        error: 'Falha na validação do certificado HTTPS (TLS). Verifique a URL.',
      );
    } on SocketException {
      final online = await _hasInternet();
      if (!online) {
        return const AiBackendHealth(
          reachable: false,
          configured: false,
          status: AiBackendStatus.noInternet,
          error: 'Celular sem acesso à internet. Verifique Wi-Fi ou dados móveis.',
        );
      }
      return AiBackendHealth(
        reachable: false,
        configured: false,
        status: AiBackendStatus.backendUnavailable,
        error: 'Internet ativa, mas o backend em $normalized não respondeu.',
      );
    } on http.ClientException {
      final online = await _hasInternet();
      return AiBackendHealth(
        reachable: false,
        configured: false,
        status: online
            ? AiBackendStatus.backendUnavailable
            : AiBackendStatus.noInternet,
        error: online
            ? 'Não foi possível alcançar o backend em $normalized.'
            : 'Sem conexão com a internet no dispositivo.',
      );
    } catch (_) {
      return const AiBackendHealth(
        reachable: false,
        configured: false,
        status: AiBackendStatus.communicationError,
        error: 'Erro inesperado ao verificar disponibilidade do servidor.',
      );
    }
  }

  @override
  Future<AiChatResponse> sendMessage({
    required String baseUrl,
    required String sessionId,
    required String message,
    required Map<String, dynamic> robotState,
  }) {
    return sendMessageWithOptions(
      baseUrl: baseUrl,
      sessionId: sessionId,
      message: message,
      robotState: robotState,
    );
  }

  @override
  Future<AiChatResponse> sendMessageWithOptions({
    required String baseUrl,
    required String sessionId,
    required String message,
    required Map<String, dynamic> robotState,
    String? sessionToken,
    String? clientToken,
    bool allowLocalHttp = false,
  }) async {
    final validation = _validateUrl(baseUrl, allowLocalHttp: allowLocalHttp);
    if (!validation.isValid) {
      throw AiBackendException(
        validation.errorMessage ?? 'URL do servidor inválida.',
        errorCode: validation.isEmpty ? 'url_not_configured' : 'invalid_url',
        status: validation.isEmpty
            ? AiBackendStatus.notConfigured
            : AiBackendStatus.communicationError,
      );
    }

    final normalized = validation.normalizedUrl;
    late http.Response res;
    try {
      res = await _http
          .post(
            _buildUri(normalized, '/chat'),
            headers: _buildHeaders(
              sessionToken: sessionToken,
              clientToken: clientToken,
              includeJsonContentType: true,
            ),
            body: jsonEncode({
              'session_id': sessionId,
              'message': message,
              'robot_state': robotState,
            }),
          )
          .timeout(AiConfig.chatTimeout);
    } on TimeoutException {
      if (!validation.isLocal) {
        throw const AiBackendException(
          'O servidor na nuvem demorou para responder (pode estar acordando após inatividade). Tente novamente em alguns segundos.',
          errorCode: 'timeout',
          status: AiBackendStatus.wakingUp,
        );
      }
      throw const AiBackendException(
        'Tempo esgotado ao aguardar resposta do servidor McQueen AI.',
        errorCode: 'timeout',
        status: AiBackendStatus.communicationError,
      );
    } on HandshakeException {
      throw const AiBackendException(
        'Falha na verificação de segurança HTTPS (TLS) com o servidor.',
        errorCode: 'tls_error',
        status: AiBackendStatus.communicationError,
      );
    } on SocketException {
      final online = await _hasInternet();
      if (!online) {
        throw const AiBackendException(
          'Sem conexão com a internet no celular. Verifique Wi-Fi ou dados móveis.',
          errorCode: 'no_internet',
          status: AiBackendStatus.noInternet,
        );
      }
      throw AiBackendException(
        'Celular conectado à internet, mas o backend em $normalized está indisponível no momento.',
        errorCode: 'connection_error',
        status: AiBackendStatus.backendUnavailable,
      );
    } on http.ClientException {
      final online = await _hasInternet();
      throw AiBackendException(
        online
            ? 'Falha ao conectar com o backend McQueen AI em $normalized.'
            : 'Sem conexão com a internet no celular.',
        errorCode: online ? 'connection_error' : 'no_internet',
        status: online
            ? AiBackendStatus.backendUnavailable
            : AiBackendStatus.noInternet,
      );
    }

    final body = _tryDecodeJsonMap(res);
    if (res.statusCode != 200) {
      throw _mapHttpError(res, body);
    }

    if (body == null || !body.containsKey('reply')) {
      throw const AiBackendException(
        'Resposta inválida recebida do servidor McQueen AI.',
        errorCode: 'invalid_json',
        status: AiBackendStatus.communicationError,
        httpStatus: 200,
      );
    }

    return AiChatResponse.fromJson(body);
  }

  AiBackendException _mapHttpError(
    http.Response res,
    Map<String, dynamic>? body,
  ) {
    final code = (body?['error_code'] as String?)?.trim();
    final detail = (body?['detail'] as String?)?.trim();
    final retryAfter = _parseRetryAfter(res);

    if (res.statusCode == 401 || res.statusCode == 403 || code == 'invalid_api_key') {
      return AiBackendException(
        detail ?? 'Falha de autenticação ou chave de API inválida no servidor (HTTP ${res.statusCode}).',
        errorCode: code ?? 'unauthorized',
        status: AiBackendStatus.invalidApiKey,
        httpStatus: res.statusCode,
      );
    }

    if (res.statusCode == 429 || code == 'rate_limit_exceeded' || code == 'llm_rate_limit') {
      return AiBackendException(
        detail ?? 'Limite temporário de requisições atingido. Aguarde alguns segundos.',
        errorCode: code ?? 'rate_limit',
        status: AiBackendStatus.rateLimited,
        httpStatus: 429,
        retryAfterSeconds: retryAfter,
      );
    }

    if (res.statusCode == 404) {
      return AiBackendException(
        detail ?? 'Rota /chat não encontrada (HTTP 404). Verifique a URL do backend.',
        errorCode: code ?? 'not_found',
        status: AiBackendStatus.backendUnavailable,
        httpStatus: 404,
      );
    }

    if (code == 'missing_api_key') {
      return AiBackendException(
        detail ?? 'Chave da API de IA não configurada nas variáveis de ambiente do servidor.',
        errorCode: code,
        status: AiBackendStatus.invalidApiKey,
        httpStatus: res.statusCode,
      );
    }

    if (code == 'llm_unreachable' || code == 'llm_api_error' || code == 'llm_bad_request') {
      return AiBackendException(
        detail ?? 'Provedor de inteligência artificial indisponível no momento.',
        errorCode: code,
        status: AiBackendStatus.llmUnavailable,
        httpStatus: res.statusCode,
      );
    }

    if (code == 'llm_timeout') {
      return AiBackendException(
        detail ?? 'O provedor de IA demorou demais para responder.',
        errorCode: code,
        status: AiBackendStatus.communicationError,
        httpStatus: res.statusCode,
      );
    }

    if ((res.statusCode == 502 || res.statusCode == 503 || res.statusCode == 504) &&
        body == null) {
      return AiBackendException(
        'Servidor McQueen AI inicializando na nuvem (HTTP ${res.statusCode}). Aguarde alguns segundos e tente novamente.',
        errorCode: 'backend_waking_up',
        status: AiBackendStatus.wakingUp,
        httpStatus: res.statusCode,
      );
    }

    if (res.statusCode >= 500) {
      return AiBackendException(
        detail ?? 'Erro interno temporário no backend (HTTP ${res.statusCode}).',
        errorCode: code ?? 'server_error',
        status: AiBackendStatus.backendUnavailable,
        httpStatus: res.statusCode,
      );
    }

    return AiBackendException(
      detail ?? 'Erro na comunicação com o servidor (HTTP ${res.statusCode}).',
      errorCode: code ?? 'http_error',
      status: AiBackendStatus.communicationError,
      httpStatus: res.statusCode,
    );
  }

  @override
  Future<void> clearSession({
    required String baseUrl,
    required String sessionId,
  }) {
    return clearSessionWithOptions(
      baseUrl: baseUrl,
      sessionId: sessionId,
    );
  }

  @override
  Future<void> clearSessionWithOptions({
    required String baseUrl,
    required String sessionId,
    String? sessionToken,
    String? clientToken,
    bool allowLocalHttp = false,
  }) async {
    final validation = _validateUrl(baseUrl, allowLocalHttp: allowLocalHttp);
    if (!validation.isValid) return;

    try {
      await _http
          .delete(
            _buildUri(validation.normalizedUrl, '/sessions/$sessionId'),
            headers: _buildHeaders(
              sessionToken: sessionToken,
              clientToken: clientToken,
            ),
          )
          .timeout(AiConfig.sessionClearTimeout);
    } catch (_) {}
  }

  @override
  void disposeClient() {
    if (_ownsClient) {
      _http.close();
    }
  }
}
