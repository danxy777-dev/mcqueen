// lib/config/ai_config.dart
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Resultado da validação e normalização da URL do backend McQueen AI.
class AiUrlValidationResult {
  final bool isValid;
  final bool isEmpty;
  final bool isLocal;
  final String normalizedUrl;
  final String? errorMessage;

  const AiUrlValidationResult({
    required this.isValid,
    required this.normalizedUrl,
    this.isEmpty = false,
    this.isLocal = false,
    this.errorMessage,
  });
}

/// Configuração centralizada do backend em nuvem do McQueen AI.
///
/// Para embutir a URL HTTPS definitiva do Render no build de produção sem alterá-la em código:
/// `flutter build apk --release --dart-define=MCQUEEN_AI_URL=https://SEU-SERVICO.onrender.com`
///
/// Opcionalmente, caso habilite `MCQUEEN_CLIENT_TOKEN` no Render:
/// `--dart-define=MCQUEEN_CLIENT_TOKEN=seu-token`
class AiConfig {
  const AiConfig._();

  /// URL configurada em tempo de compilação via `--dart-define=MCQUEEN_AI_URL=...`.
  static const String compileTimeBackendUrl = String.fromEnvironment(
    'MCQUEEN_AI_URL',
    defaultValue: '',
  );

  /// Token opcional do aplicativo configurado em tempo de compilação via `--dart-define=MCQUEEN_CLIENT_TOKEN=...`.
  static const String compileTimeClientToken = String.fromEnvironment(
    'MCQUEEN_CLIENT_TOKEN',
    defaultValue: '',
  );

  /// URL padrão utilizada quando não há URL personalizada salva pelo usuário.
  /// Fica vazia enquanto não houver URL real de produção definida em `--dart-define=MCQUEEN_AI_URL=...`.
  static String get defaultBackendUrl => normalizeUrl(compileTimeBackendUrl);

  static bool get hasCompileTimeUrl => defaultBackendUrl.isNotEmpty;

  /// Timeouts pensados para nuvem HTTPS (incluindo cold start do Render Free).
  static const Duration internetProbeTimeout = Duration(seconds: 2);
  static const Duration healthTimeout = Duration(seconds: 8);
  static const Duration wakeHealthTimeout = Duration(seconds: 32);
  static const Duration chatTimeout = Duration(seconds: 35);
  static const Duration sessionClearTimeout = Duration(seconds: 4);

  /// Intervalos de verificação periódica não bloqueante com backoff exponencial.
  static const Duration baseRetryInterval = Duration(seconds: 15);
  static const Duration maxRetryInterval = Duration(seconds: 60);
  static const Duration idleHealthInterval = Duration(seconds: 45);

  static String normalizeUrl(String raw) {
    return raw.trim().replaceAll(RegExp(r'/+$'), '');
  }

  static bool isLegacyLocalDefault(String url) {
    final norm = normalizeUrl(url).toLowerCase();
    return norm == 'http://10.0.2.2:8000' || norm == 'http://127.0.0.1:8000';
  }

  static bool isLocalHost(String host) {
    final h = host.trim().toLowerCase();
    if (h == 'localhost' || h == '127.0.0.1' || h == '10.0.2.2' || h == '::1') {
      return true;
    }
    if (h.startsWith('192.168.') || h.startsWith('10.')) {
      return true;
    }
    final match = RegExp(r'^172\.(\d{1,3})\.').firstMatch(h);
    if (match != null) {
      final secondOctet = int.tryParse(match.group(1)!) ?? -1;
      if (secondOctet >= 16 && secondOctet <= 31) return true;
    }
    return false;
  }

  static AiUrlValidationResult validateBackendUrl(
    String raw, {
    bool allowLocalHttp = kDebugMode,
  }) {
    final normalized = normalizeUrl(raw);
    if (normalized.isEmpty) {
      return const AiUrlValidationResult(
        isValid: false,
        isEmpty: true,
        normalizedUrl: '',
        errorMessage:
            'URL do servidor na nuvem não configurada. Informe a URL HTTPS gerada no Render.',
      );
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.trim().isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return AiUrlValidationResult(
        isValid: false,
        normalizedUrl: normalized,
        errorMessage:
            'URL inválida. Use o formato completo com HTTPS (ex.: https://seu-backend.onrender.com).',
      );
    }

    final hostLower = uri.host.trim().toLowerCase();
    if (hostLower.contains('sua-url') ||
        hostLower.contains('seu-backend') ||
        hostLower.contains('seu-servico') ||
        hostLower == 'example.com') {
      return AiUrlValidationResult(
        isValid: false,
        normalizedUrl: normalized,
        errorMessage:
            'Substitua a URL de exemplo pela URL real do seu serviço publicado no Render.',
      );
    }

    final local = isLocalHost(uri.host);
    if (uri.scheme == 'http') {
      if (!local) {
        return AiUrlValidationResult(
          isValid: false,
          isLocal: false,
          normalizedUrl: normalized,
          errorMessage:
              'Conexão insegura (HTTP) bloqueada na internet. Use HTTPS (https://...).',
        );
      }
      if (!allowLocalHttp) {
        return AiUrlValidationResult(
          isValid: false,
          isLocal: true,
          normalizedUrl: normalized,
          errorMessage:
              'HTTP local permitido apenas quando o modo de desenvolvimento local estiver ativado.',
        );
      }
    }

    return AiUrlValidationResult(
      isValid: true,
      isLocal: local,
      normalizedUrl: normalized,
    );
  }

  /// Gera token opaco criptograficamente aleatório para isolar a sessão do usuário no backend.
  static String generateSessionToken() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    final rng = Random.secure();
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }
}
