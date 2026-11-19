// lib/core/demo_robot_service.dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/ble_diagnostics.dart';
import '../models/mcqueen_settings.dart';
import '../models/motor_state.dart';
import '../models/robot_expression.dart';
import '../models/sound_item.dart';
import '../models/turn_signal_state.dart';
import 'ble_constants.dart';
import 'robot_service.dart';

class DemoRobotService extends RobotService {
  RobotConnectionState _state = RobotConnectionState.disconnected;
  String? _lastStatus;
  bool _buzinaSent = false;
  String? _activeSoundLabel;
  Timer? _buzzerIndicatorTimer;
  bool _isSoundSequenceRunning = false;
  int _soundSequenceToken = 0;
  Completer<void>? _sequenceWaitCompleter;
  int _emergencyStopCount = 0;

  ControlMode _controlMode = ControlMode.holdToMove;
  int _speedPercent = SpeedLevel.medium.percent;
  int _battery = 94;
  int _rssi = -58;
  String? _activeMovement;
  MotorState _motorState = const MotorState();
  RobotExpression _expression = RobotExpression.normal;
  TurnSignalState _turnSignal = TurnSignalState.off;
  McQueenSettings _settings = const McQueenSettings();
  BleDiagnostics _diagnostics = const BleDiagnostics();

  final List<CommandLogEntry> _commandLogs = [];
  final StreamController<ConnectionEvent> _connectionEvents =
      StreamController<ConnectionEvent>.broadcast();

  @override RobotConnectionState get connectionState => _state;
  @override String? get lastStatus => _lastStatus;
  @override String? get connectionError => null;
  @override Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override bool get buzinaSent => _buzinaSent;
  @override String? get activeSoundLabel => _activeSoundLabel;
  @override bool get isSoundSequenceRunning => _isSoundSequenceRunning;
  @override bool get isDemo => true;
  @override ControlMode get controlMode => _controlMode;
  @override SpeedLevel get currentSpeed => SpeedLevel.fromPercent(_speedPercent);
  @override int get speedPercent => _speedPercent;
  @override bool get batteryAvailable => true;
  @override int get batteryPercent => _battery;
  @override int get rssi => _rssi;
  @override List<CommandLogEntry> get commandLogs => List.unmodifiable(_commandLogs);
  @override BleDiagnostics get diagnostics => _diagnostics;
  @override MotorState get motorState => _motorState;
  @override RobotExpression get currentExpression => _expression;
  @override TurnSignalState get turnSignal => _turnSignal;
  @override String get setaEstado => switch (_turnSignal) {
        TurnSignalState.left => 'ESQUERDA',
        TurnSignalState.right => 'DIREITA',
        TurnSignalState.alert => 'ALERTA',
        TurnSignalState.auto => 'AUTO',
        TurnSignalState.off => 'OFF',
      };
  @override McQueenSettings get settings => _settings;
  @override int get emergencyStopCount => _emergencyStopCount;

