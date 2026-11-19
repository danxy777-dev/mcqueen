// lib/ui/screens/settings/settings_hub_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/robot_service.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/settings_components.dart';
import 'connection_settings_screen.dart';
import 'diagnostics_settings_screen.dart';
import 'display_settings_screen.dart';
import 'indicator_settings_screen.dart';
import 'motor_settings_screen.dart';
import 'sound_settings_screen.dart';

enum SettingsCategory {
  connection(
    title: 'Conexão',
    description: 'Estado BLE, conectar/desconectar, PING e diagnóstico do enlace',
    icon: Icons.bluetooth_rounded,
    accent: McQueenColors.cyan,
  ),
  motors(
    title: 'Motores',
    description: 'Calibração de neutro, inversão, limites de velocidade e testes',
    icon: Icons.precision_manufacturing_rounded,
    accent: McQueenColors.crimson,
  ),
  sounds(
    title: 'Sons',
    description: 'Buzina, bipes, sequências, efeitos compatíveis e buzzer GPIO 2',
    icon: Icons.volume_up_rounded,
    accent: McQueenColors.amber,
  ),
  display(
    title: 'Display OLED',
    description: 'Prévia 128×64, expressões faciais e reações automáticas',
    icon: Icons.tv_rounded,
    accent: McQueenColors.pink,
  ),
  indicators(
    title: 'Indicadores',
    description: 'Setas esquerda/direita, pisca-alerta e modo automático',
    icon: Icons.compare_arrows_rounded,
    accent: McQueenColors.orange,
  ),
  diagnostics(
    title: 'Diagnóstico',
    description: 'Logs BLE TX/RX, últimos comandos, respostas e estado GATT',
    icon: Icons.terminal_rounded,
    accent: McQueenColors.emerald,
  );

  final String title;
  final String description;
  final IconData icon;
  final Color accent;

  const SettingsCategory({
    required this.title,
    required this.description,
    required this.icon,
    required this.accent,
  });
}

/// Hub centralizado das Configurações do McQueen.
/// Organiza toda a área técnica separada da tela de condução.
class SettingsHubScreen extends StatefulWidget {
  const SettingsHubScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const SettingsHubScreen(),
      ),
    );
  }

  @override
  State<SettingsHubScreen> createState() => _SettingsHubScreenState();
}

class _SettingsHubScreenState extends State<SettingsHubScreen> {
  SettingsCategory _selected = SettingsCategory.connection;

  Widget _buildDetailScreen(SettingsCategory category, {required bool embedded}) {
    switch (category) {
      case SettingsCategory.connection:
        return ConnectionSettingsScreen(embedded: embedded);
      case SettingsCategory.motors:
        return MotorSettingsScreen(embedded: embedded);
      case SettingsCategory.sounds:
        return SoundSettingsScreen(embedded: embedded);
      case SettingsCategory.display:
        return DisplaySettingsScreen(embedded: embedded);
      case SettingsCategory.indicators:
        return IndicatorSettingsScreen(embedded: embedded);
      case SettingsCategory.diagnostics:
        return DiagnosticsSettingsScreen(embedded: embedded);
    }
  }

