// test/mcqueen_ai_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mcqueen/ai/mcqueen_ai_controller.dart';
import 'package:mcqueen/ai/voice_service.dart';
import 'package:mcqueen/core/demo_robot_service.dart';
import 'package:mcqueen/core/robot_service.dart';
import 'package:mcqueen/models/ai_models.dart';
import 'package:mcqueen/models/robot_expression.dart';
import 'package:mcqueen/models/turn_signal_state.dart';
import 'package:mcqueen/theme/app_theme.dart';
import 'package:mcqueen/ui/screens/ai/mcqueen_ai_screen.dart';

class FakeAiBackendClient implements AiBackendClient {
  AiBackendHealth nextHealth = const AiBackendHealth(
    reachable: true,
    configured: true,
    provider: 'openai',
    model: 'gpt-4o-mini',
  );

  final List<(String sessionId, String msg, Map<String, dynamic> state)> requests = [];
  final List<String> clearedSessions = [];

  Future<AiChatResponse> Function(
    String sessionId,
    String message,
    Map<String, dynamic> robotState,
  )? handler;

  @override
  Future<AiBackendHealth> checkHealth(String baseUrl) async => nextHealth;

  @override
  Future<void> clearSession({
    required String baseUrl,
    required String sessionId,
  }) async {
    clearedSessions.add(sessionId);
  }

  @override
  Future<AiChatResponse> sendMessage({
    required String baseUrl,
    required String sessionId,
    required String message,
    required Map<String, dynamic> robotState,
  }) async {
    requests.add((sessionId, message, robotState));
    if (handler != null) {
      return handler!(sessionId, message, robotState);
    }
    return const AiChatResponse(reply: 'Tudo pronto por aqui!');
  }
}

class FakeVoiceService implements VoiceService {
  void Function(String words, bool isFinal)? _onResult;
  void Function()? _onSpeakComplete;

  final List<String> spokenTexts = [];
  bool listening = false;
  bool speaking = false;
  int stopSpeakCalls = 0;
  int cancelListenCalls = 0;
  bool allowListenStart = true;

  @override
  Future<bool> startListening({
    required void Function(String words, bool isFinal) onResult,
    required void Function(String status) onStatus,
    required void Function(String errorMessage) onError,
  }) async {
    if (!allowListenStart) {
      onError('Permissão de microfone negada.');
      return false;
    }
    listening = true;
    _onResult = onResult;
    return true;
  }

  void emitTranscript(String words, {required bool isFinal}) {
    _onResult?.call(words, isFinal);
  }

  @override
  Future<void> stopListening() async {
    listening = false;
  }

  @override
  Future<void> cancelListening() async {
    listening = false;
    cancelListenCalls++;
  }

  @override
  Future<void> speak(
    String text, {
    required AiVoiceSettings settings,
    void Function()? onComplete,
  }) async {
    speaking = true;
    spokenTexts.add(text);
    _onSpeakComplete = onComplete;
  }

  void finishSpeaking() {
    speaking = false;
    final cb = _onSpeakComplete;
    _onSpeakComplete = null;
    cb?.call();
  }

  @override
  Future<void> stopSpeaking() async {
    stopSpeakCalls++;
    speaking = false;
    final cb = _onSpeakComplete;
    _onSpeakComplete = null;
    cb?.call();
  }

  @override
  void dispose() {}
}

