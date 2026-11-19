// lib/models/turn_signal_state.dart
import 'package:flutter/material.dart';

import '../core/ble_constants.dart';

/// Estado das setas direcionais (GPIO 7 esquerda, GPIO 9 direita).
enum TurnSignalState {
  off(
    code: 'OFF',
    label: 'Desligadas',
    shortLabel: 'Desligar',
    command: BleConstants.cmdSetaDesligar,
    accentColor: Color(0xFF9E9E9E),
  ),
  left(
    code: 'ESQ',
    label: 'Seta Esquerda',
    shortLabel: 'Esquerda',
    command: BleConstants.cmdSetaEsquerda,
    accentColor: Color(0xFFFFB300),
  ),
  right(
    code: 'DIR',
    label: 'Seta Direita',
    shortLabel: 'Direita',
    command: BleConstants.cmdSetaDireita,
    accentColor: Color(0xFFFFB300),
  ),
  alert(
    code: 'ALR',
    label: 'Pisca-Alerta',
    shortLabel: 'Alerta',
    command: BleConstants.cmdSetaAlerta,
    accentColor: Color(0xFFFF6D00),
  ),
  auto(
    code: 'AUTO',
    label: 'Automático',
    shortLabel: 'Auto',
    command: BleConstants.cmdSetaAuto,
    accentColor: Color(0xFF4CAF50),
  );

  final String code;
  final String label;
  final String shortLabel;
  final String command;
  final Color accentColor;

  const TurnSignalState({
    required this.code,
    required this.label,
    required this.shortLabel,
    required this.command,
    required this.accentColor,
  });

  bool get isLeftBlinking => this == left || this == alert;
  bool get isRightBlinking => this == right || this == alert;
  bool get isActive => this != off;

  static TurnSignalState fromCode(String raw) {
    final normalized = raw.trim().toUpperCase();
    for (final state in values) {
      if (state.code == normalized || state.name.toUpperCase() == normalized) {
        return state;
      }
    }
    return switch (normalized) {
      'ESQUERDA' => TurnSignalState.left,
      'DIREITA' => TurnSignalState.right,
      'ALERTA' || 'PISCA' => TurnSignalState.alert,
      'DESLIGAR' || 'DESLIGADA' || 'OFF' => TurnSignalState.off,
      'AUTO' => TurnSignalState.auto,
      _ => TurnSignalState.off,
    };
  }
}