  @override
  void setControlMode(ControlMode mode) {
    if (_controlMode == mode) return;
    _controlMode = mode;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(SpeedLevel speed) async {
    _speedPercent = speed.percent;
    notifyListeners();
    if (!isConnected) return;
    await sendCommand(speed.bleCommand);
    if (_activeMovement != null) {
      _updateLocalMotorStateForDirection(_activeMovement!, _speedPercent);
      notifyListeners();
      await _dispatchSimulatedCommand(
        BleConstants.movement(_activeMovement!, _speedPercent),
        log: false,
      );
    }
  }

  @override
  Future<void> setSpeedPercent(int percent) async {
    _speedPercent = BleConstants.clampPercent(percent);
    notifyListeners();
    if (!isConnected) return;
    await sendCommand(BleConstants.speed(_speedPercent));
    if (_activeMovement != null) {
      _updateLocalMotorStateForDirection(_activeMovement!, _speedPercent);
      notifyListeners();
      await _dispatchSimulatedCommand(
        BleConstants.movement(_activeMovement!, _speedPercent),
        log: false,
      );
    }
  }

  @override
  void clearLogs() {
    _commandLogs.clear();
    notifyListeners();
  }

  // ── Conexão simulada ─────────────────────────────────────────────────────────
  @override
  Future<void> connect() async {
    if (_state != RobotConnectionState.disconnected) return;

    _setState(RobotConnectionState.scanning);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_isDisposed) return;

    _setState(RobotConnectionState.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_isDisposed) return;

    _battery = 92;
    _rssi = -55;
    _diagnostics = _diagnostics.copyWith(
      deviceName: 'McQueen (Simulado)',
      deviceId: 'DEMO:00:11:22:33:44',
      serviceValidated: true,
      rxCanWrite: true,
      rxCanWriteWithoutResponse: true,
      txNotifyEnabled: true,
      lastPingLatencyMs: 24,
    );
    _setState(RobotConnectionState.connected);
    _recordLog('CONEXAO: ESTABELECIDA', isOutgoing: false);
    _setStatus('OK:CONECTADO');
    debugPrint('[DEMO] Conectado ao McQueen (simulado).');
  }

  @override
  Future<void> disconnect() async {
    _interruptRunningSoundSequence();
    _recordLog('CONEXAO: ENCERRADA', isOutgoing: false);
    _lastStatus = null;
    _activeMovement = null;
    _turnSignal = TurnSignalState.off;
    _clearBuzzerActive();
    _motorState = _motorState.copyWith(
        leftSpeed: 0, rightSpeed: 0, direction: 'PARADO');
    _diagnostics = _diagnostics.copyWith(
      clearDevice: true,
      serviceValidated: false,
      rxCanWrite: false,
      rxCanWriteWithoutResponse: false,
      txNotifyEnabled: false,
    );
    _setState(RobotConnectionState.disconnected);
    debugPrint('[DEMO] Desconectado.');
  }

  void _updateLocalMotorStateForDirection(String base, int effectiveSpeed) {
    final (l, r) = switch (base) {
      'FRENTE' => (effectiveSpeed, effectiveSpeed),
      'TRAS' => (-effectiveSpeed, -effectiveSpeed),
      'ESQUERDA' || 'ESQ' => (-effectiveSpeed, effectiveSpeed),
      'DIREITA' || 'DIR' => (effectiveSpeed, -effectiveSpeed),
      _ => (0, 0),
    };
    _motorState = _motorState.copyWith(
      leftSpeed: l,
      rightSpeed: r,
      direction: (l == 0 && r == 0) ? 'PARADO' : base,
    );
  }

  // ── Movimentação com segurança (Hold-to-move) ────────────────────────────────
  @override
  Future<void> startMovement(String cmd) async {
    final base = cmd.split(':').first.toUpperCase();
    _activeMovement = base;
    _updateLocalMotorStateForDirection(base, _speedPercent);
    notifyListeners();
    await sendCommand(cmd);
  }

  @override
  Future<void> stopMovement([String? sourceCmd]) async {
    if (_controlMode == ControlMode.holdToMove) {
      if (sourceCmd != null && _activeMovement != null) {
        final releasedBase = sourceCmd.split(':').first.toUpperCase();
        if (_activeMovement != releasedBase) return;
      }
      _activeMovement = null;
      _motorState = _motorState.copyWith(
          leftSpeed: 0, rightSpeed: 0, direction: 'PARADO');
      notifyListeners();
      await sendCommand(BleConstants.cmdParar);
    }
  }

  void _interruptRunningSoundSequence() {
    _soundSequenceToken++;
    _isSoundSequenceRunning = false;
    final wait = _sequenceWaitCompleter;
    _sequenceWaitCompleter = null;
    if (wait != null && !wait.isCompleted) {
      wait.complete();
    }
  }

