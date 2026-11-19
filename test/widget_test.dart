// test/widget_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mcqueen/core/demo_robot_service.dart';
import 'package:mcqueen/core/real_ble_service.dart';
import 'package:mcqueen/core/robot_service.dart';
import 'package:mcqueen/models/turn_signal_state.dart';
import 'package:mcqueen/theme/app_theme.dart';
import 'package:mcqueen/ui/control_page.dart';
import 'package:mcqueen/ui/widgets/analog_joystick.dart';
import 'package:mcqueen/ui/widgets/connection_dialogs.dart';

void main() {
  void setViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Widget buildApp(RobotService robot, {bool disableAnimations = false}) {
    return ChangeNotifierProvider<RobotService>.value(
      value: robot,
      child: MaterialApp(
        theme: McQueenTheme.darkTheme,
        builder: (context, child) {
          if (!disableAnimations) return child!;
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          );
        },
        home: const ControlPage(),
      ),
    );
  }

  testWidgets('Tela inicial vertical é minimalista e exibe apenas o essencial',
      (WidgetTester tester) async {
    setViewport(tester, const Size(400, 800));
    final robot = RealBleService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));

    // Elementos obrigatórios na tela principal
    expect(find.text('McQueen'), findsOneWidget);
    expect(find.text('Conectar'), findsOneWidget);
    expect(find.byType(AnalogJoystick), findsOneWidget);
    expect(find.text('ECO'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(find.text('Sport'), findsOneWidget);
    expect(find.text('Turbo'), findsOneWidget);
    expect(find.text('Buzina'), findsOneWidget);
    expect(find.text('Parar'), findsOneWidget);
    expect(find.byTooltip('Configurações'), findsOneWidget);
    expect(find.byTooltip('McQueen AI'), findsOneWidget);

    // Não deve poluir a tela inicial com detalhes técnicos ou abas
    expect(find.text('--dBm'), findsNothing);
    expect(find.text('Personalidade'), findsNothing);
    expect(find.text('Calibração'), findsNothing);
    expect(find.text('Logs BLE (TX / RX)'), findsNothing);
  });

  testWidgets('Tela inicial vertical adapta-se a telas compactas e pequenas sem overflow',
      (WidgetTester tester) async {
    setViewport(tester, const Size(320, 568));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await tester.pump();

    expect(find.byType(AnalogJoystick), findsOneWidget);
    expect(find.text('Buzina'), findsOneWidget);
    expect(find.text('Parar'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> connectDemo(WidgetTester tester, DemoRobotService robot) async {
    final future = robot.connect();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 700));
    await future;
    await tester.pump();
  }

  testWidgets('Tela horizontal adapta-se a telas pequenas sem cortes ou overflow',
      (WidgetTester tester) async {
    setViewport(tester, const Size(568, 320));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);

    expect(find.text('FRENTE'), findsOneWidget);
    expect(find.text('RÉ'), findsOneWidget);
    expect(find.text('ESQUERDA'), findsOneWidget);
    expect(find.text('DIREITA'), findsOneWidget);
    expect(find.text('EMERGÊNCIA'), findsOneWidget);
    expect(find.text('Esq'), findsOneWidget);
    expect(find.text('Alerta'), findsOneWidget);
    expect(find.text('Desligar'), findsOneWidget);
    expect(find.text('Dir'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Mudança entre orientação vertical e horizontal preserva conexão BLE e interrompe movimento',
      (WidgetTester tester) async {
    setViewport(tester, const Size(400, 800));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);
    final speedFuture = robot.setSpeed(SpeedLevel.sport);
    await tester.pump(const Duration(milliseconds: 100));
    await speedFuture;
    await tester.pump();

    // Arrasta joystick na vertical
    final center = tester.getCenter(find.byType(AnalogJoystick));
    final drag = await tester.startGesture(center);
    await drag.moveBy(const Offset(0, -70));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, greaterThan(0));

    // Gira para horizontal enquanto segura o controle
    tester.view.physicalSize = const Size(800, 420);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await drag.up();

    // Conexão e velocidade preservadas; movimento interrompido com segurança
    expect(robot.isConnected, isTrue);
    expect(robot.currentSpeed, SpeedLevel.sport);
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.motorState.rightSpeed, 0);
    expect(find.text('FRENTE'), findsOneWidget);
    expect(find.byType(AnalogJoystick), findsNothing);

    // Gira de volta para vertical mantendo conexão
    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(robot.isConnected, isTrue);
    expect(find.byType(AnalogJoystick), findsOneWidget);
  });

  testWidgets(
      'Joystick analógico dirige em todas as direções, retorna ao centro e envia PARAR ao soltar/cancelar',
      (WidgetTester tester) async {
    setViewport(tester, const Size(400, 800));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);

    final joystickFinder = find.byType(AnalogJoystick);
    final center = tester.getCenter(joystickFinder);

    // 1. Pressiona no centro e arrasta para cima (FRENTE)
    final gesture = await tester.startGesture(center);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(const Duration(milliseconds: 80));

    expect(robot.motorState.leftSpeed, greaterThan(0));
    expect(robot.motorState.rightSpeed, greaterThan(0));
    expect(robot.motorState.direction, 'FRENTE');

    // 2. Arrasta diagonalmente para cima-direita
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, greaterThan(robot.motorState.rightSpeed));

    // 3. Arrasta para baixo (RÉ)
    await gesture.moveTo(center + const Offset(0, 80));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, lessThan(0));
    expect(robot.motorState.rightSpeed, lessThan(0));

    // 4. Solta o dedo -> PARAR imediato e retorno ao centro
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.motorState.rightSpeed, 0);
    expect(robot.lastStatus, 'OK:PARAR');
    await tester.pumpAndSettle();

    // 5. Cancelamento de toque -> PARAR imediato
    final cancelGesture = await tester.startGesture(center);
    await cancelGesture.moveBy(const Offset(-70, 0));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, lessThan(0));
    expect(robot.motorState.rightSpeed, greaterThan(0));

    await cancelGesture.cancel();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.motorState.rightSpeed, 0);
    expect(robot.lastStatus, 'OK:PARAR');
    await tester.pumpAndSettle();

    // 6. Buzina e Parada de emergência (inclusive interrompendo arraste ativo)
    await tester.tap(find.text('Buzina'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.lastStatus, 'OK:BUZINA');
    expect(robot.buzinaSent, isTrue);

    final activeDrag = await tester.startGesture(center);
    await activeDrag.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, greaterThan(0));

    await tester.tap(find.text('Parar'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.lastStatus, 'OK:PARAR');
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.motorState.rightSpeed, 0);
    await activeDrag.up();
    // Aguarda timer do indicador de buzina finalizar
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets(
      'Modo horizontal (landscape) mantém gamepad de 4 botões + emergência',
      (WidgetTester tester) async {
    setViewport(tester, const Size(800, 420));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);

    expect(find.text('FRENTE'), findsOneWidget);
    expect(find.text('RÉ'), findsOneWidget);
    expect(find.text('ESQUERDA'), findsOneWidget);
    expect(find.text('DIREITA'), findsOneWidget);
    expect(find.text('EMERGÊNCIA'), findsOneWidget);
    expect(find.byType(AnalogJoystick), findsNothing);

    // Pressionar e soltar FRENTE no modo seguro envia FRENTE e depois PARAR
    final g = await tester.startGesture(tester.getCenter(find.text('FRENTE')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.lastStatus, 'OK:FRENTE');

    await g.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.lastStatus, 'OK:PARAR');
  });

  testWidgets(
      'Troca de ECO, NORMAL, SPORT e TURBO durante movimento com joystick aplica velocidade sem parar',
      (WidgetTester tester) async {
    setViewport(tester, const Size(400, 800));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);

    // Começa em ECO e arrasta joystick para frente+direita (diagonal)
    await tester.tap(find.text('ECO'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.speedPercent, 30);

    final center = tester.getCenter(find.byType(AnalogJoystick));
    final joyDrag = await tester.startGesture(center);
    await joyDrag.moveTo(center + const Offset(45, -80));
    await tester.pump(const Duration(milliseconds: 80));

    final ecoLeft = robot.motorState.leftSpeed;
    final ecoRight = robot.motorState.rightSpeed;
    expect(ecoLeft, greaterThan(0));
    expect(ecoLeft, greaterThan(ecoRight));
    expect(ecoLeft, lessThanOrEqualTo(30));

    robot.clearLogs();

    // Seleciona Normal sem soltar o joystick -> acelera imediatamente sem PARAR
    await tester.tap(find.text('Normal'));
    await tester.pump(const Duration(milliseconds: 140));
    expect(robot.speedPercent, 60);
    expect(robot.motorState.leftSpeed, greaterThan(ecoLeft));
    expect(robot.motorState.leftSpeed, lessThanOrEqualTo(60));
    expect(robot.motorState.leftSpeed, greaterThan(robot.motorState.rightSpeed));
    expect(robot.commandLogs.any((e) => e.message == 'TX → PARAR'), isFalse);

    final normalLeft = robot.motorState.leftSpeed;

    // Seleciona Sport sem soltar o joystick -> aplica 85% sem PARAR
    await tester.tap(find.text('Sport'));
    await tester.pump(const Duration(milliseconds: 140));
    expect(robot.speedPercent, 85);
    expect(robot.motorState.leftSpeed, greaterThan(normalLeft));
    expect(robot.motorState.leftSpeed, lessThanOrEqualTo(85));
    expect(robot.commandLogs.any((e) => e.message == 'TX → PARAR'), isFalse);

    final sportLeft = robot.motorState.leftSpeed;

    // Seleciona Turbo sem soltar o joystick -> aplica 100% sem PARAR
    await tester.tap(find.text('Turbo'));
    await tester.pump(const Duration(milliseconds: 140));
    expect(robot.speedPercent, 100);
    expect(robot.motorState.leftSpeed, greaterThan(sportLeft));
    expect(robot.commandLogs.any((e) => e.message == 'TX → PARAR'), isFalse);

    // Solta joystick -> envia PARAR imediato
    await joyDrag.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.motorState.rightSpeed, 0);
    expect(robot.lastStatus, 'OK:PARAR');
  });

  testWidgets(
      'Modo horizontal aplica ECO, NORMAL, SPORT e TURBO enquanto direcional está pressionado',
      (WidgetTester tester) async {
    setViewport(tester, const Size(800, 420));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);

    await tester.tap(find.text('ECO'));
    await tester.pump(const Duration(milliseconds: 80));

    final driveHold = await tester.startGesture(tester.getCenter(find.text('FRENTE')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 30);

    robot.clearLogs();
    await tester.tap(find.text('Normal'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 60);
    expect(robot.commandLogs.any((e) => e.message == 'TX → PARAR'), isFalse);

    await tester.tap(find.text('Sport'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 85);
    expect(robot.commandLogs.any((e) => e.message == 'TX → PARAR'), isFalse);

    await driveHold.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.lastStatus, 'OK:PARAR');
  });

  testWidgets(
      'Navegação pelas 6 áreas de Configurações preserva conexão BLE e aciona comandos reais',
      (WidgetTester tester) async {
    setViewport(tester, const Size(400, 800));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot, disableAnimations: true));
    await connectDemo(tester, robot);

    // Abre Configurações pelo ícone discreto
    await tester.tap(find.byTooltip('Configurações'));
    await tester.pumpAndSettle();

    expect(find.text('Configurações'), findsOneWidget);
    expect(find.text('Conexão'), findsOneWidget);
    expect(find.text('Motores'), findsOneWidget);
    expect(find.text('Sons'), findsOneWidget);
    expect(find.text('Display OLED'), findsOneWidget);
    expect(find.text('Indicadores'), findsOneWidget);
    expect(find.text('Diagnóstico'), findsOneWidget);

    // 1. Conexão
    await tester.tap(find.text('Conexão'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Testar PING'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('PING → PONG confirmado'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 2. Motores (inclui teste individual hold-to-test)
    await tester.tap(find.text('Motores'));
    await tester.pumpAndSettle();
    expect(find.text('Velocidade & Modo de Condução'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Calibração Individual dos Servos'),
      300,
    );
    expect(find.text('Calibração Individual dos Servos'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('ESQ +15%'), 300);
    final motorHold =
        await tester.startGesture(tester.getCenter(find.text('ESQ +15%')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 15);
    await motorHold.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 3. Sons
    await tester.tap(find.text('Sons'));
    await tester.pumpAndSettle();
    expect(find.text('Buzzer Ativo (2 terminais · GPIO 2)'), findsOneWidget);
    await tester.tap(find.text('Testar Buzina'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Confirmado pelo ESP32: OK:BUZINA'),
        findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 4. Display OLED
    await tester.tap(find.text('Display OLED'));
    await tester.pumpAndSettle();
    expect(find.text('Prévia OLED 128×64'), findsOneWidget);
    await tester.tap(find.text('Feliz'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(robot.lastStatus, 'OK:EXPR:FELIZ');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 5. Indicadores
    await tester.tap(find.text('Indicadores'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Seta Esquerda'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(robot.lastStatus, 'OK:SETA:ESQUERDA');
    await tester.tap(find.text('Desligar'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(robot.lastStatus, 'OK:SETA:DESLIGAR');
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 6. Diagnóstico
    await tester.tap(find.text('Diagnóstico'));
    await tester.pumpAndSettle();
    expect(find.text('Verificação do Enlace & Firmware'), findsOneWidget);
    await tester.tap(find.text('Executar Diagnóstico'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.textContaining('DIAG: OK · STATUS: OK'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Logs BLE (TX / RX)'), 300);
    expect(find.text('Logs BLE (TX / RX)'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Volta à tela inicial mantendo conexão BLE intacta
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(robot.isConnected, isTrue);
    expect(find.byType(AnalogJoystick), findsOneWidget);
  });

  testWidgets(
      'Configurações, Sons e Indicadores adaptam-se a celulares pequenos (320x568) sem overflow',
      (WidgetTester tester) async {
    setViewport(tester, const Size(320, 568));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot, disableAnimations: true));
    await connectDemo(tester, robot);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Configurações'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Conexão'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Testar PING'), 200);
    expect(find.text('Testar PING'), findsOneWidget);
    expect(find.text('Consultar DIAG'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Sons'), 150);
    await tester.tap(find.text('Sons'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Testar Buzina'), 150);
    expect(find.text('Testar Buzina'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Confirmação (Duplo Bipe)'), 200);
    await tester.ensureVisible(find.text('Confirmação (Duplo Bipe)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmação (Duplo Bipe)'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(robot.commandLogs.any((e) => e.message.contains('TONE:2000:90')), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.text('Indicadores'), 150);
    await tester.tap(find.text('Indicadores'));
    await tester.pumpAndSettle();
    expect(find.text('Pisca-Alerta'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ConnectionDialogs exibe pop-up de sucesso com texto exato',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: McQueenTheme.darkTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => ConnectionDialogs.showSuccess(context),
              child: const Text('Abrir'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();

    expect(find.text('Conexão estabelecida!'), findsOneWidget);
    expect(
      find.text(
        'O aplicativo está conectado ao ESP32 do McQueen via Bluetooth BLE. O serviço e a característica de comunicação foram identificados com sucesso. O robô está pronto para receber comandos.',
      ),
      findsOneWidget,
    );
    expect(find.text('Fechar'), findsOneWidget);

    await tester.tap(find.text('Fechar'));
    await tester.pumpAndSettle();
    expect(find.text('Conexão estabelecida!'), findsNothing);
  });

  testWidgets(
      'ConnectionDialogs exibe pop-up de falha com causa e tentar novamente',
      (WidgetTester tester) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: McQueenTheme.darkTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => ConnectionDialogs.showFailure(
                context,
                specificCause: 'Bluetooth desativado no celular.',
                onRetry: () => retried = true,
              ),
              child: const Text('Abrir Falha'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Abrir Falha'));
    await tester.pumpAndSettle();

    expect(find.text('Não foi possível conectar'), findsOneWidget);
    expect(find.text('Bluetooth desativado no celular.'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);

    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(retried, isTrue);
  });

  testWidgets(
      'Tela horizontal controla setas (Esq, Dir, Alerta, Desligar), alternância rápida e movimentação simultânea',
      (WidgetTester tester) async {
    setViewport(tester, const Size(800, 420));
    final robot = DemoRobotService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(buildApp(robot));
    await connectDemo(tester, robot);

    // 1. Seta esquerda -> pisca e sincroniza estado real
    await tester.tap(find.byTooltip('Seta Esquerda'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.turnSignal, TurnSignalState.left);
    expect(robot.lastStatus, 'OK:SETA:ESQUERDA');

    // 2. Seta direita
    await tester.tap(find.byTooltip('Seta Direita'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.turnSignal, TurnSignalState.right);
    expect(robot.lastStatus, 'OK:SETA:DIREITA');

    // 3. Pisca-alerta simultâneo
    await tester.tap(find.byTooltip('Pisca-Alerta'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.turnSignal, TurnSignalState.alert);
    expect(robot.lastStatus, 'OK:SETA:ALERTA');

    // 4. Alternância rápida + movimento simultâneo sem interromper FRENTE
    final holdForward =
        await tester.startGesture(tester.getCenter(find.text('FRENTE')));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, greaterThan(0));

    robot.clearLogs();
    await tester.tap(find.byTooltip('Seta Esquerda'));
    await tester.tap(find.byTooltip('Seta Direita'));
    await tester.tap(find.byTooltip('Pisca-Alerta'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(robot.turnSignal, TurnSignalState.alert);
    expect(robot.motorState.leftSpeed, greaterThan(0));
    expect(robot.commandLogs.any((l) => l.message == 'TX → PARAR'), isFalse);

    // Solta FRENTE -> envia PARAR e preserva alerta até desligar ou desconectar
    await holdForward.up();
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.turnSignal, TurnSignalState.alert);

    // Desligar indicadores
    await tester.tap(find.byTooltip('Desligar Indicadores'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.turnSignal, TurnSignalState.off);
    expect(robot.lastStatus, 'OK:SETA:DESLIGAR');

    // Reativa e desconecta BLE -> apaga automaticamente
    await tester.tap(find.byTooltip('Seta Direita'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(robot.turnSignal, TurnSignalState.right);
    await robot.disconnect();
    await tester.pump();
    expect(robot.turnSignal, TurnSignalState.off);
  });
}
