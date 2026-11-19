// lib/ui/widgets/connection_dialogs.dart
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../theme/app_theme.dart';

class ConnectionDialogs {
  ConnectionDialogs._();

  /// Pop-up de SUCESSO exibido após conexão e validação GATT/PING real.
  static void showSuccess(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: McQueenColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: McQueenColors.emerald.withValues(alpha: 0.45),
            width: 1.2,
          ),
        ),
        iconPadding: const EdgeInsets.only(top: 24, bottom: 12),
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: McQueenColors.emerald.withValues(alpha: 0.14),
            border: Border.all(
              color: McQueenColors.emerald.withValues(alpha: 0.65),
              width: 1.5,
            ),
          ),
          child: const Icon(
            Icons.check_rounded,
            color: McQueenColors.emerald,
            size: 30,
          ),
        ),
        title: Text(
          'Conexão estabelecida!',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: McQueenColors.textPrimary,
          ),
        ),
        content: Text(
          'O aplicativo está conectado ao ESP32 do McQueen via Bluetooth BLE. O serviço e a característica de comunicação foram identificados com sucesso. O robô está pronto para receber comandos.',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 13.5,
            height: 1.45,
            color: McQueenColors.textSecondary,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        actions: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: McQueenColors.emerald,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: Text(
                'Fechar',
                style: GoogleFonts.outfit(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pop-up de ERRO com causa específica e ação de reconexão.
  static void showFailure(
    BuildContext context, {
    required String specificCause,
    required VoidCallback onRetry,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: McQueenColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: McQueenColors.crimson.withValues(alpha: 0.45),
            width: 1.2,
          ),
        ),
        iconPadding: const EdgeInsets.only(top: 24, bottom: 12),
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: McQueenColors.crimson.withValues(alpha: 0.14),
            border: Border.all(
              color: McQueenColors.crimson.withValues(alpha: 0.65),
              width: 1.5,
            ),
          ),
          child: const Icon(
            Icons.bluetooth_disabled_rounded,
            color: McQueenColors.crimson,
            size: 28,
          ),
        ),
        title: Text(
          'Não foi possível conectar',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: McQueenColors.textPrimary,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Não foi possível estabelecer uma conexão funcional com o ESP32 do McQueen. Verifique se o robô está ligado, se o Bluetooth está ativado e se a placa está anunciando o serviço BLE correto.',
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  fontSize: 13,
                  height: 1.45,
                  color: McQueenColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: McQueenColors.crimson.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: McQueenColors.crimson.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: McQueenColors.crimson,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        specificCause,
                        style: GoogleFonts.outfit(
                          fontSize: 12,
                          height: 1.35,
                          color: const Color(0xFFFFA5AD),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(
              'Fechar',
              style: GoogleFonts.outfit(
                color: McQueenColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: McQueenColors.crimson,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(
              'Tentar novamente',
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              onRetry();
            },
          ),
        ],
      ),
    );
  }

  /// Alerta de QUEDA DE CONEXÃO inesperada durante o uso.
  static void showDisconnected(
    BuildContext context, {
    required String message,
    required VoidCallback onReconnect,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: McQueenColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(
            color: McQueenColors.amber.withValues(alpha: 0.45),
            width: 1.2,
          ),
        ),
        iconPadding: const EdgeInsets.only(top: 24, bottom: 12),
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: McQueenColors.amber.withValues(alpha: 0.14),
            border: Border.all(
              color: McQueenColors.amber.withValues(alpha: 0.65),
              width: 1.5,
            ),
          ),
          child: const Icon(
            Icons.link_off_rounded,
            color: McQueenColors.amber,
            size: 28,
          ),
        ),
        title: Text(
          'Conexão perdida',
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: McQueenColors.textPrimary,
          ),
        ),
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.outfit(
            fontSize: 13,
            height: 1.45,
            color: McQueenColors.textSecondary,
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(
              'Fechar',
              style: GoogleFonts.outfit(
                color: McQueenColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: McQueenColors.amber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.bluetooth_searching_rounded, size: 16),
            label: Text(
              'Reconectar',
              style: GoogleFonts.outfit(
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
            onPressed: () {
              Navigator.of(dialogCtx).pop();
              onReconnect();
            },
          ),
        ],
      ),
    );
  }
}