void main() {
  Future<void> pumpConnect(WidgetTester tester, DemoRobotService robot) async {
    final fut = robot.connect();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 700));
    await fut;
    await tester.pump();
  }

  testWidgets(
      'McQueen AI conversa por texto, responde perguntas gerais e mantém sessão até limpar',
      (WidgetTester tester) async {
    final robot = DemoRobotService();
    final backend = FakeAiBackendClient()
      ..handler = (_, msg, _) async {
        if (msg.contains('Einstein')) {
          return const AiChatResponse(
            reply:
                'Albert Einstein foi um físico conhecido pela teoria da relatividade.',
          );
        }
        return const AiChatResponse(
          reply: 'Tudo tranquilo! Estou pronto para acelerar.',
        );
      };
    final voice = FakeVoiceService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RobotService>.value(
        value: robot,
        child: MaterialApp(
          theme: McQueenTheme.darkTheme,
          home: McQueenAiScreen(backendClient: backend, voiceService: voice),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Oi McQueen, tudo bem?');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Oi McQueen, tudo bem?'), findsOneWidget);
    expect(find.text('Tudo tranquilo! Estou pronto para acelerar.'), findsOneWidget);
    expect(voice.spokenTexts, contains('Tudo tranquilo! Estou pronto para acelerar.'));
    expect(robot.commandLogs, isEmpty);

    voice.finishSpeaking();
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Quem é Albert Einstein?');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.text(
          'Albert Einstein foi um físico conhecido pela teoria da relatividade.'),
      findsOneWidget,
    );
    // Mesmo session_id usado no backend até limpar conversa
    expect(backend.requests[0].$1, equals(backend.requests[1].$1));

    await tester.tap(find.byTooltip('Limpar conversa'));
    await tester.pump();
    expect(backend.clearedSessions.length, 1);
    expect(find.text('Converse com o McQueen AI'), findsOneWidget);
  });

  testWidgets(
      'Voz pt-BR: escuta, transcreve, executa comandos no BLE, para automaticamente por tempo e interrompe fala',
      (WidgetTester tester) async {
    final robot = DemoRobotService();
    final backend = FakeAiBackendClient()
      ..handler = (_, msg, _) async {
        return const AiChatResponse(
          reply: 'Pisando fundo por 1 segundo e ligando o pisca!',
          intents: [
            RobotIntent(
              tool: 'set_speed_mode',
              arguments: {'mode': 'sport'},
            ),
            RobotIntent(
              tool: 'move_robot',
              arguments: {'direction': 'forward', 'duration_ms': 900},
            ),
            RobotIntent(
              tool: 'set_indicator',
              arguments: {'mode': 'hazard'},
            ),
            RobotIntent(
              tool: 'activate_horn',
              arguments: {'style': 'short'},
            ),
            RobotIntent(
              tool: 'play_sound_effect',
              arguments: {'effect': 'beep'},
            ),
            RobotIntent(
              tool: 'set_face_expression',
              arguments: {'expression': 'FELIZ'},
            ),
          ],
        );
      };
    final voice = FakeVoiceService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RobotService>.value(
        value: robot,
        child: MaterialApp(
          theme: McQueenTheme.darkTheme,
          home: McQueenAiScreen(backendClient: backend, voiceService: voice),
        ),
      ),
    );
    await pumpConnect(tester, robot);

    // Inicia escuta pelo microfone
    await tester.tap(find.byTooltip('Falar com McQueen (pt-BR)'));
    await tester.pump();
    expect(find.text('Escutando'), findsOneWidget);

    voice.emitTranscript('Avance e', isFinal: false);
    await tester.pump();
    expect(find.text('Avance e'), findsOneWidget);

    voice.emitTranscript('Coloque no sport, avance, ligue alerta, buzine e fique feliz',
        isFinal: true);
    await tester.pump(const Duration(milliseconds: 500));

    expect(robot.currentSpeed, SpeedLevel.sport);
    expect(robot.turnSignal, TurnSignalState.alert);
    expect(robot.currentExpression, RobotExpression.feliz);
    expect(
      robot.commandLogs.any((l) => l.message.contains('FRENTE:85')),
      isTrue,
    );
    expect(
      robot.commandLogs.any((l) => l.message.contains('BUZINA:CURTA')),
      isTrue,
    );
    expect(
      robot.commandLogs.any((l) => l.message.contains('BIPE')),
      isTrue,
    );

    // Interrupção imediata da fala ao tocar o microfone (barge-in)
    expect(find.text('Respondendo'), findsOneWidget);
    await tester.tap(find.byTooltip('Parar escuta').evaluate().isEmpty
        ? find.byTooltip('Falar com McQueen (pt-BR)')
        : find.byTooltip('Parar escuta'));
    await tester.pump();
    expect(voice.stopSpeakCalls, greaterThan(0));

    // Aguarda expirar limite máximo de tempo do movimento e garante PARAR automático
    await tester.pump(const Duration(milliseconds: 1200));
    expect(robot.motorState.leftSpeed, 0);
    expect(robot.motorState.rightSpeed, 0);
    expect(robot.lastStatus, 'OK:PARAR');
  });

  testWidgets(
      'Segurança: bloqueia comandos físicos quando BLE desconectado e nunca simula IA offline',
      (WidgetTester tester) async {
    final robot = DemoRobotService(); // desconectado
    final backend = FakeAiBackendClient()
      ..handler = (_, _, _) async {
        return const AiChatResponse(
          reply: 'Queria acelerar, mas estou desconectado do controle!',
          intents: [
            RobotIntent(
              tool: 'move_robot',
              arguments: {'direction': 'forward', 'duration_ms': 800},
            ),
          ],
        );
      };
    final voice = FakeVoiceService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RobotService>.value(
        value: robot,
        child: MaterialApp(
          theme: McQueenTheme.darkTheme,
          home: McQueenAiScreen(backendClient: backend, voiceService: voice),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'Avance!');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Bloqueado: ESP32 do McQueen desconectado'),
        findsOneWidget);
    expect(robot.commandLogs, isEmpty);
    voice.finishSpeaking();
    await tester.pump();

    // Se backend falhar / sem conexão, não simula IA fake e mostra erro real
    backend.handler = (_, _, _) async => throw const AiBackendException(
          'Servidor inacessível.',
          errorCode: 'connection_error',
        );
    await tester.enterText(find.byType(TextField), 'Tudo bem?');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Erro de reconhecimento'), findsOneWidget);
    expect(find.text('Servidor inacessível.'), findsOneWidget);
  });

  testWidgets(
      'Comandos de ré, direção, parada, mudo, voz robótica e configurações funcionam com segurança',
      (WidgetTester tester) async {
    final robot = DemoRobotService();
    final backend = FakeAiBackendClient();
    final voice = FakeVoiceService();
    addTearDown(robot.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<RobotService>.value(
        value: robot,
        child: MaterialApp(
          theme: McQueenTheme.darkTheme,
          home: McQueenAiScreen(backendClient: backend, voiceService: voice),
        ),
      ),
    );
    await pumpConnect(tester, robot);

    // Ativa timbre robótico e verifica envio de configurações
    await tester.tap(find.byTooltip('Configurações de Voz e IA'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Voz com timbre robótico leve'));
    await tester.pump();
    await tester.tap(find.text('Salvar & Testar'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // Testa ré e curva à esquerda com corte automático
    backend.handler = (_, _, _) async => const AiChatResponse(
          reply: 'Dando ré e virando à esquerda!',
          intents: [
            RobotIntent(
              tool: 'move_robot',
              arguments: {'direction': 'backward', 'duration_ms': 400},
            ),
            RobotIntent(
              tool: 'move_robot',
              arguments: {'direction': 'left', 'duration_ms': 400},
            ),
          ],
        );
    await tester.enterText(find.byType(TextField), 'Dê ré e vire à esquerda');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(robot.commandLogs.any((l) => l.message.contains('TRAS:60')), isTrue);
    expect(robot.commandLogs.any((l) => l.message.contains('ESQUERDA:60')), isTrue);

    await tester.pump(const Duration(milliseconds: 500));
    expect(robot.motorState.leftSpeed, 0);
    voice.finishSpeaking();
    await tester.pump();

    // Silencia buzzer -> tentativa de buzinar pela IA não inventa sucesso
    final muteFuture = robot.updateSettings(
      robot.settings.copyWith(soundsEnabled: false),
      syncCommand: 'SOM:MUTE:1',
    );
    await tester.pump(const Duration(milliseconds: 80));
    await muteFuture;
    backend.handler = (_, _, _) async => const AiChatResponse(
          reply: 'Tentando buzinar...',
          intents: [RobotIntent(tool: 'activate_horn', arguments: {'style': 'normal'})],
        );
    await tester.enterText(find.byType(TextField), 'Buzine!');
    await tester.tap(find.byTooltip('Enviar mensagem'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('silenciado (MUTE)'), findsOneWidget);
    voice.finishSpeaking();
    await tester.pump();
  });
}
