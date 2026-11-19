// lib/ui/screens/ai/mcqueen_ai_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../ai/mcqueen_ai_controller.dart';
import '../../../ai/voice_service.dart';
import '../../../config/ai_config.dart';
import '../../../core/robot_service.dart';
import '../../../models/ai_models.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/connection_pill.dart';

/// Tela dedicada do assistente conversacional, social e por voz **McQueen AI**.
/// Separada da tela principal de condução para manter a pilotagem limpa.
class McQueenAiScreen extends StatefulWidget {
  final AiBackendClient? backendClient;
  final VoiceService? voiceService;

  const McQueenAiScreen({
    super.key,
    this.backendClient,
    this.voiceService,
  });

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const McQueenAiScreen(),
      ),
    );
  }

  @override
  State<McQueenAiScreen> createState() => _McQueenAiScreenState();
}

class _McQueenAiScreenState extends State<McQueenAiScreen>
    with WidgetsBindingObserver {
  late final McQueenAiController _controller;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  int _lastRenderedMsgCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final robot = context.read<RobotService>();
    _controller = McQueenAiController(
      robot: robot,
      backendClient: widget.backendClient,
      voiceService: widget.voiceService,
    );
    _controller.addListener(_onControllerUpdated);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _controller.setScreenActive(state == AppLifecycleState.resumed);
  }

  void _onControllerUpdated() {
    if (!mounted) return;
    if (_controller.messages.length != _lastRenderedMsgCount) {
      _lastRenderedMsgCount = _controller.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerUpdated);
    _controller.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget? _buildBackendBanner(McQueenAiController ai) {
    final health = ai.backendHealth;
    if (health == null) {
      if (!ai.isCheckingHealth) return null;
      return const _CompactAiBanner(
        color: McQueenColors.cyan,
        icon: Icons.sync_rounded,
        text: 'Verificando conexão com o servidor McQueen AI...',
      );
    }

    final status = health.effectiveStatus;
    if (status == AiBackendStatus.online) {
      return null;
    }

    final urlLabel = ai.voiceSettings.backendUrl.trim();
    switch (status) {
      case AiBackendStatus.notConfigured:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              'Backend em nuvem ainda não configurado. Informe a URL HTTPS do servidor no Render para ativar a IA.',
          actionLabel: 'Configurar',
          onAction: _openVoiceAndServerSheet,
        );
      case AiBackendStatus.noInternet:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              health.error ??
              'Sem conexão com a internet no celular. Verifique Wi-Fi ou dados móveis.',
          actionLabel: ai.isCheckingHealth ? null : 'Tentar',
          onAction: ai.isCheckingHealth ? null : ai.retryConnection,
        );
      case AiBackendStatus.wakingUp:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              health.error ??
              'Servidor McQueen AI acordando na nuvem após inatividade. Aguarde alguns segundos.',
          actionLabel: ai.isCheckingHealth ? null : 'Tentar',
          onAction: ai.isCheckingHealth ? null : ai.retryConnection,
        );
      case AiBackendStatus.llmUnavailable:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              health.error ??
              'Servidor alcançado, porém o provedor de IA está indisponível ou sem chave configurada no backend.',
          actionLabel: ai.isCheckingHealth ? null : 'Testar',
          onAction: ai.isCheckingHealth ? null : ai.retryConnection,
          secondaryLabel: 'Configurar',
          onSecondaryAction: _openVoiceAndServerSheet,
        );
      case AiBackendStatus.invalidApiKey:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              health.error ??
              'Falha de autenticação no servidor (chave de API LLM ou token do app inválida).',
          actionLabel: 'Configurar',
          onAction: _openVoiceAndServerSheet,
        );
      case AiBackendStatus.rateLimited:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              health.error ??
              'Limite temporário de requisições atingido (429). Aguarde alguns segundos.',
        );
      case AiBackendStatus.backendUnavailable:
      case AiBackendStatus.communicationError:
      case AiBackendStatus.checking:
      case AiBackendStatus.online:
        return _CompactAiBanner(
          color: status.color,
          icon: status.icon,
          text:
              health.error ??
              'Backend indisponível${urlLabel.isNotEmpty ? ' em $urlLabel' : ''}.',
          actionLabel: ai.isCheckingHealth ? null : 'Tentar',
          onAction: ai.isCheckingHealth ? null : ai.retryConnection,
          secondaryLabel: 'Configurar',
          onSecondaryAction: _openVoiceAndServerSheet,
        );
    }
  }

  void _submitText() {
    final txt = _textController.text.trim();
    if (txt.isEmpty || _controller.isBusy) return;
    _textController.clear();
    unawaited(_controller.sendMessage(txt));
  }

  void _openVoiceAndServerSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: McQueenColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ChangeNotifierProvider<McQueenAiController>.value(
        value: _controller,
        child: const _AiSettingsSheet(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();

    return ChangeNotifierProvider<McQueenAiController>.value(
      value: _controller,
      child: Consumer<McQueenAiController>(
        builder: (context, ai, _) {
          final backendBanner = _buildBackendBanner(ai);

          return Scaffold(
            backgroundColor: McQueenColors.bgPrimary,
            appBar: AppBar(
              titleSpacing: 0,
              title: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [McQueenColors.crimson, McQueenColors.cyan],
                      ),
                    ),
                    child: const Icon(
                      Icons.auto_awesome_rounded,
                      color: Colors.white,
                      size: 17,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'McQueen AI',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.outfit(
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                            color: McQueenColors.textPrimary,
                          ),
                        ),
                        _AiStateInlineBadge(state: ai.state),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Center(child: ConnectionPill(compact: true)),
                ),
                IconButton(
                  tooltip: ai.voiceSettings.autoSpeak
                      ? 'Desativar voz automática'
                      : 'Ativar voz automática',
                  icon: Icon(
                    ai.voiceSettings.autoSpeak
                        ? Icons.volume_up_rounded
                        : Icons.volume_off_rounded,
                    color: ai.voiceSettings.autoSpeak
                        ? McQueenColors.cyan
                        : McQueenColors.textMuted,
                    size: 21,
                  ),
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    ai.updateVoiceSettings(
                      ai.voiceSettings.copyWith(
                        autoSpeak: !ai.voiceSettings.autoSpeak,
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Configurações de Voz e IA',
                  icon: const Icon(Icons.tune_rounded, size: 21),
                  onPressed: _openVoiceAndServerSheet,
                ),
                IconButton(
                  tooltip: 'Limpar conversa',
                  icon: const Icon(Icons.delete_outline_rounded, size: 21),
                  onPressed: ai.messages.isEmpty
                      ? null
                      : () {
                          HapticFeedback.lightImpact();
                          ai.clearConversation();
                        },
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  if (!robot.isConnected)
                    _CompactAiBanner(
                      color: McQueenColors.amber,
                      icon: Icons.bluetooth_disabled_rounded,
                      text:
                          'BLE desconectado: você pode conversar com o McQueen AI normalmente, mas comandos físicos ficam bloqueados por segurança.',
                      actionLabel: 'Conectar',
                      onAction: () => robot.connect(),
                    ),
                  ?backendBanner,

                  if (ai.isTimedMotionActive || robot.motorState.isMoving)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: McQueenColors.crimsonFill,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                          onPressed: () {
                            HapticFeedback.heavyImpact();
                            ai.emergencyStop();
                          },
                          icon: const Icon(Icons.stop_rounded),
                          label: const Text('PARAR ROBÔ IMEDIATAMENTE'),
                        ),
                      ),
                    ),

                  // Histórico de conversa
                  Expanded(
                    child: ai.messages.isEmpty
                        ? _EmptyAiIntro(
                            onQuickPrompt: (prompt) => ai.sendMessage(prompt),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            itemCount: ai.messages.length,
                            itemBuilder: (context, index) {
                              return _ChatBubble(message: ai.messages[index]);
                            },
                          ),
                  ),

                  // Barra viva de escuta / fala / erro
                  if (ai.isListening)
                    _LiveVoiceStrip(
                      color: McQueenColors.emerald,
                      icon: Icons.graphic_eq_rounded,
                      text: ai.partialTranscript.isNotEmpty
                          ? ai.partialTranscript
                          : 'Escutando em português (pt-BR)... fale naturalmente.',
                      actionLabel: 'Enviar',
                      onAction: ai.stopVoiceCapture,
                    )
                  else if (ai.isSpeaking)
                    _LiveVoiceStrip(
                      color: McQueenColors.violetText,
                      icon: Icons.volume_up_rounded,
                      text: 'McQueen falando...',
                      actionLabel: 'Interromper',
                      onAction: ai.interruptSpeech,
                    )
                  else if (ai.isBusy)
                    _LiveVoiceStrip(
                      color: McQueenColors.amber,
                      icon: Icons.psychology_rounded,
                      text: ai.state.label,
                    ),

                  // Área de entrada inferior (texto + microfone + parada rápida)
                  _BottomComposerBar(
                    textController: _textController,
                    ai: ai,
                    robotConnected: robot.isConnected,
                    onSend: _submitText,
                    onToggleMic: () {
                      HapticFeedback.mediumImpact();
                      ai.toggleVoiceCapture();
                    },
                    onEmergencyStop: () {
                      HapticFeedback.heavyImpact();
                      ai.emergencyStop();
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _AiStateInlineBadge extends StatelessWidget {
  final AiAssistantState state;

  const _AiStateInlineBadge({required this.state});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: state.color,
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            state.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.outfit(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: state.color,
            ),
          ),
        ),
      ],
    );
  }
}

class _CompactAiBanner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondaryAction;

  const _CompactAiBanner({
    required this.color,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondaryAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.outfit(
                fontSize: 11.5,
                color: McQueenColors.textPrimary,
                height: 1.3,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 30),
              ),
              child: Text(
                actionLabel!,
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          if (secondaryLabel != null && onSecondaryAction != null)
            TextButton(
              onPressed: onSecondaryAction,
              style: TextButton.styleFrom(
                foregroundColor: McQueenColors.textPrimary,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                minimumSize: const Size(0, 30),
              ),
              child: Text(
                secondaryLabel!,
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyAiIntro extends StatelessWidget {
  final ValueChanged<String> onQuickPrompt;

  const _EmptyAiIntro({required this.onQuickPrompt});

  static const _suggestions = [
    'Oi McQueen, tudo bem?',
    'Quem é Albert Einstein?',
    'Qual é a capital da França?',
    'Avance devagar e dê uma buzinada',
    'Ligue a seta esquerda',
    'Fique feliz!',
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [McQueenColors.crimson, McQueenColors.cyan],
              ),
              boxShadow: [
                BoxShadow(
                  color: McQueenColors.cyan.withValues(alpha: 0.25),
                  blurRadius: 22,
                ),
              ],
            ),
            child: const Icon(
              Icons.smart_toy_rounded,
              color: Colors.white,
              size: 34,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Converse com o McQueen AI',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: McQueenColors.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Pergunte qualquer coisa, bata um papo ou fale comandos naturais para dirigir, acender setas, buzinar e mudar expressões no OLED.',
            textAlign: TextAlign.center,
            style: GoogleFonts.outfit(
              fontSize: 13,
              color: McQueenColors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: _suggestions
                .map(
                  (s) => ActionChip(
                    backgroundColor: McQueenColors.surface,
                    side: const BorderSide(color: McQueenColors.borderSubtle),
                    label: Text(
                      s,
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        color: McQueenColors.textPrimary,
                      ),
                    ),
                    onPressed: () => onQuickPrompt(s),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final AiChatMessage message;

  const _ChatBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bg = isUser
        ? McQueenColors.crimsonFill.withValues(alpha: 0.24)
        : (message.isError
            ? McQueenColors.crimsonFill.withValues(alpha: 0.14)
            : McQueenColors.surfaceElevated);
    final border = isUser
        ? McQueenColors.crimson.withValues(alpha: 0.5)
        : (message.isError
            ? McQueenColors.crimsonText.withValues(alpha: 0.55)
            : McQueenColors.borderSubtle);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: align,
        children: [
          Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.82,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isUser ? 18 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 18),
              ),
              border: Border.all(color: border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isUser && message.isVoiceInput)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.mic_rounded,
                          size: 13,
                          color: McQueenColors.emerald,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Voz (pt-BR)',
                          style: GoogleFonts.outfit(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: McQueenColors.emerald,
                          ),
                        ),
                      ],
                    ),
                  ),
                Text(
                  message.text,
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    color: McQueenColors.textPrimary,
                    height: 1.38,
                  ),
                ),
                if (message.actionBadges.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: message.actionBadges.map((b) {
                      final isWarn = b.startsWith('⚠');
                      final c = isWarn
                          ? McQueenColors.amber
                          : McQueenColors.emerald;
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: c.withValues(alpha: 0.45)),
                        ),
                        child: Text(
                          b,
                          style: GoogleFonts.outfit(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: c,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveVoiceStrip extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _LiveVoiceStrip({
    required this.color,
    required this.icon,
    required this.text,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.outfit(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: McQueenColors.textPrimary,
              ),
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: color,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: Text(
                actionLabel!,
                style: GoogleFonts.outfit(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BottomComposerBar extends StatelessWidget {
  final TextEditingController textController;
  final McQueenAiController ai;
  final bool robotConnected;
  final VoidCallback onSend;
  final VoidCallback onToggleMic;
  final VoidCallback onEmergencyStop;

  const _BottomComposerBar({
    required this.textController,
    required this.ai,
    required this.robotConnected,
    required this.onSend,
    required this.onToggleMic,
    required this.onEmergencyStop,
  });

  @override
  Widget build(BuildContext context) {
    final listening = ai.isListening;

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: const BoxDecoration(
        color: McQueenColors.bgSecondary,
        border: Border(top: BorderSide(color: McQueenColors.borderSubtle)),
      ),
      child: Row(
        children: [
          // Botão físico/visual rápido de parada independente da IA
          Tooltip(
            message: 'Parada de emergência (PARAR)',
            child: SizedBox(
              width: 44,
              height: 44,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.zero,
                  backgroundColor: robotConnected
                      ? McQueenColors.crimsonFill
                      : McQueenColors.surface,
                  foregroundColor:
                      robotConnected ? Colors.white : McQueenColors.textMuted,
                  shape: const CircleBorder(),
                ),
                onPressed: robotConnected ? onEmergencyStop : null,
                child: const Icon(Icons.stop_rounded, size: 22),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: textController,
              enabled: !ai.isBusy,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              style: GoogleFonts.outfit(
                fontSize: 14,
                color: McQueenColors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: 'Converse ou dê um comando...',
                hintStyle: GoogleFonts.outfit(
                  fontSize: 13.5,
                  color: McQueenColors.textMuted,
                ),
                filled: true,
                fillColor: McQueenColors.surface,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide:
                      const BorderSide(color: McQueenColors.borderSubtle),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide:
                      const BorderSide(color: McQueenColors.borderSubtle),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: McQueenColors.cyan),
                ),
                suffixIcon: IconButton(
                  tooltip: 'Enviar mensagem',
                  onPressed: ai.isBusy ? null : onSend,
                  icon: const Icon(
                    Icons.send_rounded,
                    size: 20,
                    color: McQueenColors.cyan,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: listening ? 'Parar escuta' : 'Falar com McQueen (pt-BR)',
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: listening
                    ? McQueenColors.emerald
                    : McQueenColors.surfaceElevated,
                border: Border.all(
                  color: listening
                      ? McQueenColors.emerald
                      : McQueenColors.borderStrong,
                  width: 1.5,
                ),
                boxShadow: listening
                    ? [
                        BoxShadow(
                          color: McQueenColors.emerald.withValues(alpha: 0.45),
                          blurRadius: 16,
                        ),
                      ]
                    : null,
              ),
              child: IconButton(
                onPressed: ai.isBusy ? null : onToggleMic,
                icon: Icon(
                  listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                  color: listening ? Colors.black : McQueenColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiSettingsSheet extends StatefulWidget {
  const _AiSettingsSheet();

  @override
  State<_AiSettingsSheet> createState() => _AiSettingsSheetState();
}

class _AiSettingsSheetState extends State<_AiSettingsSheet> {
  late final TextEditingController _urlCtrl;
  late bool _allowLocalDevHttp;
  String? _urlError;

  @override
  void initState() {
    super.initState();
    final ai = context.read<McQueenAiController>();
    _urlCtrl = TextEditingController(text: ai.voiceSettings.backendUrl);
    _allowLocalDevHttp = ai.voiceSettings.allowLocalDevHttp;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest(McQueenAiController ai, AiVoiceSettings current) async {
    final raw = _urlCtrl.text;
    final validation = AiConfig.validateBackendUrl(
      raw,
      allowLocalHttp: _allowLocalDevHttp,
    );

    if (raw.trim().isNotEmpty && !validation.isValid) {
      setState(() {
        _urlError = validation.errorMessage;
      });
      return;
    }

    setState(() {
      _urlError = null;
    });

    await ai.updateVoiceSettings(
      current.copyWith(
        backendUrl: validation.normalizedUrl,
        allowLocalDevHttp: _allowLocalDevHttp,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ai = context.watch<McQueenAiController>();
    final s = ai.voiceSettings;
    final health = ai.backendHealth;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Voz e Servidor McQueen AI',
              style: GoogleFonts.outfit(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: McQueenColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Resposta falada automática (pt-BR)',
                style: GoogleFonts.outfit(fontSize: 14),
              ),
              value: s.autoSpeak,
              activeThumbColor: McQueenColors.cyan,
              onChanged: (v) => ai.updateVoiceSettings(s.copyWith(autoSpeak: v)),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Voz com timbre robótico leve',
                style: GoogleFonts.outfit(fontSize: 14),
              ),
              subtitle: Text(
                'Ajusta o tom (pitch) mantendo a fala natural e clara',
                style: GoogleFonts.outfit(
                  fontSize: 11.5,
                  color: McQueenColors.textMuted,
                ),
              ),
              value: s.roboticVoice,
              activeThumbColor: McQueenColors.violetText,
              onChanged: (v) =>
                  ai.updateVoiceSettings(s.copyWith(roboticVoice: v)),
            ),
            Text(
              'Velocidade da fala: ${s.speechRate.toStringAsFixed(2)}',
              style: GoogleFonts.outfit(
                fontSize: 13,
                color: McQueenColors.textSecondary,
              ),
            ),
            Slider(
              value: s.speechRate,
              min: 0.3,
              max: 0.85,
              divisions: 11,
              activeColor: McQueenColors.cyan,
              onChanged: (v) =>
                  ai.updateVoiceSettings(s.copyWith(speechRate: v)),
            ),
            Text(
              'Volume da fala: ${(s.volume * 100).round()}%',
              style: GoogleFonts.outfit(
                fontSize: 13,
                color: McQueenColors.textSecondary,
              ),
            ),
            Slider(
              value: s.volume,
              min: 0.0,
              max: 1.0,
              divisions: 10,
              activeColor: McQueenColors.emerald,
              onChanged: (v) => ai.updateVoiceSettings(s.copyWith(volume: v)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: GoogleFonts.jetBrainsMono(fontSize: 12.5),
              onChanged: (_) {
                if (_urlError != null) {
                  setState(() => _urlError = null);
                }
              },
              decoration: InputDecoration(
                labelText: 'URL HTTPS do Backend em Nuvem (sem chaves no app)',
                hintText: 'https://seu-mcqueen-ai.onrender.com',
                errorText: _urlError,
                errorMaxLines: 2,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Permitir HTTP local (desenvolvimento)',
                style: GoogleFonts.outfit(fontSize: 13.5),
              ),
              subtitle: Text(
                'Na internet é obrigatório HTTPS; ative somente para testar em localhost ou rede local.',
                style: GoogleFonts.outfit(
                  fontSize: 11,
                  color: McQueenColors.textMuted,
                ),
              ),
              value: _allowLocalDevHttp,
              activeThumbColor: McQueenColors.amber,
              onChanged: (v) {
                setState(() {
                  _allowLocalDevHttp = v;
                  _urlError = null;
                });
              },
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    ai.isCheckingHealth
                        ? 'Testando conexão com o servidor...'
                        : health == null
                            ? 'Aguardando verificação...'
                            : (health.ready
                                ? 'Online (${health.provider ?? 'llm'} · ${health.model ?? 'padrão'})'
                                : (health.error ?? health.effectiveStatus.label)),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      color: (health?.ready ?? false)
                          ? McQueenColors.emerald
                          : (health?.effectiveStatus.color ?? McQueenColors.amber),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: ai.isCheckingHealth ? null : () => _saveAndTest(ai, s),
                  child: const Text('Salvar & Testar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
