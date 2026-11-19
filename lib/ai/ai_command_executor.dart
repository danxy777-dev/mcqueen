// lib/ai/ai_command_executor.dart
import 'dart:async';

import '../core/ble_constants.dart';
import '../core/robot_service.dart';
import '../models/ai_models.dart';
import '../models/robot_expression.dart';
import '../models/sound_item.dart';
import '../models/turn_signal_state.dart';

/// Resultado consolidado da validação e execução segura das intenções da IA no BLE.
class AiExecutionSummary {
  final List<String> badges;
  final List<String> failures;
  final bool timedMotionStarted;

  const AiExecutionSummary({
    this.badges = const [],
    this.failures = const [],
    this.timedMotionStarted = false,
  });
}

/// Camada local de segurança entre intenções estruturadas do LLM e o [RobotService] BLE.
///
/// Regras obrigatórias:
/// - Nunca aceita comandos fora da lista permitida (whitelist).
/// - Bloqueia todas as ações físicas se o BLE estiver desconectado.
/// - Impõe limite de velocidade e teto máximo de 2500 ms por pulso de movimento.
/// - Garante parada automática no vencimento do timer, desconexão BLE ou parada de emergência.
class AiCommandExecutor {
  static const int minDurationMs = 200;
  static const int maxDurationMs = 2500;
  static const int defaultDurationMs = 900;
  static const int minSpeedPct = 15;
  static const int maxSpeedPct = 100;

  final RobotService _robot;
  final void Function()? onMotionStateChanged;

  Timer? _stopTimer;
  Timer? _keepAliveTimer;
  bool _isTimedMotionActive = false;
  int _lastEmergencyCount = 0;
  bool _lastConnected = false;

  AiCommandExecutor(
    this._robot, {
    this.onMotionStateChanged,
  }) {
    _lastEmergencyCount = _robot.emergencyStopCount;
    _lastConnected = _robot.isConnected;
    _robot.addListener(_onRobotChanged);
  }

  bool get isTimedMotionActive => _isTimedMotionActive;

  void _onRobotChanged() {
    final emergencyChanged = _robot.emergencyStopCount != _lastEmergencyCount;
    final bleDropped = _lastConnected && !_robot.isConnected;
    _lastEmergencyCount = _robot.emergencyStopCount;
    _lastConnected = _robot.isConnected;

    if (emergencyChanged || bleDropped) {
      cancelActiveMotion(sendStop: false);
    }
  }

  void cancelActiveMotion({bool sendStop = true}) {
    _stopTimer?.cancel();
    _stopTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    final wasActive = _isTimedMotionActive;
    _isTimedMotionActive = false;
    if (sendStop && _robot.isConnected) {
      unawaited(_robot.stopJoystick());
    }
    if (wasActive) {
      onMotionStateChanged?.call();
    }
  }

