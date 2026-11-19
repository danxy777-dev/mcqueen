// lib/models/ai_models.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../config/ai_config.dart';
import '../theme/app_theme.dart';

/// Estados visuais explícitos do assistente McQueen AI.
enum AiAssistantState {
  idle(label: 'Aguardando', color: McQueenColors.cyan, icon: Icons.auto_awesome_rounded),
  listening(label: 'Escutando', color: McQueenColors.emerald, icon: Icons.mic_rounded),
  processing(label: 'Processando', color: McQueenColors.amber, icon: Icons.psychology_rounded),
  executingCommand(label: 'Executando comando', color: McQueenColors.orange, icon: Icons.bolt_rounded),
  speaking(label: 'Respondendo', color: McQueenColors.violetText, icon: Icons.volume_up_rounded),
  error(label: 'Erro de reconhecimento', color: McQueenColors.crimsonText, icon: Icons.error_outline_rounded);

  final String label;
  final Color color;
  final IconData icon;

  const AiAssistantState({
    required this.label,
    required this.color,
    required this.icon,
  });
}

/// Estados detalhados e honestos da disponibilidade do backend na nuvem.
enum AiBackendStatus {
  checking(
    label: 'Verificando servidor...',
    color: McQueenColors.cyan,
    icon: Icons.sync_rounded,
  ),
  notConfigured(
    label: 'URL da nuvem não configurada',
    color: McQueenColors.amber,
    icon: Icons.link_off_rounded,
  ),
  noInternet(
    label: 'Sem conexão com a internet',
    color: McQueenColors.crimsonText,
    icon: Icons.wifi_off_rounded,
  ),
  wakingUp(
    label: 'Servidor acordando na nuvem...',
    color: McQueenColors.amber,
    icon: Icons.hourglass_top_rounded,
  ),
  backendUnavailable(
    label: 'Backend indisponível no momento',
    color: McQueenColors.crimsonText,
    icon: Icons.cloud_off_rounded,
  ),
  online(
    label: 'McQueen AI online',
    color: McQueenColors.emerald,
    icon: Icons.cloud_done_rounded,
  ),
  llmUnavailable(
    label: 'IA indisponível no provedor',
    color: McQueenColors.amber,
    icon: Icons.psychology_alt_rounded,
  ),
  invalidApiKey(
    label: 'Chave de API inválida ou ausente',
    color: McQueenColors.crimsonText,
    icon: Icons.key_off_rounded,
  ),
  rateLimited(
    label: 'Limite de uso atingido (429)',
    color: McQueenColors.amber,
    icon: Icons.speed_rounded,
  ),
  communicationError(
    label: 'Erro de comunicação',
    color: McQueenColors.crimsonText,
    icon: Icons.warning_amber_rounded,
  );

  final String label;
  final Color color;
  final IconData icon;

  const AiBackendStatus({
    required this.label,
    required this.color,
    required this.icon,
  });
}

/// Intenção estruturada devolvida pelo backend LLM (nunca enviada crua ao ESP32).
class RobotIntent {
  final String tool;
  final Map<String, dynamic> arguments;

  const RobotIntent({
    required this.tool,
    required this.arguments,
  });

  factory RobotIntent.fromJson(Map<String, dynamic> json) {
    final rawArgs = json['arguments'];
    return RobotIntent(
      tool: (json['tool'] as String? ?? '').trim(),
      arguments: rawArgs is Map<String, dynamic>
          ? Map<String, dynamic>.from(rawArgs)
          : <String, dynamic>{},
    );
  }
}

/// Saúde e status de configuração do backend McQueen AI.
class AiBackendHealth {
  final bool reachable;
  final bool configured;
  final String? provider;
  final String? model;
  final String? error;
  final AiBackendStatus? status;
  final int? httpStatus;
  final int? retryAfterSeconds;

  const AiBackendHealth({
    required this.reachable,
    required this.configured,
    this.provider,
    this.model,
    this.error,
    this.status,
    this.httpStatus,
    this.retryAfterSeconds,
  });

  AiBackendStatus get effectiveStatus {
    if (status != null) return status!;
    if (reachable && configured) return AiBackendStatus.online;
    if (reachable && !configured) return AiBackendStatus.llmUnavailable;
    return AiBackendStatus.backendUnavailable;
  }

  bool get ready =>
      reachable &&
      configured &&
      effectiveStatus == AiBackendStatus.online;
}

/// Resposta validada de `/chat` no backend FastAPI.
class AiChatResponse {
  final String reply;
  final List<RobotIntent> intents;
  final List<String> blockedReasons;
  final String? model;
  final String? provider;

  const AiChatResponse({
    required this.reply,
    this.intents = const [],
    this.blockedReasons = const [],
    this.model,
    this.provider,
  });

