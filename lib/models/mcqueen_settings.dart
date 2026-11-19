import 'dart:convert';
import 'dart:io';

import 'robot_expression.dart';

/// Configurações personalizáveis e calibração persistida do McQueen 2.0.
class McQueenSettings {
  // Velocidade e sensibilidade
  final int defaultSpeedPercent;
  final double sensitivity;

  // Calibração independente dos servos de rotação contínua
  final int leftNeutralUs;
  final int rightNeutralUs;
  final bool leftInverted;
  final bool rightInverted;
  final int minSpeedPercent;
  final int maxSpeedPercent;
  final int leftTrimPercent;
  final int rightTrimPercent;

  // Personalidade e reações automáticas (Idle)
  final bool autoReactionsEnabled;
  final int reactionIntervalSeconds;
  final RobotExpression baseExpression;
  final Set<RobotExpression> favoriteExpressions;

  // Central de Sons
  final bool soundsEnabled;
  final bool activeBuzzerMode;
  final int customBeepDurationMs;
  final int customBeepCount;
  final int customBeepGapMs;

  const McQueenSettings({
    this.defaultSpeedPercent = 60,
    this.sensitivity = 1.0,
    this.leftNeutralUs = 1500,
    this.rightNeutralUs = 1500,
    this.leftInverted = false,
    this.rightInverted = true,
    this.minSpeedPercent = 0,
    this.maxSpeedPercent = 100,
    this.leftTrimPercent = 0,
    this.rightTrimPercent = 0,
    this.autoReactionsEnabled = true,
    this.reactionIntervalSeconds = 8,
    this.baseExpression = RobotExpression.normal,
    this.favoriteExpressions = const {
      RobotExpression.normal,
      RobotExpression.feliz,
      RobotExpression.bravo,
      RobotExpression.triste,
      RobotExpression.surpreso,
      RobotExpression.curioso,
      RobotExpression.sonolento,
      RobotExpression.animado,
      RobotExpression.confuso,
      RobotExpression.assustado,
      RobotExpression.apaixonado,
      RobotExpression.piscando,
    },
    this.soundsEnabled = true,
    this.activeBuzzerMode = true,
    this.customBeepDurationMs = 120,
    this.customBeepCount = 3,
    this.customBeepGapMs = 160,
  });

  /// Bitmask das expressões favoritas para o comando `AUTO:MASK:<int>` do ESP32.
  int get favoriteExpressionsMask {
    int mask = 0;
    for (final expr in favoriteExpressions) {
      mask |= (1 << expr.bitIndex);
    }
    return mask == 0 ? 0x0FFF : mask;
  }

  McQueenSettings copyWith({
    int? defaultSpeedPercent,
    double? sensitivity,
    int? leftNeutralUs,
    int? rightNeutralUs,
    bool? leftInverted,
    bool? rightInverted,
    int? minSpeedPercent,
    int? maxSpeedPercent,
    int? leftTrimPercent,
    int? rightTrimPercent,
    bool? autoReactionsEnabled,
    int? reactionIntervalSeconds,
    RobotExpression? baseExpression,
    Set<RobotExpression>? favoriteExpressions,
    bool? soundsEnabled,
    bool? activeBuzzerMode,
    int? customBeepDurationMs,
    int? customBeepCount,
    int? customBeepGapMs,
  }) {
    final nextMax = (maxSpeedPercent ?? this.maxSpeedPercent).clamp(10, 100);
    final nextMin =
        (minSpeedPercent ?? this.minSpeedPercent).clamp(0, nextMax - 5);
    return McQueenSettings(
      defaultSpeedPercent:
          (defaultSpeedPercent ?? this.defaultSpeedPercent).clamp(10, 100),
      sensitivity: (sensitivity ?? this.sensitivity).clamp(0.5, 1.5),
      leftNeutralUs: (leftNeutralUs ?? this.leftNeutralUs).clamp(1000, 2000),
      rightNeutralUs: (rightNeutralUs ?? this.rightNeutralUs).clamp(1000, 2000),
      leftInverted: leftInverted ?? this.leftInverted,
      rightInverted: rightInverted ?? this.rightInverted,
      minSpeedPercent: nextMin,
      maxSpeedPercent: nextMax,
      leftTrimPercent: (leftTrimPercent ?? this.leftTrimPercent).clamp(-50, 50),
      rightTrimPercent:
          (rightTrimPercent ?? this.rightTrimPercent).clamp(-50, 50),
      autoReactionsEnabled: autoReactionsEnabled ?? this.autoReactionsEnabled,
      reactionIntervalSeconds:
          (reactionIntervalSeconds ?? this.reactionIntervalSeconds).clamp(3, 60),
      baseExpression: baseExpression ?? this.baseExpression,
      favoriteExpressions: favoriteExpressions ?? this.favoriteExpressions,
      soundsEnabled: soundsEnabled ?? this.soundsEnabled,
      activeBuzzerMode: activeBuzzerMode ?? this.activeBuzzerMode,
      customBeepDurationMs:
          (customBeepDurationMs ?? this.customBeepDurationMs).clamp(40, 1000),
      customBeepCount: (customBeepCount ?? this.customBeepCount).clamp(1, 8),
      customBeepGapMs:
          (customBeepGapMs ?? this.customBeepGapMs).clamp(80, 600),
    );
  }

