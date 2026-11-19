// lib/ui/screens/settings/diagnostics_settings_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../../core/robot_service.dart';
import '../../../theme/app_theme.dart';
import '../../widgets/settings_components.dart';

/// Área de Configurações > Diagnóstico (Logs BLE, TX/RX, GATT e Telemetria).
class DiagnosticsSettingsScreen extends StatefulWidget {
  final bool embedded;

  const DiagnosticsSettingsScreen({super.key, this.embedded = false});

  @override
  State<DiagnosticsSettingsScreen> createState() =>
      _DiagnosticsSettingsScreenState();
}

class _DiagnosticsSettingsScreenState extends State<DiagnosticsSettingsScreen> {
  bool _runningCheck = false;
  String? _checkSummary;
  bool _checkOk = true;

  Future<void> _runFullCheck(RobotService robot) async {
    setState(() {
      _runningCheck = true;
      _checkSummary = null;
    });
    HapticFeedback.lightImpact();
    final ping = await robot.testCommunication();
    final diag = await robot.requestDiagnostics();
    final status = await robot.refreshStatus();
    if (mounted) {
      final allOk = ping.ok && diag.ok && status.ok;
      setState(() {
        _runningCheck = false;
        _checkOk = allOk;
        _checkSummary =
            'PING: ${ping.ok ? "${ping.latencyMs ?? 0} ms" : (ping.error ?? "falhou")} · '
            'DIAG: ${diag.ok ? "OK" : (diag.error ?? "falhou")} · '
            'STATUS: ${status.ok ? "OK" : (status.error ?? "falhou")}';
      });
    }
  }

  String _formatOptTime(DateTime? dt) {
    if (dt == null) return '—';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final diag = robot.diagnostics;
    final logs = robot.commandLogs;
    final isConnected = robot.isConnected;

    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Ações de diagnóstico sob demanda
        McQueenSectionCard(
          title: 'Verificação do Enlace & Firmware',
          subtitle: 'Executa PING, DIAG e STATUS para inspecionar falhas',
          icon: Icons.health_and_safety_outlined,
          accentColor: McQueenColors.cyan,
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: McQueenColors.cyan,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: isConnected && !_runningCheck
                        ? () => _runFullCheck(robot)
                        : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _runningCheck
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : const Icon(Icons.play_arrow_rounded, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'Executar Diagnóstico',
                              maxLines: 1,
                              style: GoogleFonts.outfit(
                                fontSize: 13,
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
                OutlinedButton.icon(
                  onPressed: logs.isEmpty ? null : robot.clearLogs,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: McQueenColors.textSecondary,
                    side: const BorderSide(color: McQueenColors.borderStrong),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.delete_outline_rounded, size: 17),
                  label: Text(
                    'Limpar',
                    style: GoogleFonts.outfit(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (_checkSummary != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (_checkOk ? McQueenColors.emerald : McQueenColors.amber)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_checkOk
                            ? McQueenColors.emerald
                            : McQueenColors.amber)
                        .withValues(alpha: 0.35),
                  ),
                ),
                child: Text(
                  _checkSummary!,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 11,
                    color: _checkOk ? McQueenColors.emerald : McQueenColors.amber,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            McQueenInfoRow(
              label: 'Último comando enviado',
              value: diag.lastTxCommand ?? '—',
              monospace: true,
              valueColor: McQueenColors.cyan,
            ),
            McQueenInfoRow(
              label: 'Hora do envio',
              value: _formatOptTime(diag.lastTxAt),
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'Última resposta ESP32',
              value: diag.lastRxResponse ?? robot.lastStatus ?? '—',
              monospace: true,
              valueColor: McQueenColors.emerald,
            ),
            McQueenInfoRow(
              label: 'Hora da resposta',
              value: _formatOptTime(diag.lastRxAt),
              monospace: true,
            ),
            if (diag.lastError != null)
              McQueenInfoRow(
                label: 'Último erro registrado',
                value: diag.lastError!,
                monospace: true,
                valueColor: McQueenColors.crimson,
              ),
          ],
        ),
        const SizedBox(height: 14),

        // Serviços e características BLE
        McQueenSectionCard(
          title: 'Serviços e Características BLE',
          subtitle: 'Estado da camada GATT validada na conexão',
          icon: Icons.hub_outlined,
          accentColor: McQueenColors.violet,
          children: [
            McQueenInfoRow(
              label: 'Serviço GATT validado',
              value: diag.serviceValidated ? 'SIM' : 'NÃO',
              valueColor: diag.serviceValidated
                  ? McQueenColors.emerald
                  : McQueenColors.textMuted,
            ),
            McQueenInfoRow(
              label: 'Escrita RX (App → ESP32)',
              value: diag.rxWriteModeLabel,
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'Notificações TX (ESP32 → App)',
              value: diag.txNotifyEnabled ? 'Inscrito (NOTIFY)' : 'Inativo',
              valueColor: diag.txNotifyEnabled
                  ? McQueenColors.emerald
                  : McQueenColors.amber,
            ),
            McQueenInfoRow(
              label: 'Advertising / Servos (DIAG)',
              value: diag.lastDiagRaw ?? 'Aguardando consulta DIAG',
              monospace: true,
            ),
            McQueenInfoRow(
              label: 'Última sincronização STATUS',
              value: _formatOptTime(diag.lastStatusSyncAt),
              monospace: true,
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Logs BLE em tempo real
        McQueenSectionCard(
          title: 'Logs BLE (TX / RX)',
          subtitle: '${logs.length} evento(s) recentes registrados',
          icon: Icons.terminal_rounded,
          accentColor: McQueenColors.emerald,
          children: [
            if (logs.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    'Nenhum comando registrado ainda.',
                    style: GoogleFonts.outfit(
                      fontSize: 12.5,
                      color: McQueenColors.textMuted,
                    ),
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: logs.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final entry = logs[index];
                  final color = !entry.isSuccess
                      ? McQueenColors.crimson
                      : (entry.isOutgoing
                          ? McQueenColors.cyan
                          : McQueenColors.emerald);

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.formattedTime,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10.5,
                            color: McQueenColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          entry.isOutgoing
                              ? Icons.north_east_rounded
                              : Icons.south_west_rounded,
                          size: 13,
                          color: color,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            entry.message,
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              color: color,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnóstico BLE')),
      body: SafeArea(child: body),
    );
  }
}
