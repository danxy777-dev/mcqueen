// lib/models/motor_state.dart

/// Estado detalhado dos dois servomotores de rotação contínua do McQueen.
/// - Servo esquerdo: GPIO 3
/// - Servo direito:  GPIO 0
class MotorState {
  /// Velocidade percentual atual do servo esquerdo (-100 a +100).
  final int leftSpeed;

  /// Velocidade percentual atual do servo direito (-100 a +100).
  final int rightSpeed;

  /// Ponto neutro calibrado do servo esquerdo em microssegundos (1000..2000 µs).
  final int leftNeutralUs;

  /// Ponto neutro calibrado do servo direito em microssegundos (1000..2000 µs).
  final int rightNeutralUs;

  /// Indica se o sentido do servo esquerdo está invertido.
  final bool leftInverted;

  /// Indica se o sentido do servo direito está invertido.
  final bool rightInverted;

  /// Rótulo legível da direção atual (`PARADO`, `FRENTE`, `RÉ`, `ESQUERDA`, `DIREITA`, `DIFERENCIAL`).
  final String direction;

  const MotorState({
    this.leftSpeed = 0,
    this.rightSpeed = 0,
    this.leftNeutralUs = 1500,
    this.rightNeutralUs = 1500,
    this.leftInverted = false,
    this.rightInverted = true,
    this.direction = 'PARADO',
  });

  /// Retorna `true` se qualquer um dos motores estiver em movimento.
  bool get isMoving => leftSpeed != 0 || rightSpeed != 0;

  /// Calcula o pulso PWM aproximado em µs enviado ao servo esquerdo.
  int get leftPulseUs {
    if (leftSpeed == 0) return leftNeutralUs;
    final dir = leftInverted ? -1 : 1;
    final delta = ((leftSpeed * dir) * 500) ~/ 100;
    return (leftNeutralUs + delta).clamp(1000, 2000);
  }

  /// Calcula o pulso PWM aproximado em µs enviado ao servo direito.
  int get rightPulseUs {
    if (rightSpeed == 0) return rightNeutralUs;
    final dir = rightInverted ? -1 : 1;
    final delta = ((rightSpeed * dir) * 500) ~/ 100;
    return (rightNeutralUs + delta).clamp(1000, 2000);
  }

  MotorState copyWith({
    int? leftSpeed,
    int? rightSpeed,
    int? leftNeutralUs,
    int? rightNeutralUs,
    bool? leftInverted,
    bool? rightInverted,
    String? direction,
  }) {
    return MotorState(
      leftSpeed: leftSpeed ?? this.leftSpeed,
      rightSpeed: rightSpeed ?? this.rightSpeed,
      leftNeutralUs: leftNeutralUs ?? this.leftNeutralUs,
      rightNeutralUs: rightNeutralUs ?? this.rightNeutralUs,
      leftInverted: leftInverted ?? this.leftInverted,
      rightInverted: rightInverted ?? this.rightInverted,
      direction: direction ?? this.direction,
    );
  }
}