  void _markBuzzerActive(String label, [int durationMs = 500]) {
    _buzzerIndicatorTimer?.cancel();
    _buzinaSent = true;
    _activeSoundLabel = label;
    notifyListeners();
    _buzzerIndicatorTimer = Timer(Duration(milliseconds: durationMs), () {
      _clearBuzzerActive();
      notifyListeners();
    });
  }

  void _clearBuzzerActive() {
    _buzzerIndicatorTimer?.cancel();
    _buzzerIndicatorTimer = null;
    _buzinaSent = false;
    _activeSoundLabel = null;
  }

  Future<String> _dispatchSimulatedCommand(String cmd, {bool log = true}) async {
    if (!isConnected || _isDisposed) return 'ERR:DISCONNECTED';

    final now = DateTime.now();
    final upper = cmd.trim().toUpperCase();
    var reply = 'OK:$cmd';

    if (log) {
      _recordLog('TX → $cmd', isOutgoing: true);
    }
    _diagnostics = _diagnostics.copyWith(
      lastTxCommand: cmd,
      lastTxAt: now,
    );
    debugPrint('[DEMO] → $cmd');

    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (_isDisposed || !isConnected) return 'ERR:DISCONNECTED';

    if (BleConstants.isStopCommand(cmd)) {
      _activeMovement = null;
      _motorState = _motorState.copyWith(
          leftSpeed: 0, rightSpeed: 0, direction: 'PARADO');
      reply = 'OK:PARAR';
    } else if (upper == BleConstants.cmdPing) {
      reply = 'PONG';
      _diagnostics = _diagnostics.copyWith(lastPingLatencyMs: 50);
    } else if (upper == BleConstants.cmdDiag) {
      reply = 'DIAG:ADV:1|CONN:1|READY:1|LEN:24|SRV:1';
      _diagnostics = _diagnostics.copyWith(
        lastDiagRaw: reply,
        diagAdvertising: true,
        diagConnected: true,
        diagReady: true,
        diagAdvPayloadBytes: 24,
        diagServosEnabled: true,
      );
    } else if (upper == BleConstants.cmdStatus) {
      reply =
          'V:$_speedPercent|M:${_motorState.isMoving ? 1 : 0}|L:${_motorState.leftNeutralUs}|R:${_motorState.rightNeutralUs}|I:${_motorState.leftInverted ? 1 : 0}${_motorState.rightInverted ? 1 : 0}|SL:${_motorState.leftSpeed}|SR:${_motorState.rightSpeed}|E:${_expression.code}|B:${_buzinaSent ? 1 : 0}|VMIN:${_settings.minSpeedPercent}|VMAX:${_settings.maxSpeedPercent}|TL:${_settings.leftTrimPercent}|TR:${_settings.rightTrimPercent}|A:${_settings.autoReactionsEnabled ? 1 : 0}|MU:${_settings.soundsEnabled ? 0 : 1}|S:${_turnSignal.code}';
      _diagnostics = _diagnostics.copyWith(lastStatusSyncAt: DateTime.now());
    } else if (upper.startsWith('MOTOR:')) {
      final parts = upper.split(':');
      if (parts.length == 3 && (parts[1] == 'ESQ' || parts[1] == 'DIR')) {
        final spd = int.tryParse(parts[2]) ?? 0;
        _motorState = _motorState.copyWith(
          leftSpeed: parts[1] == 'ESQ' ? spd : 0,
          rightSpeed: parts[1] == 'DIR' ? spd : 0,
          direction: spd == 0 ? 'PARADO' : 'MOTOR_${parts[1]}',
        );
        reply = 'OK:MOTOR:${parts[1]}';
      } else {
        reply = 'ERR:MOTOR';
      }
    } else if (upper.startsWith('VELOCIDADE:')) {
      final v = int.tryParse(upper.substring(11));
      if (v != null && v >= 0 && v <= 100) {
        _speedPercent = v;
        reply = 'OK:VEL:$_speedPercent';
      } else {
        reply = 'ERR:VEL';
      }
    } else if (upper == BleConstants.cmdCalReset) {
      _settings = const McQueenSettings();
      _motorState = const MotorState();
      reply = 'OK:CAL:RESET';
    } else if (upper == BleConstants.cmdAutoOn) {
      _settings = _settings.copyWith(autoReactionsEnabled: true);
      reply = 'OK:AUTO:ON';
    } else if (upper == BleConstants.cmdAutoOff) {
      _settings = _settings.copyWith(autoReactionsEnabled: false);
      reply = 'OK:AUTO:OFF';
    } else if (upper.startsWith('AUTO:FREQ:')) {
      final sec = int.tryParse(upper.substring(10));
      if (sec != null && sec >= 3 && sec <= 120) {
        _settings = _settings.copyWith(reactionIntervalSeconds: sec);
        reply = 'OK:AUTO:FREQ:$sec';
      } else {
        reply = 'ERR:AUTO:FREQ';
      }
    } else if (upper.startsWith('AUTO:MASK:')) {
      reply = 'OK:AUTO:MASK';
    } else if (upper.startsWith('DIFF:')) {
      final parts = upper.split(':');
      if (parts.length == 3) {
        final l = int.tryParse(parts[1]) ?? 0;
        final r = int.tryParse(parts[2]) ?? 0;
        reply = 'OK:DIFF:$l:$r';
      }
    } else if (upper.startsWith('EXPR:')) {
      _expression = RobotExpression.fromCode(cmd.substring(5));
      reply = 'OK:EXPR:${_expression.code}';
    } else if (upper.startsWith('SETA:')) {
      if (upper == BleConstants.cmdSetaAuto) {
        _turnSignal =
            _turnSignal == TurnSignalState.auto ? TurnSignalState.off : TurnSignalState.auto;
        reply = _turnSignal == TurnSignalState.auto
            ? 'OK:SETA:AUTO:ON'
            : 'OK:SETA:AUTO:OFF';
      } else {
        _turnSignal = TurnSignalState.fromCode(upper.substring(5));
        reply = 'OK:SETA:${upper.substring(5)}';
      }
    } else if (upper == BleConstants.cmdSomMuteOn) {
      _settings = _settings.copyWith(soundsEnabled: false);
      _clearBuzzerActive();
      reply = 'OK:SOM:MUTE:1';
    } else if (upper == BleConstants.cmdSomMuteOff) {
      _settings = _settings.copyWith(soundsEnabled: true);
      reply = 'OK:SOM:MUTE:0';
    } else if (upper == BleConstants.cmdBuzzerAtivo) {
      _settings = _settings.copyWith(activeBuzzerMode: true);
      reply = 'OK:BUZZER:ATIVO';
    } else if (upper == BleConstants.cmdBuzzerPassivo) {
      _settings = _settings.copyWith(activeBuzzerMode: false);
      reply = 'OK:BUZZER:PASSIVO';
    } else if (upper == BleConstants.cmdBuzinaDesligar ||
        upper == BleConstants.cmdMute ||
        upper == 'PARAR_BUZZER') {
      _clearBuzzerActive();
      reply = upper == BleConstants.cmdBuzinaDesligar
          ? 'OK:BUZINA:DESLIGAR'
          : 'OK:BUZZER:OFF';
    } else if (upper.startsWith('BUZINA') ||
        upper == BleConstants.cmdBipe ||
        upper == BleConstants.cmdAlerta ||
        upper.startsWith('SOM:') ||
        upper.startsWith('MELODIA:') ||
        upper.startsWith('TONE:')) {
      if (!_settings.soundsEnabled) {
        _clearBuzzerActive();
        reply = 'OK:BUZZER:MUTED';
      } else {
        final durationMs = upper == BleConstants.cmdBuzinaLonga
            ? 650
            : (upper == BleConstants.cmdBuzinaEmergencia ||
                    upper == BleConstants.cmdAlerta
                ? 750
                : 500);
        if (upper.startsWith('TONE:')) {
          reply = 'OK:BUZZER:TONE';
          if (!_isSoundSequenceRunning) {
            _markBuzzerActive('BUZZER:TONE', durationMs);
          }
        } else {
          _markBuzzerActive(upper, durationMs);
        }
      }
    } else if (upper == BleConstants.cmdVel1 ||
        upper == 'VEL:ECO' ||
        upper == 'SPEED_PROFILE:ECO') {
      _speedPercent = 30;
      reply = 'OK:VEL:ECO';
    } else if (upper == BleConstants.cmdVel2 ||
        upper == 'VEL:NORMAL' ||
        upper == 'SPEED_PROFILE:NORMAL') {
      _speedPercent = 60;
      reply = 'OK:VEL:NORMAL';
    } else if (upper == BleConstants.cmdVel3 ||
        upper == 'VEL:SPORT' ||
        upper == 'SPEED_PROFILE:SPORT') {
      _speedPercent = 85;
      reply = 'OK:VEL:SPORT';
    } else if (upper == BleConstants.cmdVel4 ||
        upper == 'VEL:TURBO' ||
        upper == 'SPEED_PROFILE:TURBO') {
      _speedPercent = 100;
      reply = 'OK:VEL:TURBO';
    }

    _diagnostics = _diagnostics.copyWith(
      lastRxResponse: reply,
      lastRxAt: DateTime.now(),
      clearError: !reply.startsWith('ERR:'),
      lastError: reply.startsWith('ERR:') ? reply : null,
    );

    if (log || !upper.startsWith('DIFF:')) {
      _recordLog('RX ← $reply',
          isOutgoing: false, isSuccess: !reply.startsWith('ERR:'));
    }
    _setStatus(reply);
    return reply;
  }

