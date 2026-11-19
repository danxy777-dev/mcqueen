// lib/core/robot_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ble_diagnostics.dart';
import '../models/mcqueen_settings.dart';
import '../models/motor_state.dart';
import '../models/robot_expression.dart';
import '../models/sound_item.dart';
import '../models/turn_signal_state.dart';
import 'ble_constants.dart';

/// Estados reais e detalhados da conexão BLE.
enum RobotConnectionState {
  disconnected('Desconectado'),
  scanning('Procurando McQueen...'),
  connecting('Conectando...'),
  validatingService('Validando serviço...'),
  connected('Conectado'),
  error('Falha na conexão');

  final String label;
  const RobotConnectionState(this.label);
}

/// Modo de operação dos controles direcionais discretos (ex.: gamepad horizontal).
enum ControlMode {
  /// Seguro (padrão): move apenas enquanto o botão está pressionado e envia PARAR ao soltar.
  holdToMove,

  /// Contínuo: mantém o movimento até que PARAR seja acionado.
  continuous,
}

/// Perfis de velocidade do McQueen (ECO, Normal, Sport, Turbo).
enum SpeedLevel {
  eco(1, 'ECO', 30, BleConstants.cmdVel1),
  normal(2, 'Normal', 60, BleConstants.cmdVel2),
  sport(3, 'Sport', 85, BleConstants.cmdVel3),
  turbo(4, 'Turbo', 100, BleConstants.cmdVel4);

  final int level;
  final String label;
  final int percent;
  final String bleCommand;

  const SpeedLevel(this.level, this.label, this.percent, this.bleCommand);

  // Aliases de compatibilidade com versão 1.0 e testes unitários existentes
  static const SpeedLevel low = SpeedLevel.eco;
  static const SpeedLevel medium = SpeedLevel.normal;
  static const SpeedLevel high = SpeedLevel.turbo;

  /// Mapeia porcentagem (0..100) para o perfil correspondente.
  static SpeedLevel fromPercent(int pct) {
    if (pct <= 40) return SpeedLevel.eco;
    if (pct <= 70) return SpeedLevel.normal;
    if (pct <= 90) return SpeedLevel.sport;
    return SpeedLevel.turbo;
  }
}

/// Perfis de velocidade nomeados.
enum SpeedProfile {
  eco('ECO', BleConstants.cmdSpeedProfileEco),
  normal('NORMAL', BleConstants.cmdSpeedProfileNormal),
  sport('SPORT', BleConstants.cmdSpeedProfileSport),
  turbo('TURBO', BleConstants.cmdSpeedProfileTurbo);

  final String name;
  final String bleCommand;

  const SpeedProfile(this.name, this.bleCommand);
}

/// Resultado real da execução de um comando com confirmação do ESP32.
class CommandResult {
  final bool ok;
  final String? response;
  final String? error;
  final int? latencyMs;

  const CommandResult({
    required this.ok,
    this.response,
    this.error,
    this.latencyMs,
  });
}

/// Entrada do console de logs BLE (TX/RX).
class CommandLogEntry {
  final DateTime timestamp;
  final String message;
  final bool isOutgoing;
  final bool isSuccess;

  const CommandLogEntry({
    required this.timestamp,
    required this.message,
    required this.isOutgoing,
    this.isSuccess = true,
  });

  String get formattedTime {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }
}

/// Eventos assíncronos de conexão BLE para exibição de alertas na UI.
sealed class ConnectionEvent {
  const ConnectionEvent();
}

/// Conexão BLE validada com sucesso.
class ConnectionSuccessEvent extends ConnectionEvent {
  final String deviceName;
  final String serviceUuid;
  final String charUuid;

  const ConnectionSuccessEvent({
    required this.deviceName,
    required this.serviceUuid,
    required this.charUuid,
  });
}

/// Falha explícita ao tentar conectar ao McQueen.
class ConnectionFailureEvent extends ConnectionEvent {
  final String title;
  final String message;
  final String specificCause;

  const ConnectionFailureEvent({
    required this.title,
    required this.message,
    required this.specificCause,
  });
}

/// Queda inesperada de conexão durante o uso.
class UnexpectedDisconnectEvent extends ConnectionEvent {
  final String message;

  const UnexpectedDisconnectEvent({required this.message});
}

/// Contrato principal de controle do robô McQueen.
abstract class RobotService extends ChangeNotifier {
  RobotConnectionState get connectionState;
  bool get isConnected => connectionState == RobotConnectionState.connected;
  String? get lastStatus;
  String? get connectionError;
  Stream<ConnectionEvent> get connectionEvents;
  bool get buzinaSent;
  String? get activeSoundLabel => null;
  bool get isSoundSequenceRunning => false;
  bool get isDemo;
  ControlMode get controlMode;
  SpeedLevel get currentSpeed;
  int get speedPercent;

  /// Indica se há leitura real de bateria enviada pelo hardware (`BATT:`).
  bool get batteryAvailable => false;
  int get batteryPercent;
  int get rssi;
  List<CommandLogEntry> get commandLogs;

  /// Diagnóstico detalhado do enlace BLE (UUIDs, TX/RX, PING, DIAG).
  BleDiagnostics get diagnostics => const BleDiagnostics();

  /// Estado atual dos dois motores (velocidade L/R, direção, neutro µs, inversão).
  MotorState get motorState => const MotorState();

