// lib/models/sound_item.dart
import 'package:flutter/material.dart';

/// Passo individual de uma sequência rítmica de bipes para buzzer ativo DC.
class BeepStep {
  /// Duração do pulso HIGH no GPIO 2 em milissegundos (20..3000 ms).
  final int onMs;

  /// Intervalo silencioso após o pulso até o próximo passo em ms.
  final int gapMs;

  const BeepStep(this.onMs, [this.gapMs = 0]);
}

/// Categorias sonoras alinhadas às capacidades reais do buzzer ativo (GPIO 2).
enum SoundCategory {
  buzinasBipes(
    label: 'Buzinas & Bipes',
    subtitle: 'Acionamento direto DC no GPIO 2 (funciona 100% no buzzer ativo)',
    icon: Icons.campaign_rounded,
    accentColor: Color(0xFFF59E0B),
  ),
  sequencias(
    label: 'Sequências Limpas',
    subtitle: 'Padrões temporizados com pausas amplas para buzzer ativo',
    icon: Icons.graphic_eq_rounded,
    accentColor: Color(0xFF38BDF8),
  ),
  efeitosFirmware(
    label: 'Efeitos do Firmware (Limitação Tonal)',
    subtitle: 'Comandos SOM:* do ESP32 — no buzzer ativo tocam em tom único e pausas curtas podem soar contínuas',
    icon: Icons.memory_rounded,
    accentColor: Color(0xFF22C55E),
  ),
  melodiasPassivas(
    label: 'Melodias (Requer Buzzer Passivo)',
    subtitle: 'Incompatível com variação musical no buzzer ativo atual (GPIO 2)',
    icon: Icons.music_note_rounded,
    accentColor: Color(0xFFA855F7),
  );

  final String label;
  final String subtitle;
  final IconData icon;
  final Color accentColor;

  const SoundCategory({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
  });
}

/// Representa um comando sonoro real ou sequência compatível com o firmware McQueen.
class SoundItem {
  final String id;
  final String title;
  final String subtitle;
  final String command;
  final SoundCategory category;
  final IconData icon;
  final Color color;

  /// Quando preenchido, executa sequência real usando `TONE:2000:<onMs>` com pausas
  /// espaçadas (>= 130 ms) para soar nítida no buzzer ativo de 2 terminais.
  final List<BeepStep>? beepSequence;

  /// Indica que o efeito depende de variação de frequência (buzzer passivo) para
  /// soar como melodia musical verdadeira.
  final bool requiresPassiveBuzzer;

