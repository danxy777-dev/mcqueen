// lib/ui/control_page.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../core/ble_constants.dart';
import '../core/robot_service.dart';
import '../theme/app_theme.dart';
import 'screens/ai/mcqueen_ai_screen.dart';
import 'screens/settings/settings_hub_screen.dart';
import 'widgets/analog_joystick.dart';
import 'widgets/connection_dialogs.dart';
import 'widgets/connection_pill.dart';
import 'widgets/turn_signals_section.dart';

/// Tela principal de condução do McQueen.
/// - Em retrato: cockpit minimalista com joystick analógico, velocidade, buzina e parada.
/// - Em paisagem: gamepad de 4 botões direcionais (FRENTE, RÉ, ESQUERDA, DIREITA) + EMERGÊNCIA.
class ControlPage extends StatefulWidget {
  const ControlPage({super.key});

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> with WidgetsBindingObserver {
  StreamSubscription<ConnectionEvent>? _eventSub;
  RobotService? _robotService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<RobotService>();
    if (_robotService != service) {
      _eventSub?.cancel();
      _robotService = service;
      _eventSub = service.connectionEvents.listen(_handleConnectionEvent);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (_robotService?.isConnected ?? false)) {
      unawaited(_robotService!.emergencyStop());
    }
  }

  void _handleConnectionEvent(ConnectionEvent event) {
    if (!mounted) return;

    switch (event) {
      case ConnectionSuccessEvent():
        ConnectionDialogs.showSuccess(context);
        break;
      case ConnectionFailureEvent(:final specificCause):
        ConnectionDialogs.showFailure(
          context,
          specificCause: specificCause,
          onRetry: () => _robotService?.connect(),
        );
        break;
      case UnexpectedDisconnectEvent(:final message):
        ConnectionDialogs.showDisconnected(
          context,
          message: message,
          onReconnect: () => _robotService?.connect(),
        );
        break;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    super.dispose();
  }

  Future<void> _openSettings() async {
    if (_robotService?.isConnected ?? false) {
      await _robotService!.emergencyStop();
    }
    if (!mounted) return;
    await SettingsHubScreen.open(context);
  }

  Future<void> _openAiAssistant() async {
    if (_robotService?.isConnected ?? false) {
      await _robotService!.emergencyStop();
    }
    if (!mounted) return;
    await McQueenAiScreen.open(context);
  }

  static Future<void> _triggerHorn(
    BuildContext context,
    RobotService robot,
  ) async {
    HapticFeedback.mediumImpact();
    final res = await robot.sendBuzina();
    if (!res.ok && context.mounted) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.clearSnackBars();
      messenger?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(res.error ?? 'Não foi possível acionar a buzina.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();

    return Scaffold(
      backgroundColor: McQueenColors.bgPrimary,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isLandscape = constraints.maxWidth > constraints.maxHeight &&
                constraints.maxWidth >= 480;
            if (isLandscape) {
              return _LandscapeDriveView(
                robot: robot,
                constraints: constraints,
                onOpenSettings: _openSettings,
                onOpenAi: _openAiAssistant,
              );
            }
            return _PortraitDriveView(
              robot: robot,
              constraints: constraints,
              onOpenSettings: _openSettings,
              onOpenAi: _openAiAssistant,
            );
          },
        ),
      ),
    );
  }
}

// ── Cockpit Vertical (Portrait) ──────────────────────────────────────────────
class _PortraitDriveView extends StatelessWidget {
  final RobotService robot;
  final BoxConstraints constraints;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAi;

  const _PortraitDriveView({
    required this.robot,
    required this.constraints,
    required this.onOpenSettings,
    required this.onOpenAi,
  });

  @override
  Widget build(BuildContext context) {
    final isCompactHeight = constraints.maxHeight < 650;
    final isNarrowWidth = constraints.maxWidth < 360;
    final horizontalPad = isNarrowWidth ? 14.0 : 22.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPad,
        isCompactHeight ? 10 : 16,
        horizontalPad,
        isCompactHeight ? 14 : 22,
      ),
      child: Column(
        children: [
          // 1 & 2 & 7: Identidade McQueen, Estado BLE, McQueen AI e Configurações
          _TopCockpitBar(
            onOpenSettings: onOpenSettings,
            onOpenAi: onOpenAi,
            compact: isCompactHeight || isNarrowWidth,
          ),

          SizedBox(height: isCompactHeight ? 12 : 20),

          // 4: Indicador discreto do modo / velocidade selecionada
          _CompactSpeedPill(robot: robot),

          // 3: Joystick Analógico Circular como controle central dominante
          Expanded(
            child: LayoutBuilder(
              builder: (context, centerConstraints) {
                final avail = math.min(
                  centerConstraints.maxWidth,
                  centerConstraints.maxHeight,
                );
                final minDiameter = math.min(avail, 160.0);
                final joyDiameter = (avail * 0.88).clamp(minDiameter, 300.0);
                return Center(
                  child: AnalogJoystick(diameter: joyDiameter),
                );
              },
            ),
          ),

          SizedBox(height: isCompactHeight ? 10 : 16),

          // 5 & 6: Botão de Buzina e Botão de Parada de Emergência
          _BottomActionDeck(
            robot: robot,
            compact: isCompactHeight,
          ),
        ],
      ),
    );
  }
}