  @override
  Future<void> sendCommand(String cmd) async {
    await _dispatchSimulatedCommand(cmd);
  }

  @override
  Future<CommandResult> sendBuzina() => triggerSound(BleConstants.cmdBuzina);

  @override
  Future<void> stopBuzzer() async {
    _interruptRunningSoundSequence();
    _clearBuzzerActive();
    notifyListeners();
    if (isConnected) {
      await sendCommand(BleConstants.cmdBuzinaDesligar);
    }
  }

  @override
  Future<void> startMotorTest(String side, int speed) async {
    if (!isConnected) return;
    final normSide = side.trim().toUpperCase() == 'DIR' ? 'DIR' : 'ESQ';
    final clamped = speed.clamp(-100, 100);
    if (clamped == 0) {
      await stopJoystick();
      return;
    }
    _activeMovement = null;
    _motorState = _motorState.copyWith(
      leftSpeed: normSide == 'ESQ' ? clamped : 0,
      rightSpeed: normSide == 'DIR' ? clamped : 0,
      direction: 'MOTOR_$normSide',
    );
    notifyListeners();
    await sendCommand(
      normSide == 'ESQ'
          ? BleConstants.cmdMotorLeft(clamped)
          : BleConstants.cmdMotorRight(clamped),
    );
  }

