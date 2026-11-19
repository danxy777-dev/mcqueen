// lib/ui/widgets/connection_pill.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../core/robot_service.dart';
import '../../theme/app_theme.dart';

/// Cápsula minimalista de estado e ação rápida BLE (Conectar / Desconectar).
class ConnectionPill extends StatelessWidget {
  final bool compact;

  const ConnectionPill({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final state = robot.connectionState;
    final disableAnimations = MediaQuery.of(context).disableAnimations;

    final isLoading = state == RobotConnectionState.scanning ||
        state == RobotConnectionState.connecting ||
        state == RobotConnectionState.validatingService;

    final (label, color, icon) = switch (state) {
      RobotConnectionState.disconnected => (
          'Conectar',
          McQueenColors.textSecondary,
          Icons.bluetooth_rounded,
        ),
      RobotConnectionState.scanning => (
          'Buscando...',
          McQueenColors.amber,
          Icons.bluetooth_searching_rounded,
        ),
      RobotConnectionState.connecting => (
          'Conectando...',
          McQueenColors.cyan,
          Icons.bluetooth_searching_rounded,
        ),
      RobotConnectionState.validatingService => (
          'Validando...',
          McQueenColors.violetText,
          Icons.verified_user_outlined,
        ),
      RobotConnectionState.connected => (
          'Conectado',
          McQueenColors.emerald,
          Icons.bluetooth_connected_rounded,
        ),
      RobotConnectionState.error => (
          'Reconectar',
          McQueenColors.crimsonText,
          Icons.refresh_rounded,
        ),
    };

    final semanticHint = isLoading
        ? 'Aguarde a conclusão da operação Bluetooth'
        : (robot.isConnected
            ? 'Toque duas vezes para desconectar do McQueen'
            : 'Toque duas vezes para conectar ao McQueen');

    return Semantics(
      container: true,
      button: true,
      enabled: !isLoading,
      liveRegion: true,
      label: 'Conexão Bluetooth: $label',
      hint: semanticHint,
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: isLoading
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  if (robot.isConnected) {
                    robot.disconnect();
                  } else {
                    robot.connect();
                  }
                },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              widthFactor: 1,
              child: AnimatedContainer(
                duration: disableAnimations
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 14,
                  vertical: compact ? 6 : 8,
                ),
                decoration: BoxDecoration(
                  color: state == RobotConnectionState.connected
                      ? McQueenColors.emerald.withValues(alpha: 0.12)
                      : McQueenColors.surface,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: state == RobotConnectionState.connected
                        ? McQueenColors.emerald.withValues(alpha: 0.5)
                        : (state == RobotConnectionState.error
                            ? McQueenColors.crimsonText.withValues(alpha: 0.55)
                            : McQueenColors.borderStrong),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLoading)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: color,
                        ),
                      )
                    else
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: state == RobotConnectionState.disconnected
                              ? McQueenColors.textMuted
                              : color,
                          boxShadow: state == RobotConnectionState.connected
                              ? [
                                  BoxShadow(
                                    color: McQueenColors.emerald
                                        .withValues(alpha: 0.6),
                                    blurRadius: 6,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    const SizedBox(width: 6),
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 4),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: GoogleFonts.outfit(
                            fontSize: compact ? 11.5 : 12.5,
                            fontWeight: FontWeight.w600,
                            color: state == RobotConnectionState.connected
                                ? McQueenColors.emerald
                                : McQueenColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
