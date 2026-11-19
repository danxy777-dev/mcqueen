// lib/ai/mcqueen_ai_controller.dart
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../config/ai_config.dart';
import '../core/robot_service.dart';
import '../models/ai_models.dart';
import 'ai_backend_client.dart';
import 'ai_command_executor.dart';
import 'voice_service.dart';

export 'ai_backend_client.dart';

/// Controlador central da experiência conversacional e por voz **McQueen AI**.
class McQueenAiController extends ChangeNotifier {
  final RobotService robot;
  final AiBackendClient _backend;
  final VoiceService _voice;
  final bool enableBackgroundHealthCheck;
  late final AiCommandExecutor _executor;

  final List<AiChatMessage> _messages = [];
  AiAssistantState _state = AiAssistantState.idle;
  AiVoiceSettings _voiceSettings = const AiVoiceSettings();
  AiBackendHealth? _health;
  String _partialTranscript = '';
  String? _errorMessage;
  String _sessionId = 'mcqueen_${DateTime.now().millisecondsSinceEpoch}';
  String _sessionToken = AiConfig.generateSessionToken();
  int _msgSeq = 0;
  int _requestGeneration = 0;
  int _healthFailureStreak = 0;
  bool _checkingHealth = false;
  bool _screenActive = true;
  bool _disposed = false;
  bool _submittedCurrentVoiceTurn = false;
  Timer? _healthTimer;

  McQueenAiController({
    required this.robot,
    AiBackendClient? backendClient,
    VoiceService? voiceService,
    this.enableBackgroundHealthCheck = true,
  })  : _backend = backendClient ?? HttpAiBackendClient(),
        _voice = voiceService ?? DeviceVoiceService() {
    _executor = AiCommandExecutor(
      robot,
      onMotionStateChanged: _safeNotify,
    );
    unawaited(_loadVoiceSettings());
  }

  List<AiChatMessage> get messages => List.unmodifiable(_messages);
  AiAssistantState get state => _state;
  AiVoiceSettings get voiceSettings => _voiceSettings;
  AiBackendHealth? get backendHealth => _health;
  bool get isCheckingHealth => _checkingHealth;
  String get partialTranscript => _partialTranscript;
  String? get errorMessage => _errorMessage;
  bool get isTimedMotionActive => _executor.isTimedMotionActive;
  bool get isListening => _state == AiAssistantState.listening;
  bool get isSpeaking => _state == AiAssistantState.speaking;
  bool get isBusy =>
      _state == AiAssistantState.processing ||
      _state == AiAssistantState.executingCommand;

