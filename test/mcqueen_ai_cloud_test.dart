// test/mcqueen_ai_cloud_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:mcqueen/ai/mcqueen_ai_controller.dart';
import 'package:mcqueen/config/ai_config.dart';
import 'package:mcqueen/core/demo_robot_service.dart';
import 'package:mcqueen/core/robot_service.dart';
import 'package:mcqueen/models/ai_models.dart';
import 'package:mcqueen/theme/app_theme.dart';
import 'package:mcqueen/ui/screens/ai/mcqueen_ai_screen.dart';

import 'mcqueen_ai_test.dart' show FakeAiBackendClient, FakeVoiceService;

void main() {
  group('AiConfig validação de URL HTTPS e segurança', () {
    test('Rejeita URL vazia, HTTP pública insegura e URLs de exemplo', () {
      expect(AiConfig.validateBackendUrl('').isEmpty, isTrue);
      expect(
        AiConfig.validateBackendUrl('http://meu-backend.onrender.com').isValid,
        isFalse,
      );
      expect(
        AiConfig.validateBackendUrl('https://seu-backend.onrender.com').isValid,
        isFalse,
      );
      expect(
        AiConfig.validateBackendUrl('https://mcqueen-ai-prod.onrender.com/').normalizedUrl,
        'https://mcqueen-ai-prod.onrender.com',
      );
      expect(
        AiConfig.validateBackendUrl(
          'http://192.168.1.50:8000',
          allowLocalHttp: false,
        ).isValid,
        isFalse,
      );
      expect(
        AiConfig.validateBackendUrl(
          'http://192.168.1.50:8000',
          allowLocalHttp: true,
        ).isValid,
        isTrue,
      );
    });

    test('URL padrão do app aponta para o deploy HTTPS validado no Render e migra 10.0.2.2', () {
      expect(
        AiConfig.defaultBackendUrl,
        'https://mcqueen-ai-backend-vnm5.onrender.com',
      );

      final migrated = AiVoiceSettings.fromJson({
        'autoSpeak': true,
        'backendUrl': 'http://10.0.2.2:8000',
        'allowLocalDevHttp': false,
      });
      expect(migrated.backendUrl, AiConfig.defaultBackendUrl);

      final keptLocal = AiVoiceSettings.fromJson({
        'autoSpeak': true,
        'backendUrl': 'http://10.0.2.2:8000',
        'allowLocalDevHttp': true,
      });
      expect(keptLocal.backendUrl, 'http://10.0.2.2:8000');
    });
  });

  group('HttpAiBackendClient distingue os estados reais de rede, Render e LLM', () {
    const cloudUrl = 'https://mcqueen-ai-backend-vnm5.onrender.com';

    test('checkHealth classifica notConfigured, online, llmUnavailable, wakingUp, rateLimited e invalidApiKey (incluindo /status 401)', () async {
      final clientOnline = HttpAiBackendClient(
        client: MockClient((req) async {
          expect(req.headers['X-Session-Token'], 'sess-tok-1');
          if (req.url.path == '/status') {
            if (req.headers['X-Client-Token'] != 'app-tok-ok') {
              return http.Response(
                jsonEncode({'error_code': 'unauthorized_client'}),
                401,
              );
            }
            return http.Response(jsonEncode({'ok': true, 'status': 'online'}), 200);
          }
          expect(req.url.toString(), '$cloudUrl/health');
          return http.Response(
            jsonEncode({
              'ok': true,
              'configured': true,
              'provider': 'openai',
              'model': 'gpt-4o-mini',
            }),
            200,
          );
        }),
      );

      final emptyRes = await clientOnline.checkHealthWithOptions('');
      expect(emptyRes.effectiveStatus, AiBackendStatus.notConfigured);

      // Sem X-Client-Token quando servidor exige MCQUEEN_CLIENT_TOKEN -> detecta 401 no /status
      final missingTokenRes = await clientOnline.checkHealthWithOptions(
        cloudUrl,
        sessionToken: 'sess-tok-1',
      );
      expect(missingTokenRes.effectiveStatus, AiBackendStatus.invalidApiKey);

      final onlineRes = await clientOnline.checkHealthWithOptions(
        cloudUrl,
        sessionToken: 'sess-tok-1',
        clientToken: 'app-tok-ok',
      );
      expect(onlineRes.ready, isTrue);
      expect(onlineRes.effectiveStatus, AiBackendStatus.online);
      expect(onlineRes.model, 'gpt-4o-mini');

      final clientNoLlm = HttpAiBackendClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'ok': true, 'configured': false}),
            200,
          ),
        ),
      );
      final noLlmRes = await clientNoLlm.checkHealthWithOptions(cloudUrl);
      expect(noLlmRes.effectiveStatus, AiBackendStatus.llmUnavailable);
      expect(noLlmRes.ready, isFalse);

      final clientWaking = HttpAiBackendClient(
        client: MockClient(
          (_) async => http.Response('<html>Bad Gateway</html>', 502),
        ),
      );
      final wakingRes = await clientWaking.checkHealthWithOptions(cloudUrl);
      expect(wakingRes.effectiveStatus, AiBackendStatus.wakingUp);

      final clientRate = HttpAiBackendClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({'error_code': 'rate_limit_exceeded'}),
            429,
            headers: {'retry-after': '18'},
          ),
        ),
      );
      final rateRes = await clientRate.checkHealthWithOptions(cloudUrl);
      expect(rateRes.effectiveStatus, AiBackendStatus.rateLimited);
      expect(rateRes.retryAfterSeconds, 18);

      final clientAuth = HttpAiBackendClient(
        client: MockClient((_) async => http.Response('{}', 401)),
      );
      final authRes = await clientAuth.checkHealthWithOptions(cloudUrl);
      expect(authRes.effectiveStatus, AiBackendStatus.invalidApiKey);
    });

    test('checkHealth diferencia sem internet no celular vs backend inacessível', () async {
      final clientOffline = HttpAiBackendClient(
        client: MockClient((_) async => throw const SocketException('unreachable')),
        internetProbe: () async => false,
      );
      final offlineRes = await clientOffline.checkHealthWithOptions(cloudUrl);
      expect(offlineRes.effectiveStatus, AiBackendStatus.noInternet);

      final clientServerDown = HttpAiBackendClient(
        client: MockClient((_) async => throw const SocketException('unreachable')),
        internetProbe: () async => true,
      );
      final downRes = await clientServerDown.checkHealthWithOptions(cloudUrl);
      expect(downRes.effectiveStatus, AiBackendStatus.backendUnavailable);
    });

    test('sendMessage trata 401, 403, 404, 429, 500, 503 llm_unreachable e TimeoutException', () async {
      Future<AiBackendException> captureError(
        Future<http.Response> Function(http.Request) fn, {
        Future<bool> Function()? probe,
      }) async {
        final client = HttpAiBackendClient(
          client: MockClient(fn),
          internetProbe: probe,
        );
        try {
          await client.sendMessageWithOptions(
            baseUrl: cloudUrl,
            sessionId: 's-err',
            message: 'Oi',
            robotState: const {'ble_connected': false},
            sessionToken: 'tok-xyz',
          );
          fail('Era esperado AiBackendException');
        } on AiBackendException catch (e) {
          return e;
        }
      }

      final e401 = await captureError(
        (_) async => http.Response(
          jsonEncode({'error_code': 'invalid_api_key', 'detail': 'Chave inválida'}),
          401,
        ),
      );
      expect(e401.status, AiBackendStatus.invalidApiKey);

      final e404 = await captureError((_) async => http.Response('Not found', 404));
      expect(e404.status, AiBackendStatus.backendUnavailable);

      final e429 = await captureError(
        (_) async => http.Response(
          jsonEncode({'error_code': 'llm_rate_limit', 'detail': 'Muitas mensagens'}),
          429,
          headers: {'retry-after': '12'},
        ),
      );
      expect(e429.status, AiBackendStatus.rateLimited);
      expect(e429.retryAfterSeconds, 12);

      final e503Llm = await captureError(
        (_) async => http.Response(
          jsonEncode({'error_code': 'llm_unreachable', 'detail': 'LLM offline'}),
          503,
        ),
      );
      expect(e503Llm.status, AiBackendStatus.llmUnavailable);

      final e500 = await captureError((_) async => http.Response('Internal Error', 500));
      expect(e500.status, AiBackendStatus.backendUnavailable);

      final eTimeout = await captureError(
        (_) async => throw TimeoutException('slow'),
      );
      expect(eTimeout.status, AiBackendStatus.wakingUp);
    });
  });

  group('McQueenAiController e UI distinguem banners, retry e cancelamento', () {
    testWidgets('Exibe banner honesto por estado e botão Tentar recupera conexão', (WidgetTester tester) async {
      final robot = DemoRobotService();
      final backend = FakeAiBackendClient()
        ..nextHealth = const AiBackendHealth(
          reachable: false,
          configured: false,
          status: AiBackendStatus.wakingUp,
          error: 'Servidor acordando no Render...',
        );
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
      await tester.pump();

      expect(find.text('Servidor acordando no Render...'), findsOneWidget);
      expect(find.text('Tentar'), findsOneWidget);

      backend.nextHealth = const AiBackendHealth(
        reachable: true,
        configured: true,
        status: AiBackendStatus.online,
        provider: 'openai',
        model: 'gpt-4o-mini',
      );

      await tester.tap(find.text('Tentar'));
      await tester.pump();

      expect(find.text('Servidor acordando no Render...'), findsNothing);
    });

    test('emergencyStop cancela resposta em andamento sem executar comandos tardios', () async {
      final robot = DemoRobotService();
      final completer = Completer<AiChatResponse>();
      final backend = FakeAiBackendClient()
        ..handler = (_, _, _) => completer.future;
      final voice = FakeVoiceService();
      final controller = McQueenAiController(
        robot: robot,
        backendClient: backend,
        voiceService: voice,
        enableBackgroundHealthCheck: false,
      );
      addTearDown(() {
        controller.dispose();
        robot.dispose();
      });

      final sendFuture = controller.sendMessage('Avance agora!');
      await Future<void>.delayed(Duration.zero);
      expect(controller.state, AiAssistantState.processing);

      await controller.emergencyStop();
      expect(controller.state, AiAssistantState.idle);

      completer.complete(
        const AiChatResponse(
          reply: 'Acelerando!',
          intents: [
            RobotIntent(tool: 'move_robot', arguments: {'direction': 'forward'}),
          ],
        ),
      );
      await sendFuture;

      expect(voice.spokenTexts, isEmpty);
      expect(controller.state, AiAssistantState.idle);
    });
  });
}