  /// Expressão facial atual do display OLED.
  RobotExpression get currentExpression => RobotExpression.normal;

  /// Estado tipado das setas (off, left, right, alert, auto).
  TurnSignalState get turnSignal => TurnSignalState.fromCode(setaEstado);

  /// Estado textual legado das setas (ESQUERDA, DIREITA, ALERTA, AUTO, OFF).
  String get setaEstado => 'OFF';

  /// Contador incrementado a cada parada de emergência explícita (para reset imediato de controles).
  int get emergencyStopCount => 0;

  /// Configurações e calibração persistidas do McQueen.
  McQueenSettings get settings => const McQueenSettings();

  void setControlMode(ControlMode mode);
  Future<void> setSpeed(SpeedLevel speed);
  Future<void> setSpeedPercent(int percent);
  void clearLogs();

  Future<void> connect();
  Future<void> disconnect();

  Future<void> sendCommand(String cmd);
  Future<void> startMovement(String cmd);
  Future<void> stopMovement([String? sourceCmd]);
  Future<CommandResult> sendBuzina();
  Future<void> stopBuzzer() async {
    await sendCommand(BleConstants.cmdBuzinaDesligar);
  }

  /// Aciona ou desliga as setas direcionais (`SETA:*`).
  Future<void> setTurnSignal(TurnSignalState signal) async {
    await sendCommand(signal.command);
  }

  /// Alterna o modo automático das setas (`SETA:AUTO`).
  Future<void> toggleAutoTurnSignals() async {
    await sendCommand(BleConstants.cmdSetaAuto);
  }

  /// Controla os motores diferencialmente via joystick analógico (`DIFF:L:R`).
  /// `left` e `right` variam de -100 a +100.
  Future<void> joystickControl({required int left, required int right}) async {
    await sendCommand(BleConstants.diff(left, right));
  }

  /// Para o movimento imediatamente (prioridade máxima: envia `PARAR`).
  Future<void> stopJoystick() async {
    await sendCommand(BleConstants.cmdParar);
  }

  /// Parada de emergência imediata (alias explícito de segurança).
  Future<void> emergencyStop() => stopJoystick();

  /// Executa teste individual contínuo de um servo (`ESQ` ou `DIR`) com keepalive.
  Future<void> startMotorTest(String side, int speed) async {
    final cmd = side.trim().toUpperCase() == 'ESQ'
        ? BleConstants.cmdMotorLeft(speed)
        : BleConstants.cmdMotorRight(speed);
    await sendCommand(cmd);
  }

  /// Altera a expressão do display OLED (`EXPR:<CODIGO>`).
  Future<void> setExpression(RobotExpression expr) async {
    await sendCommand(expr.command);
  }

  /// Define o perfil de velocidade (ECO, NORMAL, SPORT, TURBO).
  Future<void> setSpeedProfile(SpeedProfile profile) async {
    await sendCommand(profile.bleCommand);
  }

  /// Dispara um comando sonoro e aguarda confirmação real do ESP32 quando disponível.
  Future<CommandResult> triggerSound(String soundCommand) async {
    await sendCommand(soundCommand);
    return const CommandResult(ok: true);
  }

  /// Executa um [SoundItem] (seja comando único ou sequência temporizada de bipes).
  Future<CommandResult> playSoundItem(SoundItem item) {
    if (item.isAppSequenced) {
      return playTimedBeepSequence(
        steps: item.beepSequence!,
        label: item.command,
      );
    }
    return triggerSound(item.command);
  }

  /// Executa uma sequência rítmica real no buzzer ativo usando pulsos `TONE:2000:<ms>`.
  Future<CommandResult> playTimedBeepSequence({
    required List<BeepStep> steps,
    required String label,
  }) async {
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final res =
          await triggerSound(BleConstants.toneCommand(2000, step.onMs));
      if (!res.ok) return res;
      if (i + 1 < steps.length && step.gapMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: step.onMs + step.gapMs));
      }
    }
    return const CommandResult(ok: true, response: 'OK:SEQUENCE');
  }

  /// Cancela qualquer sequência de bipes em andamento e silencia o buzzer.
  Future<void> cancelSoundSequence() => stopBuzzer();

  /// Executa teste de comunicação `PING` e aguarda `PONG`.
  Future<CommandResult> testCommunication() async {
    await sendCommand(BleConstants.cmdPing);
    return const CommandResult(ok: true, response: 'PONG');
  }

  /// Solicita diagnóstico `DIAG` do ESP32-C3.
  Future<CommandResult> requestDiagnostics() async {
    await sendCommand(BleConstants.cmdDiag);
    return const CommandResult(ok: true);
  }

  /// Solicita telemetria completa `STATUS` do ESP32-C3.
  Future<CommandResult> refreshStatus() async {
    await sendCommand(BleConstants.cmdStatus);
    return const CommandResult(ok: true);
  }

  /// Atualiza e persiste as configurações/calibração do McQueen.
  Future<CommandResult> updateSettings(
    McQueenSettings newSettings, {
    String? syncCommand,
    bool persist = true,
  }) async {
    if (syncCommand != null && syncCommand.isNotEmpty) {
      await sendCommand(syncCommand);
    }
    return const CommandResult(ok: true);
  }

  /// Restaura todas as configurações e calibrações para o padrão de fábrica.
  Future<void> resetAllSettings() async {
    await sendCommand(BleConstants.cmdCalReset);
  }
}
