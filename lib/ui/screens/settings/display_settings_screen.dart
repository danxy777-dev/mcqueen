// lib/ui/screens/settings/display_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/ble_constants.dart';
import '../../../core/robot_service.dart';
import '../../../models/robot_expression.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/oled_face_preview.dart';
import '../../widgets/settings_components.dart';

/// Área de Configurações > Display OLED 128×64 (I2C GPIO 5/6).
class DisplaySettingsScreen extends StatelessWidget {
  final bool embedded;

  const DisplaySettingsScreen({super.key, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final settings = robot.settings;
    final currentExpr = robot.currentExpression;
    final isConnected = robot.isConnected;

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!isConnected) ...[
          const McQueenNoticeBanner(
            icon: Icons.bluetooth_disabled_rounded,
            title: 'Prévia local (desconectado)',
            message:
                'As expressões abaixo atualizam a prévia local do OLED. Conecte ao McQueen via BLE para enviar ao display físico e configurar reações automáticas.',
            color: McQueenColors.cyan,
          ),
          const SizedBox(height: 12),
        ],
        // Pré-visualização OLED + teste de comunicação
        McQueenSectionCard(
          title: 'Prévia OLED 128×64',
          subtitle: 'SSD1306 I2C (0x3C · SDA GPIO 5 · SCL GPIO 6)',
          icon: Icons.tv_rounded,
          accentColor: McQueenColors.pink,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: currentExpr.accentColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              currentExpr.code,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                color: currentExpr.accentColor,
              ),
            ),
          ),
          children: [
            OledFacePreview(
              expression: currentExpr,
              direction: robot.motorState.direction,
              speedPercent: robot.speedPercent,
              isConnected: isConnected,
              height: 124,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentExpr.label,
                        style: GoogleFonts.outfit(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: McQueenColors.textPrimary,
                        ),
                      ),
                      Text(
                        currentExpr.subtitle,
                        style: GoogleFonts.outfit(
                          fontSize: 11.5,
                          color: McQueenColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: isConnected
                      ? () {
                          HapticFeedback.lightImpact();
                          robot.setExpression(currentExpr);
                        }
                      : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: McQueenColors.cyan,
                    side: BorderSide(
                      color: McQueenColors.cyan.withValues(alpha: 0.45),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.sync_rounded, size: 16),
                  label: Text(
                    'Testar OLED',
                    style: GoogleFonts.outfit(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Expressões faciais
        McQueenSectionCard(
          title: 'Expressões Faciais',
          subtitle: 'Toque para enviar ao display; toque longo ativa/desativa na rotação automática',
          icon: Icons.face_retouching_natural_rounded,
          accentColor: McQueenColors.cyan,
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 150,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.15,
              ),
              itemCount: RobotExpression.values.length,
              itemBuilder: (context, index) {
                final expr = RobotExpression.values[index];
                final isSelected = expr == currentExpr;
                final isFav = settings.favoriteExpressions.contains(expr);

                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      robot.setExpression(expr);
                    },
                    onLongPress: isConnected
                        ? () {
                            HapticFeedback.mediumImpact();
                            final updated = Set<RobotExpression>.from(
                                settings.favoriteExpressions);
                            if (updated.contains(expr) && updated.length > 1) {
                              updated.remove(expr);
                            } else {
                              updated.add(expr);
                            }
                            final next =
                                settings.copyWith(favoriteExpressions: updated);
                            robot.updateSettings(
                              next,
                              syncCommand: BleConstants.cmdAutoMask(
                                next.favoriteExpressionsMask,
                              ),
                            );
                          }
                        : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? expr.accentColor.withValues(alpha: 0.16)
                            : McQueenColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected
                              ? expr.accentColor
                              : McQueenColors.borderSubtle,
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(expr.icon, size: 19, color: expr.accentColor),
                              const Spacer(),
                              Icon(
                                isFav
                                    ? Icons.star_rounded
                                    : Icons.star_border_rounded,
                                size: 14,
                                color: isFav
                                    ? McQueenColors.amber
                                    : McQueenColors.textMuted,
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            expr.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.outfit(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: isSelected
                                  ? McQueenColors.textPrimary
                                  : McQueenColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Animações automáticas (Idle)
        McQueenSectionCard(
          title: 'Reações & Animações Automáticas',
          subtitle: 'Comportamento autônomo quando o robô está parado',
          icon: Icons.auto_awesome_rounded,
          accentColor: McQueenColors.emerald,
          children: [
            McQueenSwitchTile(
              title: 'Vida Própria (Idle)',
              subtitle:
                  'Alterna expressões curiosas, piscadas e modo sonolento em repouso',
              value: settings.autoReactionsEnabled,
              accentColor: McQueenColors.emerald,
              onChanged: isConnected
                  ? (val) {
                      HapticFeedback.lightImpact();
                      robot.updateSettings(
                        settings.copyWith(autoReactionsEnabled: val),
                        syncCommand: val
                            ? BleConstants.cmdAutoOn
                            : BleConstants.cmdAutoOff,
                      );
                    }
                  : null,
            ),
            const Divider(height: 16),
            McQueenSliderTile(
              label: 'Intervalo entre Reações',
              value: settings.reactionIntervalSeconds.toDouble(),
              min: 4,
              max: 45,
              divisions: 41,
              valueText: '${settings.reactionIntervalSeconds} s',
              accentColor: McQueenColors.cyan,
              onChanged: isConnected && settings.autoReactionsEnabled
                  ? (v) {
                      robot.updateSettings(
                        settings.copyWith(reactionIntervalSeconds: v.round()),
                        persist: false,
                      );
                    }
                  : null,
              onChangeEnd: isConnected && settings.autoReactionsEnabled
                  ? (v) {
                      robot.updateSettings(
                        settings.copyWith(reactionIntervalSeconds: v.round()),
                        syncCommand: BleConstants.cmdAutoFreq(v.round()),
                      );
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              'Limitações do firmware: STATUS sincroniza se o modo automático está ativo, mas o ESP32 não informa pelo BLE o intervalo nem a máscara atual (e AUTO:MASK não persiste após reiniciar a placa).',
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
      appBar: AppBar(title: const Text('Display OLED')),
      body: SafeArea(child: body),
    );
  }
}