  Future<AiExecutionSummary> executeIntents(List<RobotIntent> intents) async {
    if (intents.isEmpty) {
      return const AiExecutionSummary();
    }

    if (!_robot.isConnected) {
      return const AiExecutionSummary(
        failures: ['Bloqueado: ESP32 do McQueen desconectado do BLE.'],
      );
    }

    final badges = <String>[];
    final failures = <String>[];
    var startedMotion = false;

    final hasStop = intents.any((i) => i.tool == 'stop_robot');
    if (hasStop) {
      cancelActiveMotion(sendStop: false);
      await _robot.emergencyStop();
      badges.add('Parada prioritária executada (PARAR)');
    }

    for (final intent in intents) {
      if (hasStop && (intent.tool == 'move_robot' || intent.tool == 'stop_robot')) {
        continue;
      }
      if (!_robot.isConnected) {
        failures.add('Execução interrompida: conexão BLE perdida.');
        cancelActiveMotion(sendStop: false);
        break;
      }

      switch (intent.tool) {
        case 'stop_robot':
          cancelActiveMotion(sendStop: false);
          await _robot.emergencyStop();
          badges.add('PARAR executado');
          break;

        case 'move_robot':
          final moveBadge = await _executeMove(intent.arguments, failures);
          if (moveBadge != null) {
            badges.add(moveBadge);
            startedMotion = true;
          }
          break;

        case 'set_speed_mode':
          final modeStr =
              (intent.arguments['mode'] as String? ?? '').trim().toLowerCase();
          final level = switch (modeStr) {
            'eco' => SpeedLevel.eco,
            'normal' => SpeedLevel.normal,
            'sport' => SpeedLevel.sport,
            'turbo' => SpeedLevel.turbo,
            _ => null,
          };
          if (level == null) {
            failures.add('Modo de velocidade inválido: $modeStr');
          } else {
            await _robot.setSpeed(level);
            badges.add('Velocidade: ${level.label} (${level.percent}%)');
          }
          break;

        case 'set_indicator':
          final modeStr =
              (intent.arguments['mode'] as String? ?? '').trim().toLowerCase();
          final signal = switch (modeStr) {
            'left' => TurnSignalState.left,
            'right' => TurnSignalState.right,
            'hazard' => TurnSignalState.alert,
            'auto' => TurnSignalState.auto,
            'off' => TurnSignalState.off,
            _ => null,
          };
          if (signal == null) {
            failures.add('Indicador inválido: $modeStr');
          } else {
            await _robot.setTurnSignal(signal);
            badges.add('Indicador: ${signal.label}');
          }
          break;

        case 'activate_horn':
          if (!_robot.settings.soundsEnabled) {
            failures.add('Buzina não executada: som silenciado (MUTE).');
            break;
          }
          final style =
              (intent.arguments['style'] as String? ?? 'normal').toLowerCase();
          final (cmd, label) = switch (style) {
            'short' => (BleConstants.cmdBuzinaCurta, 'Buzina Curta'),
            'long' => (BleConstants.cmdBuzinaLonga, 'Buzina Longa'),
            'emergency' => (BleConstants.cmdBuzinaEmergencia, 'Buzina Emergência'),
            _ => (BleConstants.cmdBuzina, 'Buzina'),
          };
          final res = await _robot.triggerSound(cmd);
          if (res.ok) {
            badges.add(label);
          } else {
            failures.add(res.error ?? 'Falha ao acionar buzina.');
          }
          break;

        case 'play_sound_effect':
          if (!_robot.settings.soundsEnabled) {
            failures.add('Efeito sonoro bloqueado: som silenciado (MUTE).');
            break;
          }
          final effect =
              (intent.arguments['effect'] as String? ?? '').toLowerCase();
          final itemId = switch (effect) {
            'beep' => 'bipe_curto',
            'confirm' => 'seq_confirmacao',
            'init' => 'seq_inicializacao',
            'error' => 'som_erro',
            'laugh' => 'som_risada',
            'sos' => 'seq_sos',
            _ => null,
          };
          if (itemId == null) {
            failures.add('Efeito não suportado pelo buzzer ativo: $effect');
            break;
          }
          final item = SoundItem.catalog.firstWhere((s) => s.id == itemId);
          final res = await _robot.playSoundItem(item);
          if (res.ok) {
            badges.add('Som: ${item.title}');
          } else {
            failures.add(res.error ?? 'Falha ao reproduzir efeito sonoro.');
          }
          break;

        case 'set_face_expression':
          final exprRaw =
              (intent.arguments['expression'] as String? ?? '').trim().toUpperCase();
          final matches = RobotExpression.values.where((e) => e.code == exprRaw);
          if (matches.isEmpty) {
            failures.add('Expressão OLED inválida: $exprRaw');
          } else {
            final expr = matches.first;
            await _robot.setExpression(expr);
            badges.add('OLED: ${expr.label}');
          }
          break;

        default:
          failures.add('Comando rejeitado pela lista segura: ${intent.tool}');
      }
    }

    return AiExecutionSummary(
      badges: badges,
      failures: failures,
      timedMotionStarted: startedMotion,
    );
  }

  Future<String?> _executeMove(
    Map<String, dynamic> args,
    List<String> failures,
  ) async {
    final dirRaw = (args['direction'] as String? ?? '').trim().toLowerCase();
    final (bleBase, label) = switch (dirRaw) {
      'forward' => (BleConstants.cmdFrente, 'Avançar'),
      'backward' => (BleConstants.cmdTras, 'Ré'),
      'left' => (BleConstants.cmdEsquerda, 'Virar à esquerda'),
      'right' => (BleConstants.cmdDireita, 'Virar à direita'),
      _ => ('', ''),
    };
    if (bleBase.isEmpty) {
      failures.add('Direção de movimento inválida: $dirRaw');
      return null;
    }

    final requestedSpeed = (args['speed_percent'] as num?)?.round();
    final effectiveCap = _robot.settings.maxSpeedPercent.clamp(minSpeedPct, maxSpeedPct);
    final chosenSpeed = (requestedSpeed ?? _robot.speedPercent)
        .clamp(minSpeedPct, effectiveCap);

    final rawDuration = (args['duration_ms'] as num?)?.round() ?? defaultDurationMs;
    final durationMs = rawDuration.clamp(minDurationMs, maxDurationMs);

    cancelActiveMotion(sendStop: false);
    _isTimedMotionActive = true;
    onMotionStateChanged?.call();

    final packet = BleConstants.movement(bleBase, chosenSpeed);
    await _robot.sendCommand(packet);

    _keepAliveTimer = Timer.periodic(BleConstants.movementRepeatInterval, (_) {
      if (!_isTimedMotionActive || !_robot.isConnected) {
        cancelActiveMotion(sendStop: _robot.isConnected);
        return;
      }
      unawaited(_robot.sendCommand(packet));
    });

    _stopTimer = Timer(Duration(milliseconds: durationMs), () {
      cancelActiveMotion(sendStop: true);
    });

    return '$label ($chosenSpeed% · ${durationMs}ms)';
  }

  void dispose() {
    _robot.removeListener(_onRobotChanged);
    if (_isTimedMotionActive) {
      cancelActiveMotion(sendStop: _robot.isConnected);
    } else {
      cancelActiveMotion(sendStop: false);
    }
  }
}
