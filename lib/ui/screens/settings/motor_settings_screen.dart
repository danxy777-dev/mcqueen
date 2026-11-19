// lib/ui/screens/settings/motor_settings_screen.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/ble_constants.dart';
import '../../../core/robot_service.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/settings_components.dart';

/// Área de Configurações > Motores, Velocidade & Calibração.
class MotorSettingsScreen extends StatefulWidget {
  final bool embedded;

  const MotorSettingsScreen({super.key, this.embedded = false});

  @override
  State<MotorSettingsScreen> createState() => _MotorSettingsScreenState();
}

class _MotorSettingsScreenState extends State<MotorSettingsScreen> {
  int? _draftSpeedPercent;

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final settings = robot.settings;
    final motorState = robot.motorState;
    final isConnected = robot.isConnected;
    final effectiveSpeed = _draftSpeedPercent ?? robot.speedPercent;

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (!isConnected) ...[
          const McQueenNoticeBanner(
            icon: Icons.bluetooth_disabled_rounded,
            title: 'Robô desconectado',
            message:
                'Conecte ao McQueen via BLE para enviar calibração (neutro, inversão, VMIN/VMAX, trim) e executar testes individuais de motor.',
            color: McQueenColors.cyan,
          ),
          const SizedBox(height: 12),
        ],
        const McQueenNoticeBanner(
          icon: Icons.warning_amber_rounded,
          title: 'Segurança de bancada',
          message:
              'Mantenha o McQueen apoiado (rodas livres) ao calibrar ponto neutro ou executar testes individuais. Os testes individuais giram com keepalive apenas enquanto o botão estiver pressionado.',
          color: McQueenColors.amber,
        ),
        const SizedBox(height: 14),

