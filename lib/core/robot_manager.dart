// lib/core/robot_manager.dart
import 'dart:async';

import '../models/ble_diagnostics.dart';
import '../models/mcqueen_settings.dart';
import '../models/motor_state.dart';
import '../models/robot_expression.dart';
import '../models/sound_item.dart';
import '../models/turn_signal_state.dart';
import 'demo_robot_service.dart';
import 'real_ble_service.dart';
import 'robot_service.dart';

/// Gerenciador que permite alternar entre Modo Real (BLE com ESP32-C3)
/// e Modo Demo (simulado para testes de UI).
class RobotManager extends RobotService {
  final DemoRobotService _demoService = DemoRobotService();
  final RealBleService _realService = RealBleService();

  final StreamController<ConnectionEvent> _connectionEvents =
      StreamController<ConnectionEvent>.broadcast();
  StreamSubscription<ConnectionEvent>? _demoSub;
  StreamSubscription<ConnectionEvent>? _realSub;

  bool _useDemo;

  RobotManager({bool initialDemo = false}) : _useDemo = initialDemo {
    _demoService.addListener(_onActiveServiceChanged);
    _realService.addListener(_onActiveServiceChanged);

    _demoSub = _demoService.connectionEvents.listen((e) {
      if (_useDemo) _connectionEvents.add(e);
    });
    _realSub = _realService.connectionEvents.listen((e) {
      if (!_useDemo) _connectionEvents.add(e);
    });
  }

  RobotService get _active => _useDemo ? _demoService : _realService;

  void _onActiveServiceChanged() {
    notifyListeners();
  }

  /// Alterna entre modo Demo e modo Real (BLE)
  Future<void> toggleMode() async {
    await setDemoMode(!_useDemo);
  }

  Future<void> setDemoMode(bool demo) async {
    if (_useDemo == demo) return;

    if (_active.isConnected) {
      await _active.disconnect();
    }

    _useDemo = demo;
    notifyListeners();
  }

  // ── Encaminhamento do contrato RobotService ──────────────────────────────────
  @override RobotConnectionState get connectionState => _active.connectionState;
  @override bool get isConnected => _active.isConnected;
  @override String? get lastStatus => _active.lastStatus;
  @override String? get connectionError => _active.connectionError;
  @override Stream<ConnectionEvent> get connectionEvents => _connectionEvents.stream;
  @override bool get buzinaSent => _active.buzinaSent;
  @override String? get activeSoundLabel => _active.activeSoundLabel;
  @override bool get isSoundSequenceRunning => _active.isSoundSequenceRunning;
  @override bool get isDemo => _active.isDemo;
  @override ControlMode get controlMode => _active.controlMode;
  @override SpeedLevel get currentSpeed => _active.currentSpeed;
  @override int get speedPercent => _active.speedPercent;
  @override bool get batteryAvailable => _active.batteryAvailable;
  @override int get batteryPercent => _active.batteryPercent;
  @override int get rssi => _active.rssi;
  @override List<CommandLogEntry> get commandLogs => _active.commandLogs;
  @override BleDiagnostics get diagnostics => _active.diagnostics;
  @override MotorState get motorState => _active.motorState;
  @override RobotExpression get currentExpression => _active.currentExpression;
  @override TurnSignalState get turnSignal => _active.turnSignal;
  @override String get setaEstado => _active.setaEstado;
  @override McQueenSettings get settings => _active.settings;
  @override int get emergencyStopCount => _active.emergencyStopCount;

  @override
  void setControlMode(ControlMode mode) => _active.setControlMode(mode);

  @override
  Future<void> setSpeed(SpeedLevel speed) => _active.setSpeed(speed);

  @override
  Future<void> setSpeedPercent(int percent) => _active.setSpeedPercent(percent);

  @override
  void clearLogs() => _active.clearLogs();

  @override
  Future<void> connect() => _active.connect();

  @override
  Future<void> disconnect() => _active.disconnect();

  @override
  Future<void> sendCommand(String cmd) => _active.sendCommand(cmd);

  @override
  Future<void> startMovement(String cmd) => _active.startMovement(cmd);

  @override
  Future<void> stopMovement([String? sourceCmd]) => _active.stopMovement(sourceCmd);

  @override
  Future<CommandResult> sendBuzina() => _active.sendBuzina();

  @override
  Future<void> stopBuzzer() => _active.stopBuzzer();

  @override
  Future<void> setTurnSignal(TurnSignalState signal) => _active.setTurnSignal(signal);

  @override
  Future<void> toggleAutoTurnSignals() => _active.toggleAutoTurnSignals();

  @override
  Future<void> joystickControl({required int left, required int right}) =>
      _active.joystickControl(left: left, right: right);

  @override
  Future<void> stopJoystick() => _active.stopJoystick();

  @override
  Future<void> emergencyStop() => _active.emergencyStop();

  @override
  Future<void> startMotorTest(String side, int speed) =>
      _active.startMotorTest(side, speed);

  @override
  Future<void> setExpression(RobotExpression expr) => _active.setExpression(expr);

  @override
  Future<void> setSpeedProfile(SpeedProfile profile) =>
      _active.setSpeedProfile(profile);

  @override
  Future<CommandResult> triggerSound(String soundCommand) =>
      _active.triggerSound(soundCommand);

  @override
  Future<CommandResult> playSoundItem(SoundItem item) =>
      _active.playSoundItem(item);

  @override
  Future<CommandResult> playTimedBeepSequence({
    required List<BeepStep> steps,
    required String label,
  }) =>
      _active.playTimedBeepSequence(steps: steps, label: label);

  @override
  Future<void> cancelSoundSequence() => _active.cancelSoundSequence();

  @override
  Future<CommandResult> testCommunication() => _active.testCommunication();

  @override
  Future<CommandResult> requestDiagnostics() => _active.requestDiagnostics();

  @override
  Future<CommandResult> refreshStatus() => _active.refreshStatus();

  @override
  Future<CommandResult> updateSettings(
    McQueenSettings newSettings, {
    String? syncCommand,
    bool persist = true,
  }) =>
      _active.updateSettings(
        newSettings,
        syncCommand: syncCommand,
        persist: persist,
      );

  @override
  Future<void> resetAllSettings() => _active.resetAllSettings();

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
    _demoSub?.cancel();
    _realSub?.cancel();
    _connectionEvents.close();
    _demoService.removeListener(_onActiveServiceChanged);
    _realService.removeListener(_onActiveServiceChanged);
    _demoService.dispose();
    _realService.dispose();
    super.dispose();
  }
}
