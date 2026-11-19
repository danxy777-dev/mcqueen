// test/robot_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mcqueen/core/ble_constants.dart';
import 'package:mcqueen/core/demo_robot_service.dart';
import 'package:mcqueen/core/robot_manager.dart';
import 'package:mcqueen/core/robot_service.dart';
import 'package:mcqueen/models/sound_item.dart';
import 'package:mcqueen/models/turn_signal_state.dart';
import 'package:mcqueen/ui/widgets/analog_joystick.dart';

void main() {
  group('AnalogJoystick Differential Math', () {
    test('Deadzone central retorna (0, 0)', () {
      expect(
        AnalogJoystick.computeMotorSpeeds(
          const Offset(0.0, 0.0),
          speedLimitPercent: 100,
        ),
        (0, 0),
      );
      expect(
        AnalogJoystick.computeMotorSpeeds(
          const Offset(0.05, -0.05),
          speedLimitPercent: 100,
        ),
        (0, 0),
      );
    });

    test('Direções cardeais em 100% produzem vetores diferenciais exatos', () {
      // Cima = Frente
      expect(
        AnalogJoystick.computeMotorSpeeds(
          const Offset(0, 1.0),
          speedLimitPercent: 100,
        ),
        (100, 100),
      );
      // Baixo = Ré
      expect(
        AnalogJoystick.computeMotorSpeeds(
          const Offset(0, -1.0),
          speedLimitPercent: 100,
        ),
        (-100, -100),
      );
      // Esquerda = gira à esquerda
      expect(
        AnalogJoystick.computeMotorSpeeds(
          const Offset(-1.0, 0),
          speedLimitPercent: 100,
        ),
        (-100, 100),
      );
      // Direita = gira à direita
      expect(
        AnalogJoystick.computeMotorSpeeds(
          const Offset(1.0, 0),
          speedLimitPercent: 100,
        ),
        (100, -100),
      );
    });

    test('Diagonais combinam avanço/ré com curva proporcional', () {
      // Diagonal frente-direita
      final (frL, frR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(0.7071, 0.7071),
        speedLimitPercent: 100,
      );
      expect(frL, 100);
      expect(frR, 0);

      // Diagonal leve frente-direita
      final (sfrL, sfrR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(0.25, 0.968),
        speedLimitPercent: 100,
      );
      expect(sfrL, 100);
      expect(sfrR, greaterThan(40));
      expect(sfrR, lessThan(sfrL));

      // Diagonal frente-esquerda
      final (flL, flR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(-0.7071, 0.7071),
        speedLimitPercent: 100,
      );
      expect(flL, 0);
      expect(flR, 100);

      // Diagonal ré-direita
      final (rrL, rrR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(0.7071, -0.7071),
        speedLimitPercent: 100,
      );
      expect(rrL, 0);
      expect(rrR, -100);

      // Diagonal ré-esquerda
      final (rlL, rlR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(-0.7071, -0.7071),
        speedLimitPercent: 100,
      );
      expect(rlL, -100);
      expect(rlR, 0);
    });

    test('Intensidade acompanha inclinação e respeita limite do perfil de velocidade', () {
      final (halfL, halfR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(0, 0.55),
        speedLimitPercent: 100,
      );
      expect(halfL, 50);
      expect(halfR, 50);

      final (ecoL, ecoR) = AnalogJoystick.computeMotorSpeeds(
        const Offset(0, 1.0),
        speedLimitPercent: SpeedLevel.eco.percent, // 30%
      );
      expect(ecoL, 30);
      expect(ecoR, 30);
    });
  });

  group('BleConstants Protocol Helpers', () {
    test('DIFF e reconhecimento de movimento/parada', () {
      expect(BleConstants.diff(0, 0), 'PARAR');
      expect(BleConstants.diff(75, 40), 'DIFF:75:40');
      expect(BleConstants.diff(150, -150), 'DIFF:100:-100');
      expect(BleConstants.isMovementCommand('DIFF:50:50'), true);
      expect(BleConstants.isMovementCommand('MOTOR:ESQ:15'), true);
      expect(BleConstants.isMovementCommand('FRENTE:60'), true);
      expect(BleConstants.isStopCommand('PARAR'), true);
      expect(BleConstants.isStopCommand('STOP'), true);
    });
  });

  group('DemoRobotService Unit Tests', () {
    late DemoRobotService service;

    setUp(() {
      service = DemoRobotService();
    });

    tearDown(() {
      service.dispose();
    });

    test('Estado inicial correto', () {
      expect(service.connectionState, RobotConnectionState.disconnected);
      expect(service.isConnected, false);
      expect(service.isDemo, true);
      expect(service.currentSpeed, SpeedLevel.normal);
      expect(service.speedPercent, 60);
      expect(service.controlMode, ControlMode.holdToMove);
      expect(service.buzinaSent, false);
      expect(service.batteryPercent, 94);
      expect(service.commandLogs, isEmpty);
    });

    test('Fluxo de conexão, diagnóstico PING/DIAG/STATUS e desconexão', () async {
      final states = <RobotConnectionState>[];
      service.addListener(() => states.add(service.connectionState));

      await service.connect();

      expect(service.isConnected, true);
      expect(service.connectionState, RobotConnectionState.connected);
      expect(service.lastStatus, 'OK:CONECTADO');
      expect(states, contains(RobotConnectionState.scanning));
      expect(states, contains(RobotConnectionState.connecting));
      expect(states, contains(RobotConnectionState.connected));

      final ping = await service.testCommunication();
      expect(ping.ok, true);
      expect(ping.response, 'PONG');

      final diag = await service.requestDiagnostics();
      expect(diag.ok, true);
      expect(service.diagnostics.diagAdvertising, true);
      expect(service.diagnostics.diagServosEnabled, true);

      final st = await service.refreshStatus();
      expect(st.ok, true);
      expect(service.diagnostics.lastStatusSyncAt, isNotNull);

      await service.disconnect();
      expect(service.isConnected, false);
      expect(service.connectionState, RobotConnectionState.disconnected);
    });

    test('Joystick envia DIFF:L:R e stopJoystick envia PARAR', () async {
      await service.connect();

      await service.joystickControl(left: 60, right: 30);
      expect(service.lastStatus, 'OK:DIFF:60:30');
      expect(service.motorState.leftSpeed, 60);
      expect(service.motorState.rightSpeed, 30);

      await service.stopJoystick();
      expect(service.lastStatus, 'OK:PARAR');
      expect(service.motorState.leftSpeed, 0);
      expect(service.motorState.rightSpeed, 0);
    });

    test('Velocidade contínua 0-100 é aplicada e limitada', () async {
      await service.connect();

      await service.setSpeedPercent(30);
      expect(service.speedPercent, 30);
      expect(service.currentSpeed, SpeedLevel.eco);
      expect(service.lastStatus, 'OK:VEL:30');

      await service.setSpeedPercent(150);
      expect(service.speedPercent, 100);
      expect(service.currentSpeed, SpeedLevel.turbo);

      await service.setSpeedPercent(-10);
      expect(service.speedPercent, 0);
    });

    test('Segurança: Hold-to-Move envia PARAR ao chamar stopMovement', () async {
      await service.connect();
      expect(service.controlMode, ControlMode.holdToMove);

      await service.startMovement(BleConstants.cmdFrente);
      expect(service.lastStatus, 'OK:FRENTE');

      await service.stopMovement();
      expect(service.lastStatus, 'OK:PARAR');
    });

    test('Modo contínuo: stopMovement não envia PARAR automaticamente', () async {
      await service.connect();
      service.setControlMode(ControlMode.continuous);

      await service.startMovement(BleConstants.cmdFrente);
      expect(service.lastStatus, 'OK:FRENTE');

      await service.stopMovement();
      expect(service.lastStatus, 'OK:FRENTE');
    });

    test('Buzina confirma via resposta do ESP32 e respeita mute', () async {
      await service.connect();

      final res = await service.sendBuzina();
      expect(res.ok, true);
      expect(res.response, 'OK:BUZINA');
      expect(service.buzinaSent, true);
      expect(service.lastStatus, 'OK:BUZINA');

      await service.stopBuzzer();
      expect(service.buzinaSent, false);
      expect(service.lastStatus, 'OK:BUZINA:DESLIGAR');

      // Silenciar sons deve impedir disparo de som sem falso positivo
      await service.updateSettings(
        service.settings.copyWith(soundsEnabled: false),
        syncCommand: BleConstants.cmdSomMuteOn,
      );
      final mutedRes = await service.sendBuzina();
      expect(mutedRes.ok, false);
      expect(service.buzinaSent, false);
    });

    test('Sequência temporizada de bipes executa pulsos TONE reais e preserva label', () async {
      await service.connect();

      final res = await service.playTimedBeepSequence(
        steps: const [BeepStep(50, 40), BeepStep(50, 0)],
        label: 'SEQ:TESTE',
      );
      expect(res.ok, true);
      expect(service.lastStatus, 'OK:BUZZER:TONE');
      expect(service.buzinaSent, false);
    });

    test('Cancelamento imediato de sequência sonora e troca de som', () async {
      await service.connect();

      final seqFuture = service.playTimedBeepSequence(
        steps: const [
          BeepStep(200, 200),
          BeepStep(200, 200),
          BeepStep(200, 0),
        ],
        label: 'SEQ:LONGA',
      );
      await Future<void>.delayed(const Duration(milliseconds: 90));
      expect(service.isSoundSequenceRunning, true);
      expect(service.buzinaSent, true);
      expect(service.activeSoundLabel, 'SEQ:LONGA');

      await service.cancelSoundSequence();
      final res = await seqFuture;
      expect(res.ok, false);
      expect(service.isSoundSequenceRunning, false);
      expect(service.buzinaSent, false);
      expect(service.lastStatus, 'OK:BUZINA:DESLIGAR');
    });

    test('Teste individual de motor e parada de emergência', () async {
      await service.connect();
      final initialCount = service.emergencyStopCount;

      await service.startMotorTest('ESQ', 15);
      expect(service.motorState.leftSpeed, 15);
      expect(service.motorState.rightSpeed, 0);
      expect(service.lastStatus, 'OK:MOTOR:ESQ');

      await service.emergencyStop();
      expect(service.emergencyStopCount, initialCount + 1);
      expect(service.motorState.leftSpeed, 0);
      expect(service.motorState.rightSpeed, 0);
      expect(service.lastStatus, 'OK:PARAR');
    });

    test('Sensibilidade não ultrapassa o limite de velocidade selecionado', () async {
      await service.connect();
      await service.setSpeed(SpeedLevel.eco); // 30%
      await service.updateSettings(service.settings.copyWith(sensitivity: 1.5));

      await service.joystickControl(left: 30, right: 30);
      expect(service.motorState.leftSpeed, 30);
      expect(service.motorState.rightSpeed, 30);
    });

    test('Controle de setas direcionais (GPIO 7 e 9) emite comandos corretos', () async {
      await service.connect();

      await service.setTurnSignal(TurnSignalState.left);
      expect(service.turnSignal, TurnSignalState.left);
      expect(service.lastStatus, 'OK:SETA:ESQUERDA');

      await service.setTurnSignal(TurnSignalState.right);
      expect(service.turnSignal, TurnSignalState.right);
      expect(service.lastStatus, 'OK:SETA:DIREITA');

      await service.setTurnSignal(TurnSignalState.alert);
      expect(service.turnSignal, TurnSignalState.alert);
      expect(service.lastStatus, 'OK:SETA:ALERTA');

      await service.setTurnSignal(TurnSignalState.auto);
      expect(service.turnSignal, TurnSignalState.auto);
      expect(service.lastStatus, 'OK:SETA:AUTO:ON');

      await service.setTurnSignal(TurnSignalState.off);
      expect(service.turnSignal, TurnSignalState.off);
      expect(service.lastStatus, 'OK:SETA:DESLIGAR');
    });

    test('Troca de velocidade durante movimento contínuo aplica novo limite sem parar', () async {
      await service.connect();
      service.setControlMode(ControlMode.continuous);

      await service.setSpeed(SpeedLevel.eco);
      await service.startMovement(BleConstants.cmdFrente);
      expect(service.motorState.leftSpeed, 30);
      expect(service.motorState.rightSpeed, 30);

      await service.setSpeed(SpeedLevel.normal);
      expect(service.speedPercent, 60);
      expect(service.motorState.leftSpeed, 60);
      expect(service.motorState.rightSpeed, 60);

      await service.setSpeed(SpeedLevel.sport);
      expect(service.speedPercent, 85);
      expect(service.motorState.leftSpeed, 85);
      expect(service.motorState.rightSpeed, 85);

      await service.setSpeed(SpeedLevel.turbo);
      expect(service.speedPercent, 100);
      expect(service.motorState.leftSpeed, 100);
      expect(service.motorState.rightSpeed, 100);
      expect(service.commandLogs.any((l) => l.message == 'TX → PARAR'), isFalse);
    });

    test('clearLogs limpa todas as entradas', () async {
      await service.connect();
      await service.sendCommand(BleConstants.cmdBipe);
      expect(service.commandLogs.isNotEmpty, true);

      service.clearLogs();
      expect(service.commandLogs, isEmpty);
    });
  });

  group('RobotManager Tests', () {
    test('Alternância dinâmica entre Demo e Real', () async {
      final manager = RobotManager(initialDemo: true);
      expect(manager.isDemo, true);

      await manager.setDemoMode(false);
      expect(manager.isDemo, false);

      await manager.toggleMode();
      expect(manager.isDemo, true);

      manager.dispose();
    });
  });
}
