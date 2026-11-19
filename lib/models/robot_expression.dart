import 'package:flutter/material.dart';

/// As 12 expressões faciais animadas do display OLED 128x64 do McQueen 2.0.
enum RobotExpression {
  normal(
    bitIndex: 0,
    label: 'Normal',
    subtitle: 'Olhar atento e curioso padrão',
    command: 'EXPR:NORMAL',
    code: 'NORMAL',
    icon: Icons.visibility_rounded,
    accentColor: Color(0xFF38BDF8),
  ),
  feliz(
    bitIndex: 1,
    label: 'Feliz',
    subtitle: 'Olhos arqueados sorridentes',
    command: 'EXPR:FELIZ',
    code: 'FELIZ',
    icon: Icons.sentiment_very_satisfied_rounded,
    accentColor: Color(0xFF22C55E),
  ),
  bravo(
    bitIndex: 2,
    label: 'Bravo',
    subtitle: 'Sobrancelhas franzidas de corrida',
    command: 'EXPR:BRAVO',
    code: 'BRAVO',
    icon: Icons.whatshot_rounded,
    accentColor: Color(0xFFEF4444),
  ),
  triste(
    bitIndex: 3,
    label: 'Triste',
    subtitle: 'Olhar caído com lágrima animada',
    command: 'EXPR:TRISTE',
    code: 'TRISTE',
    icon: Icons.sentiment_dissatisfied_rounded,
    accentColor: Color(0xFF60A5FA),
  ),
  surpreso(
    bitIndex: 4,
    label: 'Surpreso',
    subtitle: 'Olhos arregalados e boca em O',
    command: 'EXPR:SURPRESO',
    code: 'SURPRESO',
    icon: Icons.bolt_rounded,
    accentColor: Color(0xFFFBBF24),
  ),
  curioso(
    bitIndex: 5,
    label: 'Curioso',
    subtitle: 'Sobrancelha erguida investigando',
    command: 'EXPR:CURIOSO',
    code: 'CURIOSO',
    icon: Icons.psychology_alt_rounded,
    accentColor: Color(0xFFA855F7),
  ),
  sonolento(
    bitIndex: 6,
    label: 'Sonolento',
    subtitle: 'Pálpebras pesadas e Zzz flutuante',
    command: 'EXPR:SONOLENTO',
    code: 'SONOLENTO',
    icon: Icons.bedtime_rounded,
    accentColor: Color(0xFF818CF8),
  ),
  animado(
    bitIndex: 7,
    label: 'Animado',
    subtitle: 'Olhos brilhantes cheios de energia',
    command: 'EXPR:ANIMADO',
    code: 'ANIMADO',
    icon: Icons.auto_awesome_rounded,
    accentColor: Color(0xFFF59E0B),
  ),
  confuso(
    bitIndex: 8,
    label: 'Confuso',
    subtitle: 'Olhos assimétricos e interrogação',
    command: 'EXPR:CONFUSO',
    code: 'CONFUSO',
    icon: Icons.help_outline_rounded,
    accentColor: Color(0xFFFB923C),
  ),
  assustado(
    bitIndex: 9,
    label: 'Assustado',
    subtitle: 'Pupilas contraídas e olhar trêmulo',
    command: 'EXPR:ASSUSTADO',
    code: 'ASSUSTADO',
    icon: Icons.warning_amber_rounded,
    accentColor: Color(0xFFF43F5E),
  ),
  apaixonado(
    bitIndex: 10,
    label: 'Apaixonado',
    subtitle: 'Corações pulsantes no display OLED',
    command: 'EXPR:APAIXONADO',
    code: 'APAIXONADO',
    icon: Icons.favorite_rounded,
    accentColor: Color(0xFFEC4899),
  ),
  piscando(
    bitIndex: 11,
    label: 'Piscando',
    subtitle: 'Piscadela charmosa alternada',
    command: 'EXPR:PISCANDO',
    code: 'PISCANDO',
    icon: Icons.mood_rounded,
    accentColor: Color(0xFF14B8A6),
  );

  final int bitIndex;
  final String label;
  final String subtitle;
  final String command;
  final String code;
  final IconData icon;
  final Color accentColor;

  const RobotExpression({
    required this.bitIndex,
    required this.label,
    required this.subtitle,
    required this.command,
    required this.code,
    required this.icon,
    required this.accentColor,
  });

  /// Converte código textual retornado pelo firmware (`NORMAL`, `FELIZ`, etc.)
  static RobotExpression fromCode(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final expr in RobotExpression.values) {
      if (expr.code == normalized) {
        return expr;
      }
    }
    return RobotExpression.normal;
  }
}