  String _summaryFor(SettingsCategory category, RobotService robot) {
    switch (category) {
      case SettingsCategory.connection:
        return robot.isConnected
            ? '${robot.diagnostics.deviceName ?? "McQueen"} · ${robot.rssi != 0 ? "${robot.rssi} dBm" : "Conectado"}'
            : robot.connectionState.label;
      case SettingsCategory.motors:
        return '${robot.currentSpeed.label} (${robot.speedPercent}%) · Trim ${robot.settings.leftTrimPercent}/${robot.settings.rightTrimPercent}';
      case SettingsCategory.sounds:
        return robot.settings.soundsEnabled
            ? (robot.settings.activeBuzzerMode ? 'Buzzer Ativo DC' : 'Modo Passivo')
            : 'Silenciado';
      case SettingsCategory.display:
        return '${robot.currentExpression.label} · Auto ${robot.settings.autoReactionsEnabled ? "ON" : "OFF"}';
      case SettingsCategory.indicators:
        return robot.isConnected ? robot.turnSignal.label : 'Desconectado';
      case SettingsCategory.diagnostics:
        return '${robot.commandLogs.length} registro(s)';
    }
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Configurações',
          style: GoogleFonts.outfit(
            fontSize: 19,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;
            if (isWide) {
              return Row(
                children: [
                  SizedBox(
                    width: 310,
                    child: _buildCategoryList(
                      context,
                      robot,
                      isWide: true,
                    ),
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: _buildDetailScreen(_selected, embedded: true),
                  ),
                ],
              );
            }
            return _buildCategoryList(context, robot, isWide: false);
          },
        ),
      ),
    );
  }

  Widget _buildCategoryList(
    BuildContext context,
    RobotService robot, {
    required bool isWide,
  }) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final cat in SettingsCategory.values) ...[
          _SettingsCategoryTile(
            category: cat,
            summary: _summaryFor(cat, robot),
            selected: isWide && _selected == cat,
            onTap: () {
              HapticFeedback.selectionClick();
              if (isWide) {
                setState(() => _selected = cat);
              } else {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _buildDetailScreen(cat, embedded: false),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 10),
        ],
        const SizedBox(height: 6),
        McQueenSectionCard(
          title: 'Hardware & Sistema',
          subtitle: 'Especificações do controlador McQueen ESP32-C3',
          icon: Icons.developer_board_rounded,
          accentColor: McQueenColors.textSecondary,
          children: [
            const McQueenInfoRow(
              label: 'Placa',
              value: 'Adafruit QT Py ESP32-C3',
            ),
            const McQueenInfoRow(
              label: 'Motores',
              value: '2× Servos MG990S (GPIO 3 / GPIO 0)',
            ),
            const McQueenInfoRow(
              label: 'Buzzer',
              value: 'Buzzer Ativo 2 terminais (GPIO 2)',
            ),
            const McQueenInfoRow(
              label: 'Display OLED',
              value: 'SSD1306 128×64 I2C (GPIO 5 / GPIO 6)',
            ),
            const McQueenInfoRow(
              label: 'Indicadores',
              value: 'Setas LED (GPIO 7 / GPIO 9)',
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: McQueenColors.crimson,
                  side: BorderSide(
                    color: McQueenColors.crimson.withValues(alpha: 0.4),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _confirmFullReset(context, robot),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.restore_rounded, size: 17),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Resetar Todas as Configurações',
                          maxLines: 1,
                          style: GoogleFonts.outfit(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _confirmFullReset(BuildContext context, RobotService robot) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Resetar tudo?'),
        content: const Text(
          'Esta ação restaura calibração, velocidade padrão, expressões e preferências sonoras para o padrão de fábrica.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: McQueenColors.crimson,
            ),
            onPressed: () async {
              Navigator.of(dialogCtx).pop();
              await robot.resetAllSettings();
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(
                      robot.isConnected
                          ? 'Configurações restauradas e sincronizadas com o McQueen.'
                          : 'Preferências locais restauradas para o padrão de fábrica.',
                    ),
                  ),
                );
              }
            },
            child: const Text('Confirmar Reset'),
          ),
        ],
      ),
    );
  }
}

class _SettingsCategoryTile extends StatelessWidget {
  final SettingsCategory category;
  final String summary;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsCategoryTile({
    required this.category,
    required this.summary,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? category.accent.withValues(alpha: 0.14)
                : McQueenColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? category.accent.withValues(alpha: 0.65)
                  : McQueenColors.borderSubtle,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: category.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(category.icon, size: 21, color: category.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            category.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: McQueenColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            summary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                            style: GoogleFonts.outfit(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: category.accent,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      category.description,
                      style: GoogleFonts.outfit(
                        fontSize: 12,
                        color: McQueenColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                color: McQueenColors.textMuted,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