  @override
  Future<void> setTurnSignal(TurnSignalState signal) async {
    if (!isConnected) return;
    await sendCommand(signal.command);
  }

  @override
  Future<void> toggleAutoTurnSignals() async {
    if (!isConnected) return;
    await sendCommand(BleConstants.cmdSetaAuto);
  }

  @override
  Future<void> joystickControl({required int left, required int right}) async {
    if (!isConnected) return;

    _activeMovement = null;
    final maxCap = _speedPercent.clamp(0, 100);
    final scaledLeft =
        (left * _settings.sensitivity).round().clamp(-maxCap, maxCap);
    final scaledRight =
        (right * _settings.sensitivity).round().clamp(-maxCap, maxCap);

    _motorState = _motorState.copyWith(
      leftSpeed: scaledLeft,
      rightSpeed: scaledRight,
      direction: _directionLabelFor(scaledLeft, scaledRight),
    );
    notifyListeners();

    final packet = BleConstants.diff(scaledLeft, scaledRight);
    await _dispatchSimulatedCommand(packet, log: packet == BleConstants.cmdParar);
  }

  String _directionLabelFor(int left, int right) {
    if (left == 0 && right == 0) return 'PARADO';
    if (left > 0 && right > 0) {
      if ((left - right).abs() <= 15) return 'FRENTE';
      return left > right ? 'DIREITA' : 'ESQUERDA';
    }
    if (left < 0 && right < 0) {
      if ((left - right).abs() <= 15) return 'TRAS';
      return left < right ? 'ESQUERDA' : 'DIREITA';
    }
    return left < right ? 'ESQUERDA' : 'DIREITA';
  }

