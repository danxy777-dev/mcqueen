// lib/ui/screens/settings/connection_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/ble_constants.dart';
import '../../../core/robot_service.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/settings_components.dart';

/// Área de Configurações > Conexão BLE.
class ConnectionSettingsScreen extends StatefulWidget {
  final bool embedded;

  const ConnectionSettingsScreen({super.key, this.embedded = false});

  @override
  State<ConnectionSettingsScreen> createState() =>
      _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<ConnectionSettingsScreen> {
  bool _testingPing = false;
  bool _testingDiag = false;
  String? _testFeedback;
  bool? _testFeedbackOk;

  Future<void> _runPingTest(RobotService robot) async {
    setState(() {
      _testingPing = true;
      _testFeedback = null;
    });
    final res = await robot.testCommunication();
    if (!mounted) return;
    setState(() {
      _testingPing = false;
      _testFeedbackOk = res.ok;
      _testFeedback = res.ok
          ? 'PING → PONG confirmado em ${res.latencyMs ?? 0} ms.'
          : (res.error ?? 'Falha no teste PING.');
    });
  }

  Future<void> _runDiag(RobotService robot) async {
    setState(() {
      _testingDiag = true;
      _testFeedback = null;
    });
    final res = await robot.requestDiagnostics();
    if (!mounted) return;
    setState(() {
      _testingDiag = false;
      _testFeedbackOk = res.ok;
      _testFeedback = res.ok
          ? 'Diagnóstico recebido: ${res.response}'
          : (res.error ?? 'Falha ao consultar DIAG.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final diag = robot.diagnostics;
    final state = robot.connectionState;
    final isConnected = robot.isConnected;
    final isBusy = state == RobotConnectionState.scanning ||
        state == RobotConnectionState.connecting ||
        state == RobotConnectionState.validatingService;

    final (stateColor, stateIcon) = switch (state) {
      RobotConnectionState.disconnected => (
          McQueenColors.textSecondary,
          Icons.bluetooth_disabled_rounded,
        ),
      RobotConnectionState.scanning => (
          McQueenColors.amber,
          Icons.bluetooth_searching_rounded,
        ),
      RobotConnectionState.connecting => (
          McQueenColors.cyan,
          Icons.bluetooth_searching_rounded,
        ),
      RobotConnectionState.validatingService => (
          McQueenColors.violet,
          Icons.verified_user_outlined,
        ),
      RobotConnectionState.connected => (
          McQueenColors.emerald,
          Icons.bluetooth_connected_rounded,
        ),
      RobotConnectionState.error => (
          McQueenColors.crimson,
          Icons.error_outline_rounded,
        ),
    };

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Estado e ação principal
        McQueenSectionCard(
          title: 'Estado da Conexão BLE',
          subtitle: isConnected
              ? 'Comunicação ativa com o ESP32-C3'
              : 'Gerencie o pareamento Bluetooth Low Energy',
          icon: stateIcon,
          accentColor: stateColor,
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: stateColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              state.label,
              style: GoogleFonts.outfit(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: stateColor,
              ),
            ),
          ),
          children: [
            McQueenInfoRow(
              label: 'Dispositivo alvo',
              value: diag.deviceName ?? BleConstants.deviceName,
            ),
            McQueenInfoRow(
              label: 'Identificador / MAC',
              value: diag.deviceId ?? 'Não conectado',
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'Sinal RSSI',
              value: isConnected && robot.rssi != 0
                  ? '${robot.rssi} dBm'
                  : 'Indisponível',
              valueColor: isConnected && robot.rssi != 0
                  ? (robot.rssi >= -65
                      ? McQueenColors.emerald
                      : McQueenColors.amber)
                  : McQueenColors.textMuted,
              monospace: true,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      isConnected ? McQueenColors.crimson : McQueenColors.emerald,
                  foregroundColor: isConnected ? Colors.white : Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: isBusy
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        if (isConnected) {
                          robot.disconnect();
                        } else {
                          robot.connect();
                        }
                      },
                icon: isBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: McQueenColors.cyan,
                        ),
                      )
                    : Icon(
                        isConnected
                            ? Icons.link_off_rounded
                            : Icons.bluetooth_searching_rounded,
                        size: 18,
                      ),
                label: Text(
                  isBusy
                      ? state.label
                      : (isConnected ? 'Desconectar do McQueen' : 'Conectar ao McQueen'),
                  style: GoogleFonts.outfit(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Teste de comunicação e diagnóstico do enlace
        McQueenSectionCard(
          title: 'Teste de Comunicação & Diagnóstico',
          subtitle: 'Valida o canal RX/TX real com o ESP32-C3 sem mover motores',
          icon: Icons.network_check_rounded,
          accentColor: McQueenColors.cyan,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isConnected && !_testingPing
                        ? () => _runPingTest(robot)
                        : null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: McQueenColors.cyan,
                      side: BorderSide(
                        color: McQueenColors.cyan.withValues(alpha: 0.45),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _testingPing
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.radar_rounded, size: 17),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Testar PING',
                        maxLines: 1,
                        style: GoogleFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: isConnected && !_testingDiag
                        ? () => _runDiag(robot)
                        : null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: McQueenColors.violet,
                      side: BorderSide(
                        color: McQueenColors.violet.withValues(alpha: 0.45),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: _testingDiag
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.analytics_outlined, size: 17),
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        'Consultar DIAG',
                        maxLines: 1,
                        style: GoogleFonts.outfit(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_testFeedback != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_testFeedbackOk == true
                          ? McQueenColors.emerald
                          : McQueenColors.crimson)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (_testFeedbackOk == true
                            ? McQueenColors.emerald
                            : McQueenColors.crimson)
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  _testFeedback!,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11.5,
                    color: _testFeedbackOk == true
                        ? McQueenColors.emerald
                        : McQueenColors.crimson,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            McQueenInfoRow(
              label: 'Latência PING/PONG',
              value: diag.lastPingLatencyMs != null
                  ? '${diag.lastPingLatencyMs} ms'
                  : 'Não medida',
              monospace: true,
              valueColor: diag.lastPingLatencyMs != null
                  ? McQueenColors.emerald
                  : McQueenColors.textMuted,
            ),
            McQueenInfoRow(
              label: 'Canal de escrita (RX)',
              value: diag.rxWriteModeLabel,
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'Notificações (TX NOTIFY)',
              value: diag.txNotifyEnabled ? 'Ativo' : 'Inativo',
              valueColor: diag.txNotifyEnabled
                  ? McQueenColors.emerald
                  : McQueenColors.textMuted,
            ),
            if (diag.lastDiagRaw != null) ...[
              McQueenInfoRow(
                label: 'Último DIAG',
                value: diag.lastDiagRaw!,
                monospace: true,
              ),
              if (diag.diagServosEnabled != null)
                McQueenInfoRow(
                  label: 'Servos no firmware',
                  value: diag.diagServosEnabled! ? 'Habilitados (PWM)' : 'Desativados',
                  valueColor: diag.diagServosEnabled!
                      ? McQueenColors.emerald
                      : McQueenColors.amber,
                ),
              if (diag.diagAdvPayloadBytes != null)
                McQueenInfoRow(
                  label: 'Payload Advertising',
                  value: '${diag.diagAdvPayloadBytes} bytes',
                  monospace: true,
                ),
            ],
          ],
        ),
        const SizedBox(height: 14),

        // Informações GATT
        McQueenSectionCard(
          title: 'Parâmetros GATT',
          subtitle: 'Identificadores preservados do protocolo ESP32-C3',
          icon: Icons.fingerprint_rounded,
          accentColor: McQueenColors.violet,
          children: [
            McQueenInfoRow(
              label: 'Service UUID',
              value: diag.serviceUuid,
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'RX Characteristic',
              value: diag.rxCharUuid,
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'TX Characteristic',
              value: diag.txCharUuid,
              monospace: true,
            ),
            if (robot.connectionError != null)
              McQueenInfoRow(
                label: 'Última falha BLE',
                value: robot.connectionError!,
                valueColor: McQueenColors.crimson,
              ),
          ],
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Conexão BLE')),
      body: SafeArea(child: body),
    );
  }
}