  Future<void> _loadVoiceSettings() async {
    _voiceSettings = await AiVoiceSettingsStore.load();
    _safeNotify();
    await refreshBackendHealth();
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  String _nextId() => 'm_${++_msgSeq}';

  void setScreenActive(bool active) {
    if (_disposed || _screenActive == active) return;
    _screenActive = active;
    if (!active) {
      _healthTimer?.cancel();
      _healthTimer = null;
    } else {
      unawaited(refreshBackendHealth());
    }
  }

  Future<void> refreshBackendHealth({bool wakeMode = false}) async {
    if (_disposed || _checkingHealth) return;
    _checkingHealth = true;
    _healthTimer?.cancel();
    _safeNotify();

    try {
      final result = await _performHealthCheck(wakeMode: wakeMode);
      if (_disposed) return;
      _health = result;
      if (result.ready) {
        _healthFailureStreak = 0;
      } else if (result.effectiveStatus != AiBackendStatus.notConfigured) {
        _healthFailureStreak = (_healthFailureStreak + 1).clamp(1, 5);
      }
      _scheduleNextHealthCheck();
    } finally {
      _checkingHealth = false;
      _safeNotify();
    }
  }

  Future<AiBackendHealth> _performHealthCheck({bool wakeMode = false}) {
    final client = _backend;
    if (client is CloudAiBackendClient) {
      return client.checkHealthWithOptions(
        _voiceSettings.backendUrl,
        sessionToken: _sessionToken,
        allowLocalHttp: _voiceSettings.allowLocalDevHttp,
        wakeMode: wakeMode,
      );
    }
    return client.checkHealth(_voiceSettings.backendUrl);
  }

  Future<void> retryConnection() async {
    _healthFailureStreak = 0;
    await refreshBackendHealth(wakeMode: true);
  }

  void _scheduleNextHealthCheck() {
    if (_disposed || !enableBackgroundHealthCheck || !_screenActive) return;
    _healthTimer?.cancel();

    final status = _health?.effectiveStatus;
    if (status == AiBackendStatus.notConfigured) {
      return;
    }

    Duration delay;
    if (_health?.ready ?? false) {
      delay = AiConfig.idleHealthInterval;
    } else if (status == AiBackendStatus.wakingUp) {
      delay = const Duration(seconds: 12);
    } else if (status == AiBackendStatus.rateLimited &&
        (_health?.retryAfterSeconds ?? 0) > 0) {
      delay = Duration(
        seconds: max(_health!.retryAfterSeconds!, 15).clamp(10, 120),
      );
    } else {
      final multiplier = 1 << (_healthFailureStreak > 0 ? _healthFailureStreak - 1 : 0);
      final secs = min(
        AiConfig.baseRetryInterval.inSeconds * multiplier,
        AiConfig.maxRetryInterval.inSeconds,
      );
      delay = Duration(seconds: secs);
    }

    _healthTimer = Timer(delay, () {
      if (_disposed || !_screenActive || isBusy) return;
      unawaited(refreshBackendHealth());
    });
  }

  Future<void> updateVoiceSettings(AiVoiceSettings next) async {
    final urlChanged =
        next.backendUrl != _voiceSettings.backendUrl ||
        next.allowLocalDevHttp != _voiceSettings.allowLocalDevHttp;
    _voiceSettings = next;
    _safeNotify();
    await AiVoiceSettingsStore.save(next);
    if (!next.autoSpeak && _state == AiAssistantState.speaking) {
      await interruptSpeech();
    }
    if (urlChanged) {
      _healthFailureStreak = 0;
      await refreshBackendHealth(wakeMode: true);
    }
  }

  Map<String, dynamic> _buildRobotStatePayload() {
    return {
      'ble_connected': robot.isConnected,
      'speed_mode': robot.currentSpeed.label,
      'speed_percent': robot.speedPercent,
      'turn_signal': robot.turnSignal.code,
      'expression': robot.currentExpression.code,
      'sounds_enabled': robot.settings.soundsEnabled,
      'is_moving': robot.motorState.isMoving || _executor.isTimedMotionActive,
    };
  }

  /// Inicia ou interrompe captura de voz em `pt-BR`.
  /// Se o McQueen estiver falando, interrompe a fala antes de abrir o microfone.
  Future<void> toggleVoiceCapture() async {
    if (_state == AiAssistantState.listening) {
      await stopVoiceCapture();
      return;
    }

    if (_state == AiAssistantState.speaking) {
      await _voice.stopSpeaking();
    }

    _errorMessage = null;
    _partialTranscript = '';
    _submittedCurrentVoiceTurn = false;
    _state = AiAssistantState.listening;
    _safeNotify();

    final started = await _voice.startListening(
      onResult: (words, isFinal) {
        if (_disposed || _submittedCurrentVoiceTurn) return;
        _partialTranscript = words;
        _safeNotify();
        if (isFinal && words.trim().isNotEmpty) {
          _submittedCurrentVoiceTurn = true;
          unawaited(_finalizeVoiceTranscript(words.trim()));
        }
      },
      onStatus: (status) {
        if (_disposed) return;
        final lower = status.toLowerCase();
        if ((lower == 'notlistening' || lower == 'done') &&
            _state == AiAssistantState.listening &&
            !_submittedCurrentVoiceTurn) {
          final buffered = _partialTranscript.trim();
          if (buffered.isNotEmpty) {
            _submittedCurrentVoiceTurn = true;
            unawaited(_finalizeVoiceTranscript(buffered));
          } else {
            _state = AiAssistantState.idle;
            _safeNotify();
          }
        }
      },
      onError: (err) {
        if (_disposed) return;
        _errorMessage = err;
        _partialTranscript = '';
        _state = AiAssistantState.error;
        _safeNotify();
      },
    );

    if (!started && _state == AiAssistantState.listening) {
      _state = AiAssistantState.error;
      _errorMessage ??= 'Não foi possível iniciar o reconhecimento de voz.';
      _safeNotify();
    }
  }

  Future<void> stopVoiceCapture() async {
    await _voice.stopListening();
    final buffered = _partialTranscript.trim();
    if (!_submittedCurrentVoiceTurn && buffered.isNotEmpty) {
      _submittedCurrentVoiceTurn = true;
      await _finalizeVoiceTranscript(buffered);
    } else if (_state == AiAssistantState.listening) {
      _partialTranscript = '';
      _state = AiAssistantState.idle;
      _safeNotify();
    }
  }

  Future<void> _finalizeVoiceTranscript(String transcript) async {
    await _voice.stopListening();
    _partialTranscript = '';
    await sendMessage(transcript, fromVoice: true);
  }

  Future<void> interruptSpeech() async {
    await _voice.stopSpeaking();
    if (_state == AiAssistantState.speaking) {
      _state = AiAssistantState.idle;
      _safeNotify();
    }
  }

  Future<AiChatResponse> _dispatchChat(String text) {
    final client = _backend;
    final statePayload = _buildRobotStatePayload();
    if (client is CloudAiBackendClient) {
      return client.sendMessageWithOptions(
        baseUrl: _voiceSettings.backendUrl,
        sessionId: _sessionId,
        message: text,
        robotState: statePayload,
        sessionToken: _sessionToken,
        allowLocalHttp: _voiceSettings.allowLocalDevHttp,
      );
    }
    return client.sendMessage(
      baseUrl: _voiceSettings.backendUrl,
      sessionId: _sessionId,
      message: text,
      robotState: statePayload,
    );
  }

  void _syncHealthFromException(AiBackendException exc) {
    _health = AiBackendHealth(
      reachable: exc.status == AiBackendStatus.llmUnavailable ||
          exc.status == AiBackendStatus.invalidApiKey ||
          exc.status == AiBackendStatus.rateLimited,
      configured: exc.status != AiBackendStatus.invalidApiKey &&
          exc.status != AiBackendStatus.llmUnavailable,
      provider: _health?.provider,
      model: _health?.model,
      status: exc.status,
      httpStatus: exc.httpStatus,
      retryAfterSeconds: exc.retryAfterSeconds,
    );
    _scheduleNextHealthCheck();
  }

  /// Envia mensagem de texto ou voz para o backend McQueen AI real, executa intenções validadas e lê a resposta.
  Future<void> sendMessage(
    String rawText, {
    bool fromVoice = false,
  }) async {
    final text = rawText.trim();
    if (text.isEmpty || isBusy) return;

    if (_state == AiAssistantState.speaking) {
      await _voice.stopSpeaking();
    }

    final reqGen = ++_requestGeneration;
    _errorMessage = null;
    _messages.add(
      AiChatMessage(
        id: _nextId(),
        isUser: true,
        text: text,
        timestamp: DateTime.now(),
        isVoiceInput: fromVoice,
      ),
    );
    _state = AiAssistantState.processing;
    _safeNotify();

    try {
      final response = await _dispatchChat(text);
      if (_disposed || reqGen != _requestGeneration) return;

      // Confirma servidor online quando /chat responde com sucesso
      _healthFailureStreak = 0;
      _health = AiBackendHealth(
        reachable: true,
        configured: true,
        provider: response.provider ?? _health?.provider,
        model: response.model ?? _health?.model,
        status: AiBackendStatus.online,
        httpStatus: 200,
      );

      final actionBadges = <String>[];
      if (response.intents.isNotEmpty) {
        _state = AiAssistantState.executingCommand;
        _safeNotify();

        final exec = await _executor.executeIntents(response.intents);
        if (_disposed || reqGen != _requestGeneration) return;
        actionBadges.addAll(exec.badges);
        for (final f in exec.failures) {
          actionBadges.add('⚠ $f');
        }
      }
      for (final b in response.blockedReasons) {
        actionBadges.add('⚠ $b');
      }

      final replyText = response.reply.isNotEmpty
          ? response.reply
          : 'Comando processado.';

      _messages.add(
        AiChatMessage(
          id: _nextId(),
          isUser: false,
          text: replyText,
          timestamp: DateTime.now(),
          actionBadges: actionBadges,
        ),
      );

      if (_voiceSettings.autoSpeak && !_disposed) {
        _state = AiAssistantState.speaking;
        _safeNotify();
        await _voice.speak(
          replyText,
          settings: _voiceSettings,
          onComplete: () {
            if (!_disposed &&
                reqGen == _requestGeneration &&
                _state == AiAssistantState.speaking) {
              _state = AiAssistantState.idle;
              _safeNotify();
            }
          },
        );
      } else {
        _state = AiAssistantState.idle;
        _safeNotify();
      }
    } on AiBackendException catch (e) {
      if (_disposed || reqGen != _requestGeneration) return;
      _errorMessage = e.message;
      _messages.add(
        AiChatMessage(
          id: _nextId(),
          isUser: false,
          text: e.message,
          timestamp: DateTime.now(),
          isError: true,
        ),
      );
      _state = AiAssistantState.error;
      _syncHealthFromException(e);
      _safeNotify();
    } catch (_) {
      if (_disposed || reqGen != _requestGeneration) return;
      const fallback = 'Erro inesperado ao se comunicar com o McQueen AI.';
      _errorMessage = fallback;
      _messages.add(
        AiChatMessage(
          id: _nextId(),
          isUser: false,
          text: fallback,
          timestamp: DateTime.now(),
          isError: true,
        ),
      );
      _state = AiAssistantState.error;
      _safeNotify();
    }
  }

  /// Parada de emergência imediata e cancelamento de processamento/voz/escuta.
  Future<void> emergencyStop() async {
    _requestGeneration++;
    _executor.cancelActiveMotion(sendStop: false);
    await _voice.cancelListening();
    await _voice.stopSpeaking();
    await robot.emergencyStop();
    if (_state != AiAssistantState.idle) {
      _state = AiAssistantState.idle;
      _partialTranscript = '';
      _safeNotify();
    }
  }

  /// Apaga histórico local e reinicia sessão e token isolado no backend.
  Future<void> clearConversation() async {
    _requestGeneration++;
    final oldSession = _sessionId;
    final oldToken = _sessionToken;
    _sessionId = 'mcqueen_${DateTime.now().millisecondsSinceEpoch}';
    _sessionToken = AiConfig.generateSessionToken();
    _messages.clear();
    _errorMessage = null;
    _partialTranscript = '';
    await _voice.cancelListening();
    await _voice.stopSpeaking();
    _state = AiAssistantState.idle;
    _safeNotify();

    final client = _backend;
    if (client is CloudAiBackendClient) {
      await client.clearSessionWithOptions(
        baseUrl: _voiceSettings.backendUrl,
        sessionId: oldSession,
        sessionToken: oldToken,
        allowLocalHttp: _voiceSettings.allowLocalDevHttp,
      );
    } else {
      await client.clearSession(
        baseUrl: _voiceSettings.backendUrl,
        sessionId: oldSession,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _requestGeneration++;
    _healthTimer?.cancel();
    _healthTimer = null;
    _executor.dispose();
    _voice.dispose();
    final client = _backend;
    if (client is CloudAiBackendClient) {
      client.disposeClient();
    }
    super.dispose();
  }
}
