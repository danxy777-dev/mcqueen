// lib/ai/voice_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/ai_models.dart';

/// Contrato de entrada e saída de voz (STT e TTS) para o McQueen AI.
abstract class VoiceService {
  Future<bool> startListening({
    required void Function(String words, bool isFinal) onResult,
    required void Function(String status) onStatus,
    required void Function(String errorMessage) onError,
  });

  Future<void> stopListening();
  Future<void> cancelListening();

  Future<void> speak(
    String text, {
    required AiVoiceSettings settings,
    void Function()? onComplete,
  });

  Future<void> stopSpeaking();
  void dispose();
}

/// Implementação real Android/dispositivo com `speech_to_text` (pt-BR) + `flutter_tts` (pt-BR).
class DeviceVoiceService implements VoiceService {
  final SpeechToText _stt = SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _sttInitialized = false;
  bool _ttsInitialized = false;
  void Function()? _pendingSpeakComplete;
  void Function(String error)? _activeSttErrorCallback;

  Future<void> _ensureTtsInitialized() async {
    if (_ttsInitialized) return;
    _ttsInitialized = true;
    try {
      await _tts.setLanguage('pt-BR');
      await _tts.awaitSpeakCompletion(false);

      // Tenta selecionar voz masculina pt-BR se disponível no mecanismo Android TTS
      try {
        final rawVoices = await _tts.getVoices;
        if (rawVoices is List) {
          Map<String, String>? bestVoice;
          for (final v in rawVoices) {
            if (v is! Map) continue;
            final locale = (v['locale'] ?? '').toString().toLowerCase();
            final name = (v['name'] ?? '').toString().toLowerCase();
            if (!locale.contains('pt') || !locale.contains('br')) continue;
            final mapVoice = v.map(
              (k, val) => MapEntry(k.toString(), val.toString()),
            );
            bestVoice ??= mapVoice;
            if (name.contains('male') ||
                name.contains('ptt') ||
                name.contains('afs') ||
                name.contains('ptd') ||
                name.contains('ricardo') ||
                name.contains('felipe')) {
              bestVoice = mapVoice;
              break;
            }
          }
          if (bestVoice != null) {
            await _tts.setVoice(bestVoice);
          }
        }
      } catch (_) {}

      _tts.setCompletionHandler(() {
        final cb = _pendingSpeakComplete;
        _pendingSpeakComplete = null;
        cb?.call();
      });
      _tts.setCancelHandler(() {
        final cb = _pendingSpeakComplete;
        _pendingSpeakComplete = null;
        cb?.call();
      });
      _tts.setErrorHandler((_) {
        final cb = _pendingSpeakComplete;
        _pendingSpeakComplete = null;
        cb?.call();
      });
    } catch (e) {
      debugPrint('[VOICE] Aviso ao configurar TTS: $e');
    }
  }

  @override
  Future<bool> startListening({
    required void Function(String words, bool isFinal) onResult,
    required void Function(String status) onStatus,
    required void Function(String errorMessage) onError,
  }) async {
    _activeSttErrorCallback = onError;
    if (!_sttInitialized) {
      try {
        _sttInitialized = await _stt.initialize(
          onStatus: onStatus,
          onError: (err) {
            _activeSttErrorCallback?.call(
              'Reconhecimento de voz (${err.errorMsg}). Tente novamente.',
            );
          },
        );
      } catch (e) {
        onError('Falha ao inicializar microfone: $e');
        return false;
      }
    }

    if (!_sttInitialized) {
      onError(
        'Reconhecimento de voz indisponível ou permissão de microfone negada no dispositivo.',
      );
      return false;
    }

    try {
      await _stt.listen(
        listenOptions: SpeechListenOptions(
          localeId: 'pt_BR',
          listenFor: const Duration(seconds: 20),
          pauseFor: const Duration(seconds: 3),
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.confirmation,
        ),
        onResult: (result) {
          onResult(result.recognizedWords, result.finalResult);
        },
      );
      return true;
    } catch (e) {
      onError('Não foi possível iniciar a escuta: $e');
      return false;
    }
  }

  @override
  Future<void> stopListening() async {
    try {
      if (_stt.isListening) {
        await _stt.stop();
      }
    } catch (_) {}
  }

  @override
  Future<void> cancelListening() async {
    try {
      await _stt.cancel();
    } catch (_) {}
  }

  @override
  Future<void> speak(
    String text, {
    required AiVoiceSettings settings,
    void Function()? onComplete,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      onComplete?.call();
      return;
    }
    await _ensureTtsInitialized();
    _pendingSpeakComplete = onComplete;
    try {
      await _tts.setVolume(settings.volume);
      await _tts.setSpeechRate(settings.effectiveRate);
      await _tts.setPitch(settings.effectivePitch);
      await _tts.speak(clean);
    } catch (_) {
      final cb = _pendingSpeakComplete;
      _pendingSpeakComplete = null;
      cb?.call();
    }
  }

  @override
  Future<void> stopSpeaking() async {
    final cb = _pendingSpeakComplete;
    _pendingSpeakComplete = null;
    try {
      await _tts.stop();
    } catch (_) {}
    cb?.call();
  }

  @override
  void dispose() {
    _activeSttErrorCallback = null;
    _pendingSpeakComplete = null;
    unawaited(cancelListening());
    unawaited(stopSpeaking());
  }
}