  const SoundItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.command,
    required this.category,
    required this.icon,
    required this.color,
    this.beepSequence,
    this.requiresPassiveBuzzer = false,
  });

  bool get isAppSequenced => beepSequence != null && beepSequence!.isNotEmpty;

  /// Verifica se o rótulo sonoro ativo corresponde a este item.
  bool matchesActiveLabel(String? activeLabel) {
    if (activeLabel == null || activeLabel.isEmpty) return false;
    final norm = activeLabel.trim().toUpperCase();
    return norm == command.toUpperCase() || norm == id.toUpperCase();
  }

  static const List<SoundItem> catalog = [
    // ── BUZINAS & BIPES DIRETOS (100% compatíveis com Buzzer Ativo DC) ───────
    SoundItem(
      id: 'buz_principal',
      title: 'Buzina Normal',
      subtitle: 'Toque duplo automotivo (190 ms + pausa + 240 ms)',
      command: 'BUZINA',
      category: SoundCategory.buzinasBipes,
      icon: Icons.campaign_rounded,
      color: Color(0xFFF59E0B),
    ),
    SoundItem(
      id: 'bipe_curto',
      title: 'Bipe Curto',
      subtitle: 'Pulso rápido único de 110 ms (BIPE)',
      command: 'BIPE',
      category: SoundCategory.buzinasBipes,
      icon: Icons.notifications_active_rounded,
      color: Color(0xFF38BDF8),
    ),
    SoundItem(
      id: 'buz_curta',
      title: 'Buzina Curta',
      subtitle: 'Aviso rápido amigável de 110 ms (BUZINA:CURTA)',
      command: 'BUZINA:CURTA',
      category: SoundCategory.buzinasBipes,
      icon: Icons.touch_app_rounded,
      color: Color(0xFF38BDF8),
    ),
    SoundItem(
      id: 'buz_longa',
      title: 'Buzina Longa',
      subtitle: 'Sinal contínuo de passagem de 520 ms (BUZINA:LONGA)',
      command: 'BUZINA:LONGA',
      category: SoundCategory.buzinasBipes,
      icon: Icons.volume_up_rounded,
      color: Color(0xFFF97316),
    ),
    SoundItem(
      id: 'buz_emerg',
      title: 'Buzina de Emergência',
      subtitle: 'Sequência rápida de 5 pulsos de alerta (BUZINA:EMERGENCIA)',
      command: 'BUZINA:EMERGENCIA',
      category: SoundCategory.buzinasBipes,
      icon: Icons.warning_amber_rounded,
      color: Color(0xFFE63946),
    ),

    // ── SEQUÊNCIAS LIMPAS (Espaçadas para soar nítidas no Buzzer Ativo) ──────
    SoundItem(
      id: 'seq_confirmacao',
      title: 'Confirmação (Duplo Bipe)',
      subtitle: 'Dois bipes curtos nítidos (90 ms + 160 ms + 130 ms)',
      command: 'SEQ:CONFIRMACAO',
      category: SoundCategory.sequencias,
      icon: Icons.check_circle_outline_rounded,
      color: Color(0xFF22C55E),
      beepSequence: [
        BeepStep(90, 160),
        BeepStep(130, 0),
      ],
    ),
    SoundItem(
      id: 'seq_inicializacao',
      title: 'Inicialização Limpa',
      subtitle: 'Ignição progressiva em 3 pulsos crescentes (90 → 140 → 260 ms)',
      command: 'SEQ:INICIALIZACAO',
      category: SoundCategory.sequencias,
      icon: Icons.power_settings_new_rounded,
      color: Color(0xFF38BDF8),
      beepSequence: [
        BeepStep(90, 150),
        BeepStep(140, 150),
        BeepStep(260, 0),
      ],
    ),
    SoundItem(
      id: 'seq_alerta_triplo',
      title: 'Alerta Triplo',
      subtitle: 'Três pulsos firmes de atenção com pausa clara (140 ms × 3)',
      command: 'SEQ:ALERTA_TRIPLO',
      category: SoundCategory.sequencias,
      icon: Icons.notification_important_rounded,
      color: Color(0xFFF97316),
      beepSequence: [
        BeepStep(140, 150),
        BeepStep(140, 150),
        BeepStep(140, 0),
      ],
    ),
    SoundItem(
      id: 'seq_erro',
      title: 'Aviso de Falha',
      subtitle: 'Pulso curto seguido de pulso grave longo (90 ms + 320 ms)',
      command: 'SEQ:FALHA',
      category: SoundCategory.sequencias,
      icon: Icons.error_outline_rounded,
      color: Color(0xFFE63946),
      beepSequence: [
        BeepStep(90, 170),
        BeepStep(320, 0),
      ],
    ),
    SoundItem(
      id: 'seq_sos',
      title: 'Sinal S.O.S. (Morse)',
      subtitle: 'Padrão clássico 3 curtos, 3 longos, 3 curtos no GPIO 2',
      command: 'SEQ:SOS',
      category: SoundCategory.sequencias,
      icon: Icons.sos_rounded,
      color: Color(0xFFE63946),
      beepSequence: [
        BeepStep(90, 140),
        BeepStep(90, 140),
        BeepStep(90, 220),
        BeepStep(260, 140),
        BeepStep(260, 140),
        BeepStep(260, 220),
        BeepStep(90, 140),
        BeepStep(90, 140),
        BeepStep(90, 0),
      ],
    ),

    // ── EFEITOS NATIVOS DO FIRMWARE (SOM:*) ──────────────────────────────────
    SoundItem(
      id: 'som_init',
      title: 'Inicialização (Firmware)',
      subtitle: 'SOM:INIT — 4 notas (pausas de 30 ms; sem variação tonal no ativo)',
      command: 'SOM:INIT',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.rocket_launch_rounded,
      color: Color(0xFF22C55E),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'som_ble_conn',
      title: 'Confirmação BLE',
      subtitle: 'SOM:BLE_CONN — 2 pulsos de conexão (no ativo soa em tom único)',
      command: 'SOM:BLE_CONN',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.bluetooth_connected_rounded,
      color: Color(0xFF38BDF8),
    ),
    SoundItem(
      id: 'som_ble_disc',
      title: 'Desconexão BLE',
      subtitle: 'SOM:BLE_DISC — 2 pulsos de desconexão (no ativo soa em tom único)',
      command: 'SOM:BLE_DISC',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.bluetooth_disabled_rounded,
      color: Color(0xFF94A3B8),
    ),
    SoundItem(
      id: 'som_comemoracao',
      title: 'Comemoração',
      subtitle: 'SOM:COMEMORACAO — Fanfarra (pausas 30 ms; + rosto Feliz no OLED)',
      command: 'SOM:COMEMORACAO',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.emoji_events_rounded,
      color: Color(0xFFFBBF24),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'som_erro',
      title: 'Erro / Obstáculo',
      subtitle: 'SOM:ERRO — Duplo pulso longo (60 ms pausa; + Triste no OLED)',
      command: 'SOM:ERRO',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.report_problem_rounded,
      color: Color(0xFFE63946),
    ),
    SoundItem(
      id: 'som_surpresa',
      title: 'Surpresa',
      subtitle: 'SOM:SURPRESA — Pausas de 20 ms (requer passivo; + Surpreso no OLED)',
      command: 'SOM:SURPRESA',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.bolt_rounded,
      color: Color(0xFFF59E0B),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'som_risada',
      title: 'Risada Robótica',
      subtitle: 'SOM:RISADA — 5 pulsos cadenciados (+ Piscando no OLED)',
      command: 'SOM:RISADA',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.sentiment_very_satisfied_rounded,
      color: Color(0xFF14B8A6),
    ),
    SoundItem(
      id: 'som_arcade',
      title: 'Arcade',
      subtitle: 'SOM:ARCADE — Pausa de 20 ms + salto tonal (requer buzzer passivo)',
      command: 'SOM:ARCADE',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.videogame_asset_rounded,
      color: Color(0xFFA855F7),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'som_futurista',
      title: 'Scanner Futurista',
      subtitle: 'SOM:FUTURISTA — Pausas de 20 ms (requer passivo; + Curioso no OLED)',
      command: 'SOM:FUTURISTA',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.radar_rounded,
      color: Color(0xFF06B6D4),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'buz_div',
      title: 'Buzina de Corrida',
      subtitle: 'SOM:BUZ_DIV — Cadência rítmica de 7 pulsos (+ Animado no OLED)',
      command: 'SOM:BUZ_DIV',
      category: SoundCategory.efeitosFirmware,
      icon: Icons.flag_rounded,
      color: Color(0xFF22C55E),
    ),

    // ── MELODIAS (SOMENTE PARA HARDWARE COM BUZZER PASSIVO) ──────────────────
    SoundItem(
      id: 'melodia_init',
      title: 'Melodia de Largada',
      subtitle: 'MELODIA:INIT (7 notas) — No buzzer ativo toca sem variação de tom',
      command: 'MELODIA:INIT',
      category: SoundCategory.melodiasPassivas,
      icon: Icons.music_note_rounded,
      color: Color(0xFFA855F7),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'melodia_comemoracao',
      title: 'Melodia Festiva',
      subtitle: 'MELODIA:COMEMORACAO (8 notas) — Exige buzzer passivo para notas',
      command: 'MELODIA:COMEMORACAO',
      category: SoundCategory.melodiasPassivas,
      icon: Icons.stars_rounded,
      color: Color(0xFFFBBF24),
      requiresPassiveBuzzer: true,
    ),
    SoundItem(
      id: 'melodia_vitoria',
      title: 'Melodia de Vitória',
      subtitle: 'MELODIA:VITORIA (9 notas) — Exige buzzer passivo para notas',
      command: 'MELODIA:VITORIA',
      category: SoundCategory.melodiasPassivas,
      icon: Icons.workspace_premium_rounded,
      color: Color(0xFFEC4899),
      requiresPassiveBuzzer: true,
    ),
  ];

  static List<SoundItem> byCategory(SoundCategory cat) =>
      catalog.where((item) => item.category == cat).toList();
}