  Map<String, dynamic> toJson() => {
        'defaultSpeedPercent': defaultSpeedPercent,
        'sensitivity': sensitivity,
        'leftNeutralUs': leftNeutralUs,
        'rightNeutralUs': rightNeutralUs,
        'leftInverted': leftInverted,
        'rightInverted': rightInverted,
        'minSpeedPercent': minSpeedPercent,
        'maxSpeedPercent': maxSpeedPercent,
        'leftTrimPercent': leftTrimPercent,
        'rightTrimPercent': rightTrimPercent,
        'autoReactionsEnabled': autoReactionsEnabled,
        'reactionIntervalSeconds': reactionIntervalSeconds,
        'baseExpression': baseExpression.code,
        'favoriteExpressions':
            favoriteExpressions.map((e) => e.code).toList(growable: false),
        'soundsEnabled': soundsEnabled,
        'activeBuzzerMode': activeBuzzerMode,
        'customBeepDurationMs': customBeepDurationMs,
        'customBeepCount': customBeepCount,
        'customBeepGapMs': customBeepGapMs,
      };

  factory McQueenSettings.fromJson(Map<String, dynamic> map) {
    final favRaw = map['favoriteExpressions'];
    Set<RobotExpression> favs = Set<RobotExpression>.from(RobotExpression.values);
    if (favRaw is List && favRaw.isNotEmpty) {
      favs = favRaw
          .whereType<String>()
          .map(RobotExpression.fromCode)
          .toSet();
      if (favs.isEmpty) {
        favs = Set<RobotExpression>.from(RobotExpression.values);
      }
    }

    return McQueenSettings(
      defaultSpeedPercent: (map['defaultSpeedPercent'] as int? ?? 60).clamp(10, 100),
      sensitivity: ((map['sensitivity'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 1.5),
      leftNeutralUs: (map['leftNeutralUs'] as int? ?? 1500).clamp(1000, 2000),
      rightNeutralUs: (map['rightNeutralUs'] as int? ?? 1500).clamp(1000, 2000),
      leftInverted: map['leftInverted'] as bool? ?? false,
      rightInverted: map['rightInverted'] as bool? ?? true,
      minSpeedPercent: (map['minSpeedPercent'] as int? ?? 0).clamp(0, 90),
      maxSpeedPercent: (map['maxSpeedPercent'] as int? ?? 100).clamp(10, 100),
      leftTrimPercent: (map['leftTrimPercent'] as int? ?? 0).clamp(-50, 50),
      rightTrimPercent: (map['rightTrimPercent'] as int? ?? 0).clamp(-50, 50),
      autoReactionsEnabled: map['autoReactionsEnabled'] as bool? ?? true,
      reactionIntervalSeconds:
          (map['reactionIntervalSeconds'] as int? ?? 8).clamp(3, 60),
      baseExpression: RobotExpression.fromCode(
          map['baseExpression'] as String? ?? 'NORMAL'),
      favoriteExpressions: favs,
      soundsEnabled: map['soundsEnabled'] as bool? ?? true,
      activeBuzzerMode: map['activeBuzzerMode'] as bool? ?? true,
      customBeepDurationMs:
          (map['customBeepDurationMs'] as int? ?? 120).clamp(40, 1000),
      customBeepCount: (map['customBeepCount'] as int? ?? 3).clamp(1, 8),
      customBeepGapMs:
          (map['customBeepGapMs'] as int? ?? 160).clamp(80, 600),
    );
  }
}

/// Persistência local leve em arquivo JSON para as configurações do McQueen 2.0.
class McQueenSettingsStore {
  static File get _file =>
      File('${Directory.systemTemp.path}/mcqueen_v2_settings.json');

  static Future<McQueenSettings> load() async {
    try {
      final f = _file;
      if (await f.exists()) {
        final content = await f.readAsString();
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          return McQueenSettings.fromJson(decoded);
        }
      }
    } catch (_) {
      // Ignora falha de leitura e retorna padrão de fábrica
    }
    return const McQueenSettings();
  }

  static Future<void> save(McQueenSettings settings) async {
    try {
      final f = _file;
      await f.writeAsString(jsonEncode(settings.toJson()), flush: true);
    } catch (_) {
      // Ignora erro de I/O em ambientes somente leitura
    }
  }
}