  factory AiChatResponse.fromJson(Map<String, dynamic> json) {
    final rawIntents = json['intents'];
    final intents = <RobotIntent>[];
    if (rawIntents is List) {
      for (final item in rawIntents) {
        if (item is Map<String, dynamic>) {
          intents.add(RobotIntent.fromJson(item));
        }
      }
    }

    final rawBlocked = json['blocked_intents'];
    final blocked = <String>[];
    if (rawBlocked is List) {
      for (final item in rawBlocked) {
        if (item is Map<String, dynamic>) {
          final reason = (item['reason'] as String? ?? '').trim();
          if (reason.isNotEmpty) blocked.add(reason);
        }
      }
    }

    return AiChatResponse(
      reply: (json['reply'] as String? ?? '').trim(),
      intents: intents,
      blockedReasons: blocked,
      model: json['model'] as String?,
      provider: json['provider'] as String?,
    );
  }
}

/// Mensagem exibida no histórico de conversa do McQueen AI.
class AiChatMessage {
  final String id;
  final bool isUser;
  final String text;
  final DateTime timestamp;
  final bool isVoiceInput;
  final bool isError;
  final List<String> actionBadges;

  const AiChatMessage({
    required this.id,
    required this.isUser,
    required this.text,
    required this.timestamp,
    this.isVoiceInput = false,
    this.isError = false,
    this.actionBadges = const [],
  });
}

/// Configurações locais de voz e URL do backend (nunca armazena chaves secretas de LLM).
class AiVoiceSettings {
  final bool autoSpeak;
  final double speechRate;
  final double volume;
  final bool roboticVoice;
  final String backendUrl;
  final bool allowLocalDevHttp;

  const AiVoiceSettings({
    this.autoSpeak = true,
    this.speechRate = 0.52,
    this.volume = 1.0,
    this.roboticVoice = false,
    this.backendUrl = AiConfig.compileTimeBackendUrl,
    this.allowLocalDevHttp = false,
  });

  double get effectivePitch => roboticVoice ? 0.78 : 1.02;
  double get effectiveRate =>
      roboticVoice ? (speechRate + 0.04).clamp(0.3, 0.85) : speechRate;

  AiVoiceSettings copyWith({
    bool? autoSpeak,
    double? speechRate,
    double? volume,
    bool? roboticVoice,
    String? backendUrl,
    bool? allowLocalDevHttp,
  }) {
    return AiVoiceSettings(
      autoSpeak: autoSpeak ?? this.autoSpeak,
      speechRate: (speechRate ?? this.speechRate).clamp(0.3, 0.85),
      volume: (volume ?? this.volume).clamp(0.0, 1.0),
      roboticVoice: roboticVoice ?? this.roboticVoice,
      backendUrl: AiConfig.normalizeUrl(backendUrl ?? this.backendUrl),
      allowLocalDevHttp: allowLocalDevHttp ?? this.allowLocalDevHttp,
    );
  }

  Map<String, dynamic> toJson() => {
        'autoSpeak': autoSpeak,
        'speechRate': speechRate,
        'volume': volume,
        'roboticVoice': roboticVoice,
        'backendUrl': backendUrl,
        'allowLocalDevHttp': allowLocalDevHttp,
      };

  factory AiVoiceSettings.fromJson(Map<String, dynamic> map) {
    final storedUrl = AiConfig.normalizeUrl(map['backendUrl'] as String? ?? '');
    final allowLocal = map['allowLocalDevHttp'] as bool? ?? false;

    // Migra URL legada de emulador (`10.0.2.2`) para a URL em nuvem quando houver uma configurada.
    String effectiveUrl = storedUrl;
    if (effectiveUrl.isEmpty ||
        (!allowLocal && AiConfig.isLegacyLocalDefault(effectiveUrl))) {
      effectiveUrl = AiConfig.defaultBackendUrl;
    }

    return AiVoiceSettings(
      autoSpeak: map['autoSpeak'] as bool? ?? true,
      speechRate:
          ((map['speechRate'] as num?)?.toDouble() ?? 0.52).clamp(0.3, 0.85),
      volume: ((map['volume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
      roboticVoice: map['roboticVoice'] as bool? ?? false,
      backendUrl: effectiveUrl,
      allowLocalDevHttp: allowLocal,
    );
  }
}

class AiVoiceSettingsStore {
  static File get _file =>
      File('${Directory.systemTemp.path}/mcqueen_ai_voice_settings.json');

  static Future<AiVoiceSettings> load() async {
    try {
      final f = _file;
      if (f.existsSync()) {
        final decoded = jsonDecode(f.readAsStringSync());
        if (decoded is Map<String, dynamic>) {
          return AiVoiceSettings.fromJson(decoded);
        }
      }
    } catch (_) {}
    return const AiVoiceSettings();
  }

  static Future<void> save(AiVoiceSettings settings) async {
    try {
      await _file.writeAsString(jsonEncode(settings.toJson()), flush: true);
    } catch (_) {}
  }
}
