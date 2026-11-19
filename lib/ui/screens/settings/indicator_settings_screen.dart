// lib/ui/screens/settings/indicator_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/robot_service.dart';
import '../../../models/turn_signal_state.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/settings_components.dart';
import '../../widgets/turn_signals_section.dart';

/// Área de Configurações > Indicadores (Setas Esquerda/Direita e Pisca-Alerta).
class IndicatorSettingsScreen extends StatelessWidget {
  final bool embedded;

  const IndicatorSettingsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final signal = robot.isConnected ? robot.turnSignal : TurnSignalState.off;

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        McQueenSectionCard(
          title: 'Setas Direcionais & Pisca-Alerta',
          subtitle: 'LEDs físicos em GPIO 7 (Esquerda) e GPIO 9 (Direita)',
          icon: Icons.compare_arrows_rounded,
          accentColor: McQueenColors.amber,
          children: const [
            TurnSignalsSection(),
          ],
        ),
        const SizedBox(height: 14),
        McQueenSectionCard(
          title: 'Estado Atual dos Indicadores',
          subtitle: 'Sincronizado com respostas TX do firmware ESP32-C3',
          icon: Icons.lightbulb_outline_rounded,
          accentColor: McQueenColors.cyan,
          children: [
            McQueenInfoRow(
              label: 'Modo ativo',
              value: robot.isConnected ? signal.label : 'Desconectado',
              valueColor: robot.isConnected && signal.isActive
                  ? signal.accentColor
                  : McQueenColors.textSecondary,
            ),
            McQueenInfoRow(
              label: 'Código de protocolo',
              value: signal.command,
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'Seta Esquerda (GPIO 7)',
              value: signal == TurnSignalState.auto
                  ? 'Automática nas curvas'
                  : (signal.isLeftBlinking ? 'Piscando (500 ms)' : 'Apagada'),
            ),
            McQueenInfoRow(
              label: 'Seta Direita (GPIO 9)',
              value: signal == TurnSignalState.auto
                  ? 'Automática nas curvas'
                  : (signal.isRightBlinking ? 'Piscando (500 ms)' : 'Apagada'),
            ),
            const SizedBox(height: 8),
            Text(
              'Nota de hardware (Adafruit QT Py ESP32-C3): GPIO 7 (MO) é seguro na barra lateral. GPIO 9 corresponde ao botão BOOT (strapping de inicialização, ausente na barra lateral padrão); caso deseje migrar a fiação da seta direita no futuro, recomenda-se SCK (GPIO 10). O modo Automático (SETA:AUTO) sincroniza com curvas do gamepad e do joystick proporcional.',
              style: GoogleFonts.outfit(
                fontSize: 11.5,
                color: McQueenColors.textMuted,
                height: 1.35,
              ),
            ),
          ],
        ),
      ],
    );

    if (embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Indicadores')),
      body: SafeArea(child: body),
    );
  }
}