class _TopCockpitBar extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAi;
  final bool compact;

  const _TopCockpitBar({
    required this.onOpenSettings,
    required this.onOpenAi,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Emblema + Nome McQueen
        Container(
          width: compact ? 34 : 38,
          height: compact ? 34 : 38,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [McQueenColors.crimson, McQueenColors.crimsonDeep],
            ),
            boxShadow: [
              BoxShadow(
                color: McQueenColors.crimson.withValues(alpha: 0.35),
                blurRadius: 14,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            Icons.bolt_rounded,
            color: Colors.white,
            size: compact ? 19 : 21,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                'McQueen',
                maxLines: 1,
                style: GoogleFonts.outfit(
                  fontSize: compact ? 17.5 : 20,
                  fontWeight: FontWeight.w700,
                  color: McQueenColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        const Flexible(
          flex: 3,
          child: ConnectionPill(compact: true),
        ),
        const SizedBox(width: 6),
        _CockpitCircleButton(
          tooltip: 'McQueen AI',
          icon: Icons.auto_awesome_rounded,
          iconColor: McQueenColors.cyan,
          onTap: onOpenAi,
          compact: compact,
        ),
        const SizedBox(width: 6),
        _CockpitCircleButton(
          tooltip: 'Configurações',
          icon: Icons.tune_rounded,
          iconColor: McQueenColors.textSecondary,
          onTap: onOpenSettings,
          compact: compact,
        ),
      ],
    );
  }
}

class _CockpitCircleButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;
  final bool compact;

  const _CockpitCircleButton({
    required this.tooltip,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 34.0 : 40.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: McQueenColors.surface,
              border: Border.all(color: McQueenColors.borderSubtle),
            ),
            child: Icon(
              icon,
              size: compact ? 18 : 19,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Seletor discreto de modo/velocidade (ECO, Normal, Sport, Turbo).
class _CompactSpeedPill extends StatelessWidget {
  final RobotService robot;
  final bool compact;

  const _CompactSpeedPill({required this.robot, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final current = robot.currentSpeed;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: compact ? 260 : 360),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: McQueenColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: McQueenColors.borderSubtle),
        ),
        child: Row(
          children: SpeedLevel.values.map((lvl) {
            final isSelected = current == lvl;
            final accent = switch (lvl) {
              SpeedLevel.eco => McQueenColors.emerald,
              SpeedLevel.normal => McQueenColors.cyan,
              SpeedLevel.sport => McQueenColors.amber,
              SpeedLevel.turbo => McQueenColors.crimson,
            };

            return Expanded(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    robot.setSpeed(lvl);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 4 : 6,
                      vertical: compact ? 5 : 7,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? accent.withValues(alpha: 0.18)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isSelected
                            ? accent.withValues(alpha: 0.55)
                            : Colors.transparent,
                      ),
                    ),
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          lvl.label,
                          maxLines: 1,
                          style: GoogleFonts.outfit(
                            fontSize: compact ? 11 : 12,
                            fontWeight:
                                isSelected ? FontWeight.w700 : FontWeight.w500,
                            color: isSelected
                                ? McQueenColors.textPrimary
                                : McQueenColors.textMuted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _BottomActionDeck extends StatelessWidget {
  final RobotService robot;
  final bool compact;

  const _BottomActionDeck({required this.robot, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final isConnected = robot.isConnected;
    final soundsEnabled = robot.settings.soundsEnabled;
    final hornActive = isConnected && robot.buzinaSent;
    final canHorn = isConnected && soundsEnabled;
    final btnHeight = compact ? 56.0 : 64.0;

    return Row(
      children: [
        // Botão de Buzina
        Expanded(
          child: _DeckActionButton(
            height: btnHeight,
            label: !soundsEnabled ? 'Mudo' : (hornActive ? 'Buzinando' : 'Buzina'),
            icon: !soundsEnabled
                ? Icons.volume_off_rounded
                : (hornActive
                    ? Icons.volume_up_rounded
                    : Icons.campaign_rounded),
            accentColor: McQueenColors.amber,
            active: hornActive,
            enabled: canHorn,
            onTap: () => _ControlPageState._triggerHorn(context, robot),
          ),
        ),
        const SizedBox(width: 12),
        // Botão de Parada de Emergência
        Expanded(
          child: _DeckActionButton(
            height: btnHeight,
            label: 'Parar',
            icon: Icons.stop_rounded,
            accentColor: McQueenColors.crimson,
            isPrimaryDanger: true,
            enabled: isConnected,
            onTap: () {
              HapticFeedback.heavyImpact();
              robot.emergencyStop();
            },
          ),
        ),
      ],
    );
  }
}

class _DeckActionButton extends StatefulWidget {
  final double height;
  final String label;
  final IconData icon;
  final Color accentColor;
  final bool enabled;
  final bool active;
  final bool isPrimaryDanger;
  final VoidCallback onTap;

  const _DeckActionButton({
    required this.height,
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.enabled,
    required this.onTap,
    this.active = false,
    this.isPrimaryDanger = false,
  });

  @override
  State<_DeckActionButton> createState() => _DeckActionButtonState();
}

class _DeckActionButtonState extends State<_DeckActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final fillColor = widget.isPrimaryDanger
        ? (widget.enabled
            ? (_pressed
                ? McQueenColors.crimsonDeep
                : McQueenColors.crimson)
            : McQueenColors.surface)
        : (widget.active
            ? widget.accentColor.withValues(alpha: 0.24)
            : (_pressed
                ? McQueenColors.surfaceHighlight
                : McQueenColors.surface));

    final borderColor = widget.isPrimaryDanger
        ? (widget.enabled
            ? McQueenColors.crimson
            : McQueenColors.borderSubtle)
        : (widget.active
            ? widget.accentColor
            : (widget.enabled
                ? McQueenColors.borderStrong
                : McQueenColors.borderSubtle));

    final fg = widget.isPrimaryDanger
        ? (widget.enabled ? Colors.white : McQueenColors.textMuted)
        : (widget.active
            ? widget.accentColor
            : (widget.enabled
                ? McQueenColors.textPrimary
                : McQueenColors.textMuted));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.enabled
          ? (_) {
              setState(() => _pressed = true);
              widget.onTap();
            }
          : null,
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: widget.height,
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: 1.2),
            boxShadow: widget.isPrimaryDanger && widget.enabled && !_pressed
                ? [
                    BoxShadow(
                      color: McQueenColors.crimson.withValues(alpha: 0.28),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.icon, size: 22, color: fg),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      style: GoogleFonts.outfit(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: fg,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Gamepad Horizontal (Landscape — 4 Botões + Emergência) ──────────────────
class _LandscapeDriveView extends StatelessWidget {
  final RobotService robot;
  final BoxConstraints constraints;
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenAi;

  const _LandscapeDriveView({
    required this.robot,
    required this.constraints,
    required this.onOpenSettings,
    required this.onOpenAi,
  });

  @override
  Widget build(BuildContext context) {
    final isCompact = constraints.maxWidth < 700 || constraints.maxHeight < 420;
    final isVeryNarrow = constraints.maxWidth < 560;
    final sidePad = isCompact ? 12.0 : 24.0;
    final vertPad = isCompact ? 8.0 : 12.0;
    final isHold = robot.controlMode == ControlMode.holdToMove;
    final soundsEnabled = robot.settings.soundsEnabled;
    final hornActive = robot.isConnected && robot.buzinaSent;
    final canHorn = robot.isConnected && soundsEnabled;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: sidePad,
        vertical: vertPad,
      ),
      child: Column(
        children: [
          // Barra superior horizontal discreta
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [McQueenColors.crimson, McQueenColors.crimsonDeep],
                  ),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              if (!isVeryNarrow) ...[
                const SizedBox(width: 8),
                Text(
                  'McQueen',
                  maxLines: 1,
                  style: GoogleFonts.outfit(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: McQueenColors.textPrimary,
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _CompactSpeedPill(robot: robot, compact: true),
                ),
              ),
              const SizedBox(width: 6),
              // Buzina rápida no gamepad horizontal
              Tooltip(
                message: !soundsEnabled
                    ? 'Buzina silenciada (Mudo)'
                    : (hornActive ? 'Buzinando' : 'Buzina'),
                child: IconButton(
                  onPressed: canHorn
                      ? () => _ControlPageState._triggerHorn(context, robot)
                      : null,
                  style: IconButton.styleFrom(
                    backgroundColor: hornActive
                        ? McQueenColors.amber.withValues(alpha: 0.22)
                        : McQueenColors.surface,
                    side: BorderSide(
                      color: hornActive
                          ? McQueenColors.amber
                          : McQueenColors.borderSubtle,
                    ),
                  ),
                  icon: Icon(
                    !soundsEnabled
                        ? Icons.volume_off_rounded
                        : (hornActive
                            ? Icons.volume_up_rounded
                            : Icons.campaign_rounded),
                    size: 19,
                    color: !soundsEnabled || !robot.isConnected
                        ? McQueenColors.textMuted
                        : (hornActive
                            ? McQueenColors.amber
                            : McQueenColors.textPrimary),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _CockpitCircleButton(
                tooltip: 'McQueen AI',
                icon: Icons.auto_awesome_rounded,
                iconColor: McQueenColors.cyan,
                onTap: onOpenAi,
                compact: true,
              ),
              const SizedBox(width: 6),
              const Flexible(
                flex: 0,
                child: ConnectionPill(compact: true),
              ),
              const SizedBox(width: 6),
              _CockpitCircleButton(
                tooltip: 'Configurações',
                icon: Icons.tune_rounded,
                iconColor: McQueenColors.textSecondary,
                onTap: onOpenSettings,
                compact: true,
              ),
            ],
          ),
          SizedBox(height: isCompact ? 6 : 10),

          // Área principal dos 4 botões + Parada de Emergência (sem cortes nem overflow)
          Expanded(
            child: LayoutBuilder(
              builder: (context, padConstraints) {
                final gap = (padConstraints.maxWidth < 560 ||
                        padConstraints.maxHeight < 230)
                    ? 10.0
                    : (isCompact ? 14.0 : 20.0);
                final emergencySize = math
                    .min(
                      isCompact ? 74.0 : 88.0,
                      math.min(
                        padConstraints.maxHeight * 0.72,
                        padConstraints.maxWidth * 0.22,
                      ),
                    )
                    .clamp(44.0, 88.0);
                final maxBtnH = (padConstraints.maxHeight - gap) / 2.0;
                final maxBtnW =
                    (padConstraints.maxWidth - emergencySize - gap * 4.0) / 4.0;
                final rawBtn = math.min(maxBtnH, maxBtnW);
                final minBtn = math.min(rawBtn, 44.0);
                final buttonSize = rawBtn.clamp(minBtn, 118.0);
                final iconSize = buttonSize * 0.42;
                final fontSize = (buttonSize * 0.13).clamp(9.0, 14.0);

                return Row(
                  children: [
                    // Esquerda: FRENTE / RÉ
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _GamepadPadButton(
                            icon: Icons.keyboard_arrow_up_rounded,
                            label: 'FRENTE',
                            color: McQueenColors.emerald,
                            size: buttonSize,
                            iconSize: iconSize,
                            fontSize: fontSize,
                            enabled: robot.isConnected,
                            onPressStart: () {
                              HapticFeedback.lightImpact();
                              robot.startMovement(BleConstants.cmdFrente);
                            },
                            onPressEnd: () {
                              if (isHold) {
                                robot.stopMovement(BleConstants.cmdFrente);
                              }
                            },
                          ),
                          SizedBox(height: gap),
                          _GamepadPadButton(
                            icon: Icons.keyboard_arrow_down_rounded,
                            label: 'RÉ',
                            color: McQueenColors.crimson,
                            size: buttonSize,
                            iconSize: iconSize,
                            fontSize: fontSize,
                            enabled: robot.isConnected,
                            onPressStart: () {
                              HapticFeedback.lightImpact();
                              robot.startMovement(BleConstants.cmdTras);
                            },
                            onPressEnd: () {
                              if (isHold) {
                                robot.stopMovement(BleConstants.cmdTras);
                              }
                            },
                          ),
                        ],
                      ),
                    ),

                    // Centro: EMERGÊNCIA
                    SizedBox(width: gap),
                    _GamepadPadButton(
                      icon: Icons.stop_rounded,
                      label: 'EMERGÊNCIA',
                      color: McQueenColors.crimson,
                      size: emergencySize,
                      iconSize: emergencySize * 0.42,
                      fontSize: (emergencySize * 0.125).clamp(8.5, 11.5),
                      isFilledDanger: true,
                      enabled: robot.isConnected,
                      onPressStart: () {
                        HapticFeedback.heavyImpact();
                        robot.emergencyStop();
                      },
                    ),
                    SizedBox(width: gap),

                    // Direita: ESQUERDA / DIREITA
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _GamepadPadButton(
                            icon: Icons.keyboard_arrow_left_rounded,
                            label: 'ESQUERDA',
                            color: McQueenColors.cyan,
                            size: buttonSize,
                            iconSize: iconSize,
                            fontSize: fontSize,
                            enabled: robot.isConnected,
                            onPressStart: () {
                              HapticFeedback.lightImpact();
                              robot.startMovement(BleConstants.cmdEsquerda);
                            },
                            onPressEnd: () {
                              if (isHold) {
                                robot.stopMovement(BleConstants.cmdEsquerda);
                              }
                            },
                          ),
                          SizedBox(width: gap),
                          _GamepadPadButton(
                            icon: Icons.keyboard_arrow_right_rounded,
                            label: 'DIREITA',
                            color: McQueenColors.amber,
                            size: buttonSize,
                            iconSize: iconSize,
                            fontSize: fontSize,
                            enabled: robot.isConnected,
                            onPressStart: () {
                              HapticFeedback.lightImpact();
                              robot.startMovement(BleConstants.cmdDireita);
                            },
                            onPressEnd: () {
                              if (isHold) {
                                robot.stopMovement(BleConstants.cmdDireita);
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          SizedBox(height: isCompact ? 6 : 8),

          // Indicadores de direção integrados (Esq, Alerta, Desligar, Dir)
          LandscapeTurnSignalsBar(compact: isCompact),
        ],
      ),
    );
  }
}

class _GamepadPadButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color color;
  final double size;
  final double iconSize;
  final double fontSize;
  final bool enabled;
  final bool isFilledDanger;
  final VoidCallback onPressStart;
  final VoidCallback? onPressEnd;

  const _GamepadPadButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.size,
    required this.iconSize,
    required this.fontSize,
    required this.enabled,
    required this.onPressStart,
    this.onPressEnd,
    this.isFilledDanger = false,
  });

  @override
  State<_GamepadPadButton> createState() => _GamepadPadButtonState();
}

class _GamepadPadButtonState extends State<_GamepadPadButton> {
  bool _down = false;

  @override
  void didUpdateWidget(covariant _GamepadPadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _down) {
      _down = false;
      final onEnd = widget.onPressEnd;
      if (onEnd != null) {
        Future<void>.microtask(onEnd);
      }
    }
  }

  @override
  void deactivate() {
    if (_down) {
      _down = false;
      final onEnd = widget.onPressEnd;
      if (onEnd != null) {
        Future<void>.microtask(onEnd);
      }
    }
    super.deactivate();
  }

  void _handleDown() {
    if (!widget.enabled || _down) return;
    setState(() => _down = true);
    widget.onPressStart();
  }

  void _handleUp() {
    if (!_down) return;
    setState(() => _down = false);
    widget.onPressEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isFilledDanger
        ? (widget.enabled
            ? (_down ? McQueenColors.crimsonDeep : McQueenColors.crimson)
            : McQueenColors.surface)
        : (_down
            ? widget.color.withValues(alpha: 0.28)
            : McQueenColors.surface);

    final border = widget.isFilledDanger
        ? (widget.enabled
            ? McQueenColors.crimson
            : McQueenColors.borderSubtle)
        : (_down
            ? widget.color
            : (widget.enabled
                ? widget.color.withValues(alpha: 0.35)
                : McQueenColors.borderSubtle));

    final fg = widget.isFilledDanger
        ? Colors.white
        : (widget.enabled ? widget.color : McQueenColors.textMuted);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: widget.enabled ? (_) => _handleDown() : null,
      onPointerUp: (_) => _handleUp(),
      onPointerCancel: (_) => _handleUp(),
      child: AnimatedScale(
        scale: _down ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: border, width: _down ? 2.0 : 1.3),
            boxShadow: _down && widget.enabled
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.25),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Opacity(
            opacity: widget.enabled ? 1.0 : 0.35,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, size: widget.iconSize, color: fg),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      style: GoogleFonts.outfit(
                        fontSize: widget.fontSize,
                        fontWeight: FontWeight.w700,
                        color: widget.isFilledDanger
                            ? Colors.white
                            : McQueenColors.textPrimary,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
