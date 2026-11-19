// lib/ui/widgets/turn_signals_section.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../core/robot_service.dart';
import '../../models/turn_signal_state.dart';
import '../../theme/app_theme.dart';

/// Controle das setas direcionais (GPIO 7 esquerda, GPIO 9 direita).
/// Mantém o piscar (~500 ms) sincronizado com os LEDs físicos quando ativo.
class TurnSignalsSection extends StatefulWidget {
  final bool compact;

  const TurnSignalsSection({super.key, this.compact = false});

  @override
  State<TurnSignalsSection> createState() => _TurnSignalsSectionState();
}

class _TurnSignalsSectionState extends State<TurnSignalsSection>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blinkController;
  TurnSignalState _lastSyncedState = TurnSignalState.off;

  @override
  void initState() {
    super.initState();
    // Ciclo completo de 1000 ms (500 ms aceso / 500 ms apagado), idêntico ao firmware.
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  void _syncBlinkAnimation(bool shouldBlink, TurnSignalState state) {
    final activatedNewMode = state != _lastSyncedState && shouldBlink;
    _lastSyncedState = shouldBlink ? state : TurnSignalState.off;

    if (shouldBlink && (!_blinkController.isAnimating || activatedNewMode)) {
      _blinkController.repeat();
    } else if (!shouldBlink && _blinkController.isAnimating) {
      _blinkController.stop();
      _blinkController.value = 0;
    }
  }

  void _triggerSignal(RobotService robot, TurnSignalState target) {
    if (!robot.isConnected) return;
    HapticFeedback.selectionClick();
    robot.setTurnSignal(target);
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final isConnected = robot.isConnected;
    final current = isConnected ? robot.turnSignal : TurnSignalState.off;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldBlink = !disableAnimations &&
        isConnected &&
        (current.isLeftBlinking || current.isRightBlinking);
    _syncBlinkAnimation(shouldBlink, current);

    return AnimatedBuilder(
      animation: _blinkController,
      builder: (context, _) {
        final blinkOn = disableAnimations
            ? (isConnected && (current.isLeftBlinking || current.isRightBlinking))
            : (shouldBlink && _blinkController.value < 0.5);
        final leftLit = isConnected && current.isLeftBlinking && blinkOn;
        final rightLit = isConnected && current.isRightBlinking && blinkOn;
        final isAuto = isConnected && current == TurnSignalState.auto;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Luzes-espia sincronizadas ESQ / DIR
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: McQueenColors.bgSecondary,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: current.isActive && isConnected
                      ? current.accentColor.withValues(alpha: 0.4)
                      : McQueenColors.borderSubtle,
                ),
              ),
              child: Row(
                children: [
                  Flexible(
                    child: _LedIndicatorPill(
                      icon: Icons.west_rounded,
                      label: 'ESQ · GPIO 7',
                      lit: leftLit,
                      auto: isAuto,
                      activeColor: TurnSignalState.left.accentColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            isConnected ? current.label : 'Desconectado',
                            maxLines: 1,
                            style: GoogleFonts.outfit(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: !isConnected
                                  ? McQueenColors.textMuted
                                  : current.isActive
                                      ? current.accentColor
                                      : McQueenColors.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            isConnected
                                ? (isAuto
                                    ? 'Auto nas curvas'
                                    : 'Pisca 500 ms')
                                : 'Conecte para testar',
                            maxLines: 1,
                            style: GoogleFonts.outfit(
                              fontSize: 10.5,
                              color: McQueenColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: _LedIndicatorPill(
                      icon: Icons.east_rounded,
                      label: 'DIR · GPIO 9',
                      lit: rightLit,
                      auto: isAuto,
                      activeColor: TurnSignalState.right.accentColor,
                      iconRight: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Controles principais
            Row(
              children: [
                Expanded(
                  child: _SetaControlTile(
                    label: 'Seta Esquerda',
                    icon: Icons.turn_left_rounded,
                    color: McQueenColors.amber,
                    enabled: isConnected,
                    selected: current == TurnSignalState.left,
                    lit: leftLit && current == TurnSignalState.left,
                    onTap: () => _triggerSignal(robot, TurnSignalState.left),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SetaControlTile(
                    label: 'Seta Direita',
                    icon: Icons.turn_right_rounded,
                    color: McQueenColors.amber,
                    enabled: isConnected,
                    selected: current == TurnSignalState.right,
                    lit: rightLit && current == TurnSignalState.right,
                    onTap: () => _triggerSignal(robot, TurnSignalState.right),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _SetaControlTile(
                    label: 'Pisca-Alerta',
                    icon: Icons.warning_amber_rounded,
                    color: McQueenColors.orange,
                    enabled: isConnected,
                    selected: current == TurnSignalState.alert,
                    lit: (leftLit || rightLit) &&
                        current == TurnSignalState.alert,
                    onTap: () => _triggerSignal(robot, TurnSignalState.alert),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SetaControlTile(
                    label: 'Auto',
                    icon: Icons.auto_awesome_rounded,
                    color: McQueenColors.emerald,
                    enabled: isConnected,
                    selected: current == TurnSignalState.auto,
                    lit: current == TurnSignalState.auto,
                    onTap: () => _triggerSignal(robot, TurnSignalState.auto),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _SetaControlTile(
                    label: 'Desligar',
                    icon: Icons.power_settings_new_rounded,
                    color: McQueenColors.textSecondary,
                    enabled: isConnected,
                    selected: current == TurnSignalState.off,
                    lit: false,
                    onTap: () => _triggerSignal(robot, TurnSignalState.off),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _LedIndicatorPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool lit;
  final bool auto;
  final Color activeColor;
  final bool iconRight;

  const _LedIndicatorPill({
    required this.icon,
    required this.label,
    required this.lit,
    required this.auto,
    required this.activeColor,
    this.iconRight = false,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = auto ? McQueenColors.emerald : activeColor;
    final fg = lit
        ? Colors.black
        : (auto ? McQueenColors.emerald : McQueenColors.textMuted);

    final children = [
      Icon(icon, size: 13, color: fg),
      const SizedBox(width: 4),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ),
      ),
    ];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 90),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: lit
            ? effectiveColor
            : (auto
                ? McQueenColors.emerald.withValues(alpha: 0.14)
                : McQueenColors.surface),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: lit
              ? effectiveColor
              : (auto ? McQueenColors.emerald : McQueenColors.borderSubtle),
        ),
        boxShadow: lit
            ? [
                BoxShadow(
                  color: effectiveColor.withValues(alpha: 0.4),
                  blurRadius: 12,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: iconRight ? children.reversed.toList() : children,
      ),
    );
  }
}

class _SetaControlTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final bool selected;
  final bool lit;
  final VoidCallback onTap;

  const _SetaControlTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.selected,
    required this.lit,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlighted = enabled && (selected || lit);

    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            decoration: BoxDecoration(
              color: lit
                  ? color.withValues(alpha: 0.24)
                  : (highlighted
                      ? color.withValues(alpha: 0.14)
                      : McQueenColors.surfaceElevated),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: highlighted
                    ? color.withValues(alpha: 0.75)
                    : McQueenColors.borderSubtle,
                width: highlighted ? 1.5 : 1.0,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: highlighted ? color : McQueenColors.textSecondary,
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: highlighted ? color : McQueenColors.textPrimary,
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

/// Barra compacta de setas e pisca-alerta para a tela de controle horizontal (landscape).
class LandscapeTurnSignalsBar extends StatefulWidget {
  final bool compact;

  const LandscapeTurnSignalsBar({super.key, this.compact = false});

  @override
  State<LandscapeTurnSignalsBar> createState() =>
      _LandscapeTurnSignalsBarState();
}

class _LandscapeTurnSignalsBarState extends State<LandscapeTurnSignalsBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blinkController;
  TurnSignalState _lastSyncedState = TurnSignalState.off;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  void _syncBlink(bool shouldBlink, TurnSignalState state) {
    final restarted = state != _lastSyncedState && shouldBlink;
    _lastSyncedState = shouldBlink ? state : TurnSignalState.off;

    if (shouldBlink && (!_blinkController.isAnimating || restarted)) {
      _blinkController.repeat();
    } else if (!shouldBlink && _blinkController.isAnimating) {
      _blinkController.stop();
      _blinkController.value = 0;
    }
  }

  void _sendSignal(RobotService robot, TurnSignalState target) {
    if (!robot.isConnected) return;
    HapticFeedback.selectionClick();
    robot.setTurnSignal(target);
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final isConnected = robot.isConnected;
    final current = isConnected ? robot.turnSignal : TurnSignalState.off;
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldBlink = !disableAnimations &&
        isConnected &&
        (current.isLeftBlinking || current.isRightBlinking);
    _syncBlink(shouldBlink, current);

    return AnimatedBuilder(
      animation: _blinkController,
      builder: (context, _) {
        final blinkOn = disableAnimations
            ? (isConnected &&
                (current.isLeftBlinking || current.isRightBlinking))
            : (shouldBlink && _blinkController.value < 0.5);
        final leftLit = isConnected && current.isLeftBlinking && blinkOn;
        final rightLit = isConnected && current.isRightBlinking && blinkOn;
        final alertLit =
            isConnected && current == TurnSignalState.alert && blinkOn;

        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.compact ? 360 : 440),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: McQueenColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: current.isActive && isConnected
                    ? current.accentColor.withValues(alpha: 0.45)
                    : McQueenColors.borderSubtle,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _LandscapeSignalChip(
                    tooltip: 'Seta Esquerda',
                    label: 'Esq',
                    icon: Icons.arrow_back_rounded,
                    color: McQueenColors.amber,
                    enabled: isConnected,
                    selected: current == TurnSignalState.left,
                    lit: leftLit,
                    compact: widget.compact,
                    onTap: () => _sendSignal(robot, TurnSignalState.left),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _LandscapeSignalChip(
                    tooltip: 'Pisca-Alerta',
                    label: 'Alerta',
                    icon: Icons.warning_amber_rounded,
                    color: McQueenColors.orange,
                    enabled: isConnected,
                    selected: current == TurnSignalState.alert,
                    lit: alertLit,
                    compact: widget.compact,
                    onTap: () => _sendSignal(robot, TurnSignalState.alert),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _LandscapeSignalChip(
                    tooltip: 'Desligar Indicadores',
                    label: 'Desligar',
                    icon: Icons.power_settings_new_rounded,
                    color: McQueenColors.textSecondary,
                    enabled: isConnected,
                    selected: current == TurnSignalState.off,
                    lit: false,
                    compact: widget.compact,
                    onTap: () => _sendSignal(robot, TurnSignalState.off),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: _LandscapeSignalChip(
                    tooltip: 'Seta Direita',
                    label: 'Dir',
                    icon: Icons.arrow_forward_rounded,
                    color: McQueenColors.amber,
                    enabled: isConnected,
                    selected: current == TurnSignalState.right,
                    lit: rightLit,
                    compact: widget.compact,
                    iconRight: true,
                    onTap: () => _sendSignal(robot, TurnSignalState.right),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LandscapeSignalChip extends StatelessWidget {
  final String tooltip;
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final bool selected;
  final bool lit;
  final bool compact;
  final bool iconRight;
  final VoidCallback onTap;

  const _LandscapeSignalChip({
    required this.tooltip,
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.selected,
    required this.lit,
    required this.compact,
    required this.onTap,
    this.iconRight = false,
  });

  @override
  Widget build(BuildContext context) {
    final active = enabled && selected;
    final bg = lit
        ? color.withValues(alpha: 0.28)
        : (active ? color.withValues(alpha: 0.14) : Colors.transparent);
    final border = lit
        ? color
        : (active ? color.withValues(alpha: 0.65) : Colors.transparent);
    final fg = !enabled
        ? McQueenColors.textMuted.withValues(alpha: 0.55)
        : (lit || active ? color : McQueenColors.textSecondary);

    final rowChildren = <Widget>[
      Icon(icon, size: compact ? 15 : 17, color: fg),
      const SizedBox(width: 4),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: GoogleFonts.outfit(
              fontSize: compact ? 10.5 : 11.5,
              fontWeight: active || lit ? FontWeight.w700 : FontWeight.w600,
              color: active || lit ? McQueenColors.textPrimary : fg,
            ),
          ),
        ),
      ),
    ];

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 6 : 10,
              vertical: compact ? 5 : 7,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: border),
              boxShadow: lit
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.35),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: iconRight ? rowChildren.reversed.toList() : rowChildren,
            ),
          ),
        ),
      ),
    );
  }
}