        // Modo de condução e velocidade
        McQueenSectionCard(
          title: 'Velocidade & Modo de Condução',
          subtitle: 'Perfis de potência, velocidade livre, sensibilidade e modo horizontal',
          icon: Icons.speed_rounded,
          accentColor: McQueenColors.cyan,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: SpeedLevel.values.map((lvl) {
                final selected = robot.currentSpeed == lvl;
                return ChoiceChip(
                  label: Text('${lvl.label} (${lvl.percent}%)'),
                  selected: selected,
                  selectedColor: McQueenColors.crimson.withValues(alpha: 0.24),
                  backgroundColor: McQueenColors.surfaceElevated,
                  side: BorderSide(
                    color: selected
                        ? McQueenColors.crimson
                        : McQueenColors.borderSubtle,
                  ),
                  labelStyle: GoogleFonts.outfit(
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? McQueenColors.textPrimary
                        : McQueenColors.textSecondary,
                  ),
                  onSelected: (_) {
                    HapticFeedback.selectionClick();
                    setState(() => _draftSpeedPercent = null);
                    robot.setSpeed(lvl);
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 14),
            McQueenSliderTile(
              label: 'Velocidade Livre (VELOCIDADE:nn)',
              subtitle: isConnected
                  ? 'Limite imediato enviado ao ESP32-C3 (0–100%)'
                  : 'Conecte para sincronizar velocidade livre com o ESP32-C3',
              value: effectiveSpeed.toDouble(),
              min: 0,
              max: 100,
              divisions: 100,
              valueText: '$effectiveSpeed%',
              accentColor: McQueenColors.amber,
              onChanged: (v) {
                setState(() => _draftSpeedPercent = v.round());
              },
              onChangeEnd: (v) {
                final target = v.round();
                setState(() => _draftSpeedPercent = null);
                robot.setSpeedPercent(target);
              },
            ),
            McQueenSliderTile(
              label: 'Sensibilidade do Controle',
              subtitle: 'Curva de resposta sem exceder o limite de velocidade (0.5x – 1.5x)',
              value: settings.sensitivity,
              min: 0.5,
              max: 1.5,
              divisions: 20,
              valueText: '${settings.sensitivity.toStringAsFixed(2)}x',
              accentColor: McQueenColors.violet,
              onChanged: (v) {
                robot.updateSettings(
                  settings.copyWith(sensitivity: v),
                  persist: false,
                );
              },
              onChangeEnd: (v) {
                robot.updateSettings(
                  settings.copyWith(sensitivity: v),
                  persist: true,
                );
              },
            ),
            const Divider(height: 20),
            McQueenSwitchTile(
              title: 'Modo Seguro no Controle Horizontal',
              subtitle: robot.controlMode == ControlMode.holdToMove
                  ? 'Ativo: para imediatamente ao soltar o botão direcional'
                  : 'Contínuo: mantém movimento até pressionar PARAR',
              value: robot.controlMode == ControlMode.holdToMove,
              accentColor: McQueenColors.emerald,
              onChanged: (val) {
                HapticFeedback.lightImpact();
                robot.setControlMode(
                  val ? ControlMode.holdToMove : ControlMode.continuous,
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Calibração de ponto neutro e inversão
        McQueenSectionCard(
          title: 'Calibração Individual dos Servos',
          subtitle: 'Ajuste o ponto de parada (µs) e sentido de cada roda (salvo na NVS)',
          icon: Icons.tune_rounded,
          accentColor: McQueenColors.emerald,
          children: [
            McQueenSliderTile(
              label: 'Neutro Servo Esquerdo (GPIO 3)',
              subtitle: 'Pulso de parada total (padrão 1500 µs)',
              value: settings.leftNeutralUs.toDouble(),
              min: 1000,
              max: 2000,
              divisions: 100,
              valueText: '${settings.leftNeutralUs} µs',
              accentColor: McQueenColors.cyan,
              onChanged: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(leftNeutralUs: v.round()),
                        persist: false,
                      )
                  : null,
              onChangeEnd: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(leftNeutralUs: v.round()),
                        syncCommand: BleConstants.cmdCalLeftStop(v.round()),
                      )
                  : null,
            ),
            McQueenSliderTile(
              label: 'Neutro Servo Direito (GPIO 0)',
              subtitle: 'Pulso de parada total (padrão 1500 µs)',
              value: settings.rightNeutralUs.toDouble(),
              min: 1000,
              max: 2000,
              divisions: 100,
              valueText: '${settings.rightNeutralUs} µs',
              accentColor: McQueenColors.orange,
              onChanged: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(rightNeutralUs: v.round()),
                        persist: false,
                      )
                  : null,
              onChangeEnd: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(rightNeutralUs: v.round()),
                        syncCommand: BleConstants.cmdCalRightStop(v.round()),
                      )
                  : null,
            ),
            const Divider(height: 18),
            McQueenSwitchTile(
              title: 'Inverter Servo Esquerdo (GPIO 3)',
              subtitle: settings.leftInverted ? 'Sentido invertido' : 'Sentido normal',
              value: settings.leftInverted,
              accentColor: McQueenColors.cyan,
              onChanged: isConnected
                  ? (val) {
                      HapticFeedback.lightImpact();
                      robot.updateSettings(
                        settings.copyWith(leftInverted: val),
                        syncCommand: BleConstants.cmdCalInvertLeft,
                      );
                    }
                  : null,
            ),
            McQueenSwitchTile(
              title: 'Inverter Servo Direito (GPIO 0)',
              subtitle: settings.rightInverted ? 'Sentido invertido' : 'Sentido normal',
              value: settings.rightInverted,
              accentColor: McQueenColors.orange,
              onChanged: isConnected
                  ? (val) {
                      HapticFeedback.lightImpact();
                      robot.updateSettings(
                        settings.copyWith(rightInverted: val),
                        syncCommand: BleConstants.cmdCalInvertRight,
                      );
                    }
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Faixa segura e Trim
        McQueenSectionCard(
          title: 'Limites Seguros & Alinhamento (Trim)',
          subtitle: 'Compensação de zona morta e equilíbrio entre as rodas (VMIN < VMAX)',
          icon: Icons.balance_rounded,
          accentColor: McQueenColors.amber,
          children: [
            McQueenSliderTile(
              label: 'Velocidade Mínima Efetiva (VMIN)',
              value: settings.minSpeedPercent.toDouble(),
              min: 0,
              max: 90,
              divisions: 90,
              valueText: '${settings.minSpeedPercent}%',
              accentColor: McQueenColors.cyan,
              onChanged: isConnected
                  ? (v) {
                      final clamped =
                          math.min(v.round(), settings.maxSpeedPercent - 5);
                      robot.updateSettings(
                        settings.copyWith(minSpeedPercent: clamped),
                        persist: false,
                      );
                    }
                  : null,
              onChangeEnd: isConnected
                  ? (v) {
                      final clamped =
                          math.min(v.round(), settings.maxSpeedPercent - 5);
                      robot.updateSettings(
                        settings.copyWith(minSpeedPercent: clamped),
                        syncCommand: BleConstants.cmdCalVMin(clamped),
                      );
                    }
                  : null,
            ),
            McQueenSliderTile(
              label: 'Velocidade Máxima Segura (VMAX)',
              value: settings.maxSpeedPercent.toDouble(),
              min: 10,
              max: 100,
              divisions: 90,
              valueText: '${settings.maxSpeedPercent}%',
              accentColor: McQueenColors.crimson,
              onChanged: isConnected
                  ? (v) {
                      final clamped =
                          math.max(v.round(), settings.minSpeedPercent + 5);
                      robot.updateSettings(
                        settings.copyWith(maxSpeedPercent: clamped),
                        persist: false,
                      );
                    }
                  : null,
              onChangeEnd: isConnected
                  ? (v) {
                      final clamped =
                          math.max(v.round(), settings.minSpeedPercent + 5);
                      robot.updateSettings(
                        settings.copyWith(maxSpeedPercent: clamped),
                        syncCommand: BleConstants.cmdCalVMax(clamped),
                      );
                    }
                  : null,
            ),
            const Divider(height: 18),
            McQueenSliderTile(
              label: 'Trim Lado Esquerdo',
              value: settings.leftTrimPercent.toDouble(),
              min: -50,
              max: 50,
              divisions: 100,
              valueText: '${settings.leftTrimPercent}%',
              accentColor: McQueenColors.cyan,
              onChanged: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(leftTrimPercent: v.round()),
                        persist: false,
                      )
                  : null,
              onChangeEnd: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(leftTrimPercent: v.round()),
                        syncCommand: BleConstants.cmdCalTrimLeft(v.round()),
                      )
                  : null,
            ),
            McQueenSliderTile(
              label: 'Trim Lado Direito',
              value: settings.rightTrimPercent.toDouble(),
              min: -50,
              max: 50,
              divisions: 100,
              valueText: '${settings.rightTrimPercent}%',
              accentColor: McQueenColors.orange,
              onChanged: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(rightTrimPercent: v.round()),
                        persist: false,
                      )
                  : null,
              onChangeEnd: isConnected
                  ? (v) => robot.updateSettings(
                        settings.copyWith(rightTrimPercent: v.round()),
                        syncCommand: BleConstants.cmdCalTrimRight(v.round()),
                      )
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Testes individuais com Hold-to-Test seguro + keepalive + PARAR
        McQueenSectionCard(
          title: 'Testes Individuais de Motor',
          subtitle:
              'Segure para girar a 15% (o outro lado permanece parado). Solte para parar.',
          icon: Icons.precision_manufacturing_rounded,
          accentColor: McQueenColors.crimson,
          children: [
            McQueenInfoRow(
              label: 'Comando & Neutro',
              value:
                  'ESQ ${motorState.leftSpeed}% (${motorState.leftNeutralUs} µs)  ·  DIR ${motorState.rightSpeed}% (${motorState.rightNeutralUs} µs)',
              monospace: true,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _HoldMotorTestButton(
                    label: 'ESQ +15%',
                    color: McQueenColors.cyan,
                    enabled: isConnected,
                    onStart: () => robot.startMotorTest('ESQ', 15),
                    onStop: () => robot.emergencyStop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _HoldMotorTestButton(
                    label: 'ESQ -15%',
                    color: McQueenColors.cyan,
                    enabled: isConnected,
                    onStart: () => robot.startMotorTest('ESQ', -15),
                    onStop: () => robot.emergencyStop(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _HoldMotorTestButton(
                    label: 'DIR +15%',
                    color: McQueenColors.orange,
                    enabled: isConnected,
                    onStart: () => robot.startMotorTest('DIR', 15),
                    onStop: () => robot.emergencyStop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _HoldMotorTestButton(
                    label: 'DIR -15%',
                    color: McQueenColors.orange,
                    enabled: isConnected,
                    onStart: () => robot.startMotorTest('DIR', -15),
                    onStop: () => robot.emergencyStop(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: McQueenColors.crimson,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: isConnected
                    ? () {
                        HapticFeedback.heavyImpact();
                        robot.emergencyStop();
                      }
                    : null,
                icon: const Icon(Icons.stop_circle_rounded, size: 20),
                label: Text(
                  'PARAR MOTORES (PARAR)',
                  style: GoogleFonts.outfit(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: McQueenColors.crimson,
                  side: BorderSide(
                    color: McQueenColors.crimson.withValues(alpha: 0.45),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _confirmReset(context, robot),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.restore_rounded, size: 17),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'Restaurar Calibração de Fábrica',
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

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Motores & Calibração')),
      body: SafeArea(child: body),
    );
  }

  void _confirmReset(BuildContext context, RobotService robot) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Restaurar calibração?'),
        content: const Text(
          'Os valores de ponto neutro (1500 µs), inversão, VMIN/VMAX e trim voltarão ao padrão de fábrica.',
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
              setState(() => _draftSpeedPercent = null);
              await robot.resetAllSettings();
              if (context.mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  SnackBar(
                    content: Text(
                      robot.isConnected
                          ? 'Calibração restaurada no ESP32-C3.'
                          : 'Calibração local restaurada para o padrão de fábrica.',
                    ),
                  ),
                );
              }
            },
            child: const Text('Restaurar'),
          ),
        ],
      ),
    );
  }
}

class _HoldMotorTestButton extends StatefulWidget {
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback onStart;
  final VoidCallback onStop;

  const _HoldMotorTestButton({
    required this.label,
    required this.color,
    required this.enabled,
    required this.onStart,
    required this.onStop,
  });

  @override
  State<_HoldMotorTestButton> createState() => _HoldMotorTestButtonState();
}

class _HoldMotorTestButtonState extends State<_HoldMotorTestButton> {
  bool _holding = false;

  @override
  void didUpdateWidget(covariant _HoldMotorTestButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _holding) {
      _holding = false;
      Future<void>.microtask(widget.onStop);
    }
  }

  @override
  void deactivate() {
    if (_holding) {
      _holding = false;
      Future<void>.microtask(widget.onStop);
    }
    super.deactivate();
  }

  void _start() {
    if (!widget.enabled || _holding) return;
    setState(() => _holding = true);
    HapticFeedback.lightImpact();
    widget.onStart();
  }

  void _stop() {
    if (!_holding) return;
    setState(() => _holding = false);
    widget.onStop();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: widget.enabled ? (_) => _start() : null,
      onPointerUp: (_) => _stop(),
      onPointerCancel: (_) => _stop(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: _holding
              ? widget.color.withValues(alpha: 0.28)
              : widget.color.withValues(alpha: widget.enabled ? 0.12 : 0.05),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: widget.enabled
                ? widget.color.withValues(alpha: _holding ? 0.9 : 0.45)
                : McQueenColors.borderSubtle,
          ),
        ),
        child: Center(
          child: Text(
            _holding ? '${widget.label} (ATIVO)' : widget.label,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: widget.enabled ? widget.color : McQueenColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
