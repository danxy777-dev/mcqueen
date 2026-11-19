// lib/core/ble_constants.dart

/// Constantes do protocolo Bluetooth Low Energy (BLE) para o Robô McQueen 2.0.
/// Sincronizado com o firmware ESP32-C3 (`mcqueen_firmware.ino` v4.2.0).
class BleConstants {
  BleConstants._();

  // -- Identificacao do Periferico -------------------------------------------
  static const String deviceName = 'McQueen';

  // -- UUIDs GATT (128-bit) --------------------------------------------------
  static const String serviceUuid = '12345678-1234-5678-1234-56789abcdef0';
  static const String charRxUuid = '12345678-1234-5678-1234-56789abcdef1';
  static const String charTxUuid = '12345678-1234-5678-1234-56789abcdef2';

  // -- Comandos de Movimentacao -----------------------------------------------
  static const String cmdFrente = 'FRENTE';
  static const String cmdTras = 'TRAS';
  static const String cmdEsquerda = 'ESQUERDA';
  static const String cmdDireita = 'DIREITA';
  static const String cmdParar = 'PARAR';

  // -- Comandos de Velocidade (Perfis McQueen 4.0) ----------------------------
  static const String cmdVel1 = 'VEL:1'; // ECO (30%)
  static const String cmdVel2 = 'VEL:2'; // Normal (60%)
  static const String cmdVel3 = 'VEL:3'; // Sport (85%)
  static const String cmdVel4 = 'VEL:4'; // Turbo (100%)
  static const String cmdSpeedPrefix = 'VELOCIDADE:';

  // -- Comandos de Perfil de Velocidade por Nome (McQueen 4.0) -------------
  static const String cmdSpeedProfileEco = 'SPEED_PROFILE:ECO';
  static const String cmdSpeedProfileNormal = 'SPEED_PROFILE:NORMAL';
  static const String cmdSpeedProfileSport = 'SPEED_PROFILE:SPORT';
  static const String cmdSpeedProfileTurbo = 'SPEED_PROFILE:TURBO';

  // -- Comandos Sonoros -------------------------------------------------------
  static const String cmdBuzina = 'BUZINA';
  static const String cmdBuzinaCurta = 'BUZINA:CURTA';
  static const String cmdBuzinaLonga = 'BUZINA:LONGA';
  static const String cmdBuzinaEmergencia = 'BUZINA:EMERGENCIA';
  static const String cmdBuzinaDesligar = 'BUZINA:DESLIGAR';
  static const String cmdBipe = 'BIPE';
  static const String cmdAlerta = 'ALERTA';
  static const String cmdMute = 'MUTE';
  static const String cmdSomMuteOn = 'SOM:MUTE:1';
  static const String cmdSomMuteOff = 'SOM:MUTE:0';
  static const String cmdBuzzerAtivo = 'BUZZER:ATIVO';
  static const String cmdBuzzerPassivo = 'BUZZER:PASSIVO';

  // -- Comandos das Setas (GPIO 7 e GPIO 9) ------------------------------------
  static const String cmdSetaEsquerda = 'SETA:ESQUERDA';
  static const String cmdSetaDireita = 'SETA:DIREITA';
  static const String cmdSetaAlerta = 'SETA:ALERTA';
  static const String cmdSetaDesligar = 'SETA:DESLIGAR';
  static const String cmdSetaAuto = 'SETA:AUTO';

  // -- Comandos de Expressao e Reacoes Automaticas ----------------------------
  static String cmdExpr(String code) => 'EXPR:${code.trim().toUpperCase()}';
  static const String cmdAutoOn = 'AUTO:ON';
  static const String cmdAutoOff = 'AUTO:OFF';
  static String cmdAutoFreq(int seconds) => 'AUTO:FREQ:${seconds.clamp(3, 120)}';
  static String cmdAutoMask(int mask) => 'AUTO:MASK:$mask';

  // -- Comandos de Calibracao dos Servos --------------------------------------
  static String cmdCalLeftStop(int us) => 'CAL:ESTOPL:${us.clamp(1000, 2000)}';
  static String cmdCalRightStop(int us) => 'CAL:ESTOPR:${us.clamp(1000, 2000)}';
  static const String cmdCalInvertLeft = 'CAL:INVERTEL';
  static const String cmdCalInvertRight = 'CAL:INVERTED';
  static String cmdCalVMin(int pct) => 'CAL:VMIN:${pct.clamp(0, 95)}';
  static String cmdCalVMax(int pct) => 'CAL:VMAX:${pct.clamp(5, 100)}';
  static String cmdCalTrimLeft(int pct) => 'CAL:TRIML:${pct.clamp(-50, 50)}';
  static String cmdCalTrimRight(int pct) => 'CAL:TRIMR:${pct.clamp(-50, 50)}';
  static const String cmdCalReset = 'CAL:RESET';
  static String cmdMotorLeft(int speed) => 'MOTOR:ESQ:${speed.clamp(-100, 100)}';
  static String cmdMotorRight(int speed) => 'MOTOR:DIR:${speed.clamp(-100, 100)}';

  // -- Controle Diferencial Proporcional --------------------------------------
  static const String cmdDiffPrefix = 'DIFF:';

  // -- Diagnostico ------------------------------------------------------------
  static const String cmdPing = 'PING';
  static const String cmdStatus = 'STATUS';
  static const String cmdStatusJson = 'STATUS:JSON';
  static const String cmdDiag = 'DIAG';

  // -- Timeouts e Intervalos --------------------------------------------------
  static const Duration scanTimeout = Duration(seconds: 10);
  static const Duration connectTimeout = Duration(seconds: 12);
  static const Duration movementRepeatInterval = Duration(milliseconds: 120);
  static const Duration joystickKeepAliveInterval = Duration(milliseconds: 140);
  static const Duration joystickMinSendInterval = Duration(milliseconds: 60);

  // -- Helpers de Protocolo ---------------------------------------------------
  static int clampPercent(int percent) => percent.clamp(0, 100);

  static String speed(int percent) => '$cmdSpeedPrefix${clampPercent(percent)}';

  static String toneCommand(int freqHz, int durationMs) =>
      'TONE:${freqHz.clamp(100, 10000)}:${durationMs.clamp(20, 3000)}';

  static String movement(String direction, int speedPercent) {
    final base = direction.split(':').first.trim().toUpperCase();
    return '$base:${clampPercent(speedPercent)}';
  }

  static String diff(int left, int right) {
    final l = left.clamp(-100, 100);
    final r = right.clamp(-100, 100);
    if (l == 0 && r == 0) return cmdParar;
    return '$cmdDiffPrefix$l:$r';
  }

  static bool isStopCommand(String cmd) {
    final norm = cmd.trim().toUpperCase();
    return norm == cmdParar || norm == 'STOP';
  }

  static bool isMovementCommand(String cmd) {
    final trimmed = cmd.trim();
    if (trimmed.startsWith('{')) {
      final upper = trimmed.toUpperCase();
      return upper.contains('"MOVE"') || upper.contains('"DIFF"');
    }
    final base = trimmed.split(':').first.trim().toUpperCase();
    return base == cmdFrente ||
        base == cmdTras ||
        base == cmdEsquerda ||
        base == cmdDireita ||
        base == 'ESQ' ||
        base == 'DIR' ||
        base == 'DIFF' ||
        base == 'MOTOR';
  }
}