  @override
  Future<void> stopJoystick() async {
    _activeMovement = null;
    _motorState = _motorState.copyWith(
        leftSpeed: 0, rightSpeed: 0, direction: 'PARADO');
    notifyListeners();
    if (isConnected) {
      await sendCommand(BleConstants.cmdParar);
    }
  }

  @override
  Future<void> emergencyStop() async {
    _emergencyStopCount++;
    await stopJoystick();
  }

  @override
  Future<void> setExpression(RobotExpression expr) async {
    _settings = _settings.copyWith(baseExpression: expr);
    if (!isConnected) {
      _expression = expr;
      notifyListeners();
      return;
    }
    await sendCommand(expr.command);
  }

  @override
  Future<CommandResult> triggerSound(String soundCommand) =>
      _triggerSoundInternal(soundCommand, isSequenceStep: false);

  Future<CommandResult> _triggerSoundInternal(
    String soundCommand, {
    required bool isSequenceStep,
  }) async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    if (!isSequenceStep && _isSoundSequenceRunning) {
      _interruptRunningSoundSequence();
      _clearBuzzerActive();
      notifyListeners();
    }
    final upper = soundCommand.trim().toUpperCase();
    final allowWhenMuted = upper == BleConstants.cmdMute ||
        upper == BleConstants.cmdBuzinaDesligar ||
        upper.startsWith('SOM:MUTE:');
    if (!_settings.soundsEnabled && !allowWhenMuted) {
      return const CommandResult(
          ok: false, error: 'Sons silenciados nas configurações.');
    }
    final reply = await _dispatchSimulatedCommand(soundCommand);
    if (reply == 'OK:BUZZER:MUTED') {
      return CommandResult(
          ok: false, response: reply, error: 'Buzzer silenciado.');
    }
    if (reply.startsWith('ERR:')) {
      return CommandResult(ok: false, response: reply, error: reply);
    }
    return CommandResult(ok: true, response: reply);
  }

  Future<void> _waitCancelableSequenceDelay(int ms, int token) async {
    if (ms <= 0 || token != _soundSequenceToken || !isConnected || _isDisposed) {
      return;
    }
    final wait = Completer<void>();
    _sequenceWaitCompleter = wait;
    final timer = Timer(Duration(milliseconds: ms), () {
      if (!wait.isCompleted) wait.complete();
    });
    try {
      await wait.future;
    } finally {
      timer.cancel();
      if (identical(_sequenceWaitCompleter, wait)) {
        _sequenceWaitCompleter = null;
      }
    }
  }

  @override
  Future<CommandResult> playTimedBeepSequence({
    required List<BeepStep> steps,
    required String label,
  }) async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    if (!_settings.soundsEnabled) {
      return const CommandResult(
          ok: false, error: 'Sons silenciados nas configurações.');
    }
    if (steps.isEmpty) {
      return const CommandResult(ok: false, error: 'Sequência vazia.');
    }
    _interruptRunningSoundSequence();
    _buzzerIndicatorTimer?.cancel();
    _buzzerIndicatorTimer = null;

    final token = _soundSequenceToken;
    _isSoundSequenceRunning = true;
    _buzinaSent = true;
    _activeSoundLabel = label;
    notifyListeners();
    try {
      for (var i = 0; i < steps.length; i++) {
        if (token != _soundSequenceToken || !isConnected || _isDisposed) {
          return const CommandResult(
              ok: false, error: 'Sequência interrompida.');
        }
        final step = steps[i];
        final res = await _triggerSoundInternal(
          BleConstants.toneCommand(2000, step.onMs),
          isSequenceStep: true,
        );
        if (!res.ok) return res;
        if (token != _soundSequenceToken || !isConnected || _isDisposed) {
          return const CommandResult(
              ok: false, error: 'Sequência interrompida.');
        }
        if (i + 1 < steps.length) {
          await _waitCancelableSequenceDelay(step.onMs + step.gapMs, token);
        } else {
          await _waitCancelableSequenceDelay(step.onMs, token);
        }
      }
      return const CommandResult(ok: true, response: 'OK:SEQUENCE');
    } finally {
      if (token == _soundSequenceToken && !_isDisposed) {
        _isSoundSequenceRunning = false;
        _clearBuzzerActive();
        notifyListeners();
      }
    }
  }

  @override
  Future<void> cancelSoundSequence() async {
    _interruptRunningSoundSequence();
    await stopBuzzer();
  }

  @override
  Future<CommandResult> testCommunication() async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    final reply = await _dispatchSimulatedCommand(BleConstants.cmdPing);
    return CommandResult(
      ok: reply == 'PONG',
      response: reply,
      latencyMs: _diagnostics.lastPingLatencyMs,
    );
  }

  @override
  Future<CommandResult> requestDiagnostics() async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    final reply = await _dispatchSimulatedCommand(BleConstants.cmdDiag);
    return CommandResult(ok: reply.startsWith('DIAG:'), response: reply);
  }

  @override
  Future<CommandResult> refreshStatus() async {
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    final reply = await _dispatchSimulatedCommand(BleConstants.cmdStatus);
    return CommandResult(ok: reply.startsWith('V:'), response: reply);
  }

  @override
  Future<CommandResult> updateSettings(
    McQueenSettings newSettings, {
    String? syncCommand,
    bool persist = true,
  }) async {
    _settings = newSettings;
    _motorState = _motorState.copyWith(
      leftNeutralUs: newSettings.leftNeutralUs,
      rightNeutralUs: newSettings.rightNeutralUs,
      leftInverted: newSettings.leftInverted,
      rightInverted: newSettings.rightInverted,
    );
    notifyListeners();
    if (syncCommand == null || syncCommand.isEmpty) {
      return const CommandResult(ok: true);
    }
    if (!isConnected) {
      return const CommandResult(ok: false, error: 'Não conectado.');
    }
    final reply = await _dispatchSimulatedCommand(syncCommand);
    return CommandResult(
      ok: !reply.startsWith('ERR:'),
      response: reply,
      error: reply.startsWith('ERR:') ? reply : null,
    );
  }

  @override
  Future<void> resetAllSettings() async {
    _settings = const McQueenSettings();
    _speedPercent = _settings.defaultSpeedPercent;
    _expression = _settings.baseExpression;
    _motorState = const MotorState();
    notifyListeners();
    if (isConnected) {
      await sendCommand(BleConstants.cmdCalReset);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────
  void _recordLog(String msg,
      {required bool isOutgoing, bool isSuccess = true}) {
    _commandLogs.insert(
      0,
      CommandLogEntry(
        timestamp: DateTime.now(),
        message: msg,
        isOutgoing: isOutgoing,
        isSuccess: isSuccess,
      ),
    );
    if (_commandLogs.length > 80) {
      _commandLogs.removeLast();
    }
    notifyListeners();
  }

  void _setState(RobotConnectionState s) {
    _state = s;
    notifyListeners();
  }

  void _setStatus(String s) {
    _lastStatus = s;
    notifyListeners();
  }

  bool _isDisposed = false;

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _interruptRunningSoundSequence();
    _buzzerIndicatorTimer?.cancel();
    _connectionEvents.close();
    super.dispose();
  }
}
