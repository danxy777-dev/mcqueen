// lib/ui/screens/settings/sound_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/ble_constants.dart';
import '../../../core/robot_service.dart';
import '../../../models/sound_item.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/settings_components.dart';

/// Área de Configurações > Sons & Diagnóstico do Buzzer (GPIO 2).
class SoundSettingsScreen extends StatefulWidget {
  final bool embedded;

  const SoundSettingsScreen({super.key, this.embedded = false});

  @override
  State<SoundSettingsScreen> createState() => _SoundSettingsScreenState();
}

class _SoundSettingsScreenState extends State<SoundSettingsScreen> {
  String? _lastFeedbackText;
  bool _lastFeedbackOk = true;
  bool _busy = false;

  Future<void> _executeSound(RobotService robot, SoundItem item) async {
    setState(() {
      _busy = true;
      _lastFeedbackText = null;
    });
    HapticFeedback.selectionClick();
    final res = await robot.playSoundItem(item);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastFeedbackOk = res.ok;
      _lastFeedbackText = res.ok
          ? 'Confirmado pelo ESP32: ${res.response ?? item.command}'
          : (res.error ?? 'Falha ao acionar ${item.title}.');
    });
  }

  Future<void> _toggleSoundsEnabled(RobotService robot, bool enable) async {
    HapticFeedback.lightImpact();
    final res = await robot.updateSettings(
      robot.settings.copyWith(soundsEnabled: enable),
      syncCommand:
          enable ? BleConstants.cmdSomMuteOff : BleConstants.cmdSomMuteOn,
    );
    if (!mounted) return;
    setState(() {
      _lastFeedbackOk = res.ok;
      _lastFeedbackText = res.ok
          ? (enable
              ? 'Sons ativados no ESP32 (${res.response ?? 'OK:SOM:MUTE:0'}).'
              : 'ESP32 silenciado (${res.response ?? 'OK:SOM:MUTE:1'}).')
          : (res.error ?? 'Sem confirmação do ESP32 para mute.');
    });
  }

  Future<void> _toggleBuzzerDriver(RobotService robot, bool activeMode) async {
    HapticFeedback.lightImpact();
    final res = await robot.updateSettings(
      robot.settings.copyWith(activeBuzzerMode: activeMode),
      syncCommand: activeMode
          ? BleConstants.cmdBuzzerAtivo
          : BleConstants.cmdBuzzerPassivo,
    );
    if (!mounted) return;
    setState(() {
      _lastFeedbackOk = res.ok;
      _lastFeedbackText = res.ok
          ? (activeMode
              ? 'Modo Buzzer Ativo DC confirmado (${res.response ?? 'OK:BUZZER:ATIVO'}).'
              : 'Modo Buzzer Passivo confirmado (${res.response ?? 'OK:BUZZER:PASSIVO'}).')
          : (res.error ?? 'Sem confirmação do ESP32 para modo do buzzer.');
    });
  }

  Future<void> _stopAllSounds(RobotService robot) async {
    HapticFeedback.mediumImpact();
    await robot.cancelSoundSequence();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastFeedbackOk = true;
      _lastFeedbackText = 'Buzzer desligado (BUZINA:DESLIGAR).';
    });
  }

  Future<void> _playCustomSequence(RobotService robot) async {
    final s = robot.settings;
    final steps = List<BeepStep>.generate(
      s.customBeepCount,
      (i) => BeepStep(
        s.customBeepDurationMs,
        i + 1 < s.customBeepCount ? s.customBeepGapMs : 0,
      ),
    );
    setState(() {
      _busy = true;
      _lastFeedbackText = null;
    });
    HapticFeedback.mediumImpact();
    final res = await robot.playTimedBeepSequence(
      steps: steps,
      label: 'CUSTOM:${s.customBeepCount}x${s.customBeepDurationMs}ms',
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _lastFeedbackOk = res.ok;
      _lastFeedbackText = res.ok
          ? 'Sequência personalizada concluída (${s.customBeepCount} bipes de ${s.customBeepDurationMs} ms).'
          : (res.error ?? 'Sequência não concluída.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final settings = robot.settings;
    final isConnected = robot.isConnected;
    final canPlay = isConnected && settings.soundsEnabled;

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Diagnóstico real do hardware
        const McQueenNoticeBanner(
          icon: Icons.info_outline_rounded,
          title: 'Buzzer Ativo (2 terminais · GPIO 2)',
          message:
              'O McQueen utiliza um buzzer ativo com oscilador interno fixo. Buzinas, bipes curtos, alertas e sequências rítmicas com pausas amplas funcionam diretamente. Melodias musicais com variação de notas (Hz) exigem troca física para um buzzer passivo.',
          color: McQueenColors.cyan,
        ),
        const SizedBox(height: 14),

        // Controle geral + Teste da Buzina + Estado de confirmação
        McQueenSectionCard(
          title: 'Configuração & Teste Rápido',
          subtitle: robot.buzinaSent
              ? 'Ativo agora: ${robot.activeSoundLabel ?? "BUZINA"}'
              : 'Confirmação real via notificações do ESP32',
          icon: Icons.volume_up_rounded,
          accentColor: McQueenColors.amber,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: (settings.soundsEnabled
                      ? McQueenColors.emerald
                      : McQueenColors.crimson)
                  .withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              settings.soundsEnabled ? 'Ativado' : 'Mudo',
              style: GoogleFonts.outfit(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: settings.soundsEnabled
                    ? McQueenColors.emerald
                    : McQueenColors.crimson,
              ),
            ),
          ),
          children: [
            McQueenSwitchTile(
              title: 'Sons Habilitados no ESP32',
              subtitle: 'Envia SOM:MUTE:0 ou SOM:MUTE:1 (salvo na NVS)',
              value: settings.soundsEnabled,
              accentColor: McQueenColors.emerald,
              onChanged:
                  isConnected ? (val) => _toggleSoundsEnabled(robot, val) : null,
            ),
            const Divider(height: 18),
            McQueenSwitchTile(
              title: 'Driver Buzzer Ativo (Pulso DC)',
              subtitle:
                  'Recomendado para o buzzer ativo atual no GPIO 2. Desligar envia onda quadrada (somente buzzer passivo).',
              value: settings.activeBuzzerMode,
              accentColor: McQueenColors.cyan,
              onChanged:
                  isConnected ? (val) => _toggleBuzzerDriver(robot, val) : null,
            ),
            if (!settings.activeBuzzerMode) ...[
              const SizedBox(height: 8),
              const McQueenNoticeBanner(
                icon: Icons.warning_amber_rounded,
                title: 'Modo Passivo selecionado em hardware Ativo',
                message:
                    'Com buzzer ativo no GPIO 2, o modo Passivo (onda quadrada) pode deixar o som fraco, falho ou mudo. Mantenha "Driver Buzzer Ativo" ligado.',
                color: McQueenColors.amber,
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: McQueenColors.amber,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                    onPressed: canPlay && !_busy
                        ? () => _executeSound(robot, SoundItem.catalog.first)
                        : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.campaign_rounded, size: 19),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Testar Buzina',
                              maxLines: 1,
                              style: GoogleFonts.outfit(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: McQueenColors.crimson,
                      side: BorderSide(
                        color: McQueenColors.crimson.withValues(alpha: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 13,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(13),
                      ),
                    ),
                    onPressed: isConnected
                        ? () => _stopAllSounds(robot)
                        : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.stop_rounded, size: 19),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Parar Som',
                              maxLines: 1,
                              style: GoogleFonts.outfit(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
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
            if (_lastFeedbackText != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: (_lastFeedbackOk
                          ? McQueenColors.emerald
                          : McQueenColors.crimson)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (_lastFeedbackOk
                            ? McQueenColors.emerald
                            : McQueenColors.crimson)
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  _lastFeedbackText!,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    color: _lastFeedbackOk
                        ? McQueenColors.emerald
                        : McQueenColors.crimson,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),

        // Sequenciador Personalizado de Bipes (TONE:2000:<ms> com pausas limpas)
        McQueenSectionCard(
          title: 'Efeito Personalizado (Padrão de Bipes)',
          subtitle:
              'Gera pulsos reais no GPIO 2 via TONE:2000:<ms> com pausas limpas',
          icon: Icons.tune_rounded,
          accentColor: McQueenColors.cyan,
          children: [
            McQueenSliderTile(
              label: 'Duração do Pulso',
              value: settings.customBeepDurationMs.toDouble(),
              min: 40,
              max: 500,
              divisions: 46,
              valueText: '${settings.customBeepDurationMs} ms',
              accentColor: McQueenColors.cyan,
              onChanged: (v) {
                robot.updateSettings(
                  settings.copyWith(customBeepDurationMs: v.round()),
                  persist: false,
                );
              },
              onChangeEnd: (v) {
                robot.updateSettings(
                  settings.copyWith(customBeepDurationMs: v.round()),
                  persist: true,
                );
              },
            ),
            McQueenSliderTile(
              label: 'Quantidade de Bipes',
              value: settings.customBeepCount.toDouble(),
              min: 1,
              max: 8,
              divisions: 7,
              valueText: '${settings.customBeepCount}×',
              accentColor: McQueenColors.emerald,
              onChanged: (v) {
                robot.updateSettings(
                  settings.copyWith(customBeepCount: v.round()),
                  persist: false,
                );
              },
              onChangeEnd: (v) {
                robot.updateSettings(
                  settings.copyWith(customBeepCount: v.round()),
                  persist: true,
                );
              },
            ),
            McQueenSliderTile(
              label: 'Intervalo entre Bipes',
              value: settings.customBeepGapMs.toDouble(),
              min: 100,
              max: 500,
              divisions: 40,
              valueText: '${settings.customBeepGapMs} ms',
              accentColor: McQueenColors.amber,
              onChanged: (v) {
                robot.updateSettings(
                  settings.copyWith(customBeepGapMs: v.round()),
                  persist: false,
                );
              },
              onChangeEnd: (v) {
                robot.updateSettings(
                  settings.copyWith(customBeepGapMs: v.round()),
                  persist: true,
                );
              },
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: McQueenColors.cyan,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
                onPressed: canPlay && !robot.isSoundSequenceRunning
                    ? () => _playCustomSequence(robot)
                    : null,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.play_arrow_rounded, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          robot.isSoundSequenceRunning
                              ? 'Reproduzindo Sequência...'
                              : 'Disparar Sequência Personalizada',
                          maxLines: 1,
                          style: GoogleFonts.outfit(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
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
        const SizedBox(height: 14),

        // Categorias do catálogo real
        for (final category in SoundCategory.values) ...[
          _buildCategoryCard(
            category: category,
            items: SoundItem.byCategory(category),
            robot: robot,
            canPlay: canPlay,
          ),
          const SizedBox(height: 14),
        ],

        // Diagnóstico técnico de buzzer & requisitos para melodias
        McQueenSectionCard(
          title: 'Diagnóstico Técnico & Melodias',
          subtitle: 'Por que melodias musicais não tocam notas no buzzer atual',
          icon: Icons.build_circle_outlined,
          accentColor: McQueenColors.violet,
          children: [
            McQueenInfoRow(
              label: 'Hardware instalado',
              value: 'Buzzer ativo 2 pinos (GPIO 2 / A2)',
            ),
            McQueenInfoRow(
              label: 'Modo ativo no app',
              value: settings.activeBuzzerMode ? 'Ativo (DC HIGH)' : 'Passivo (Onda)',
            ),
            McQueenInfoRow(
              label: 'Canal TX (confirmação)',
              value: robot.diagnostics.txNotifyEnabled
                  ? 'Ativo'
                  : (isConnected ? 'Inativo' : 'Desconectado'),
            ),
            const SizedBox(height: 8),
            Text(
              'O que falta para reproduzir músicas/melodias reais:\n'
              '• Hardware: substituir o buzzer ativo por um buzzer passivo (piezo sem oscilador interno).\n'
              '• Configuração/Firmware: alternar para modo BUZZER:PASSIVO (já suportado no firmware v4.2.0 via esp_timer, ou aprimorá-lo com LEDC/tone() dedicado para maior estabilidade).',
              style: GoogleFonts.outfit(
                fontSize: 12,
                color: McQueenColors.textSecondary,
                height: 1.45,
              ),
            ),
          ],
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Sons & Buzzer')),
      body: SafeArea(child: body),
    );
  }

  Widget _buildCategoryCard({
    required SoundCategory category,
    required List<SoundItem> items,
    required RobotService robot,
    required bool canPlay,
  }) {
    final isPassiveCategory = category == SoundCategory.melodiasPassivas;
    final isFirmwareEffectsCategory = category == SoundCategory.efeitosFirmware;
    final activePassiveHardware = !robot.settings.activeBuzzerMode;

    return McQueenSectionCard(
      title: category.label,
      subtitle: category.subtitle,
      icon: category.icon,
      accentColor: category.accentColor,
      children: [
        if (isFirmwareEffectsCategory) ...[
          const McQueenNoticeBanner(
            icon: Icons.info_outline_rounded,
            title: 'Limitação no Buzzer Ativo (GPIO 2)',
            message:
                'Os comandos SOM:* têm pausas curtas (20–45 ms) e tons musicais no firmware. No buzzer ativo atual, tocam sempre em frequência única e efeitos rápidos (INIT, SURPRESA, ARCADE, FUTURISTA) podem soar contínuos.',
            color: McQueenColors.emerald,
          ),
          const SizedBox(height: 10),
        ],
        if (isPassiveCategory && !activePassiveHardware) ...[
          const McQueenNoticeBanner(
            icon: Icons.music_off_rounded,
            title: 'Notas musicais indisponíveis no buzzer ativo',
            message:
                'No hardware atual (buzzer ativo GPIO 2), estes comandos executam apenas pulsos rítmicos monotônicos sem variação de notas musicais. Requer troca física para buzzer passivo.',
            color: McQueenColors.violet,
          ),
          const SizedBox(height: 10),
        ],
        ...items.map((item) {
          final isPlaying =
              robot.buzinaSent && item.matchesActiveLabel(robot.activeSoundLabel);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: canPlay && !_busy
                    ? () => _executeSound(robot, item)
                    : null,
                child: AnimatedOpacity(
                  opacity: canPlay ? 1.0 : 0.45,
                  duration: const Duration(milliseconds: 160),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isPlaying
                          ? item.color.withValues(alpha: 0.16)
                          : McQueenColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isPlaying
                            ? item.color
                            : McQueenColors.borderSubtle,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(9),
                          decoration: BoxDecoration(
                            color: item.color.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Icon(item.icon, size: 19, color: item.color),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.title,
                                style: GoogleFonts.outfit(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: McQueenColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                item.subtitle,
                                style: GoogleFonts.outfit(
                                  fontSize: 11,
                                  color: McQueenColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          isPlaying
                              ? Icons.graphic_eq_rounded
                              : Icons.play_arrow_rounded,
                          color: canPlay ? item.color : McQueenColors.textMuted,
                          size: 22,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    );
  }
}
