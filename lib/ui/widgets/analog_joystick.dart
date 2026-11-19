// lib/ui/widgets/analog_joystick.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/ble_constants.dart';
import '../../core/robot_service.dart';
import '../../theme/app_theme.dart';

/// Joystick analógico circular ergonômico para controle proporcional do McQueen.
///
/// - Suporta todas as direções (360°), incluindo diagonais combinadas.
/// - Escala a intensidade conforme inclinação do polegar e modo de velocidade ativo.
/// - Envia comandos diferenciais (`DIFF:L:R`) com throttling trailing-edge e keepalive.
/// - Ao soltar, cancelar toque, perder foco do app ou desconectar BLE, envia `PARAR`
///   imediatamente e retorna suavemente a bolinha ao centro.
class AnalogJoystick extends StatefulWidget {
  final double? diameter;

  const AnalogJoystick({super.key, this.diameter});

  /// Converte posição normalizada do stick (`dx, dy` em `-1.0..1.0`, onde `dy > 0`
  /// significa frente e `dx > 0` direita) para velocidades diferenciais `(left, right)`
  /// em `-100..100`, respeitando `deadzone` e `speedLimitPercent`.
  static (int left, int right) computeMotorSpeeds(
    Offset normalizedStick, {
    required int speedLimitPercent,
    double deadzone = 0.10,
  }) {
    final x = normalizedStick.dx.clamp(-1.0, 1.0);
    final y = normalizedStick.dy.clamp(-1.0, 1.0);
    final radius = math.sqrt(x * x + y * y).clamp(0.0, 1.0);
    final limit = speedLimitPercent.clamp(0, 100);

    if (radius < deadzone || limit <= 0) {
      return (0, 0);
    }

    final effectiveMag = ((radius - deadzone) / (1.0 - deadzone)).clamp(0.0, 1.0);
    final ux = x / radius;
    final uy = y / radius;

    double rawLeft = uy + ux;
    double rawRight = uy - ux;
    final peak = math.max(1.0, math.max(rawLeft.abs(), rawRight.abs()));
    rawLeft /= peak;
    rawRight /= peak;

    final left = (rawLeft * effectiveMag * limit).round().clamp(-100, 100);
    final right = (rawRight * effectiveMag * limit).round().clamp(-100, 100);
    return (left, right);
  }

  @override
  State<AnalogJoystick> createState() => _AnalogJoystickState();
}

class _AnalogJoystickState extends State<AnalogJoystick>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  RobotService? _robot;
  late final AnimationController _returnController;
  Animation<Offset>? _returnAnimation;

  Timer? _keepAliveTimer;
  Timer? _throttleTimer;
  bool _pendingDeferredSend = false;
  int? _activePointerId;
  bool _hasFocus = false;
  final Set<LogicalKeyboardKey> _pressedSteeringKeys = <LogicalKeyboardKey>{};

  static final Map<LogicalKeyboardKey, Offset> _keyVectors = {
    LogicalKeyboardKey.arrowUp: Offset(0, 1),
    LogicalKeyboardKey.keyW: Offset(0, 1),
    LogicalKeyboardKey.arrowDown: Offset(0, -1),
    LogicalKeyboardKey.keyS: Offset(0, -1),
    LogicalKeyboardKey.arrowLeft: Offset(-1, 0),
    LogicalKeyboardKey.keyA: Offset(-1, 0),
    LogicalKeyboardKey.arrowRight: Offset(1, 0),
    LogicalKeyboardKey.keyD: Offset(1, 0),
  };

  /// Posição normalizada do stick dentro do círculo unitário (`dy > 0` = frente).
  Offset _stickNormalized = Offset.zero;

  int _lastSentLeft = 0;
  int _lastSentRight = 0;
  bool _wasMoving = false;
  bool _lastConnected = false;
  int _lastEmergencyStopCount = 0;
  int _lastSpeedPercent = SpeedLevel.normal.percent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _returnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() {
        if (!mounted || _returnAnimation == null) return;
        setState(() {
          _stickNormalized = _returnAnimation!.value;
        });
      });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<RobotService>();
    if (_robot != service) {
      _robot?.removeListener(_onRobotChanged);
      _robot = service;
      _lastConnected = service.isConnected;
      _lastEmergencyStopCount = service.emergencyStopCount;
      _lastSpeedPercent = service.speedPercent;
      service.addListener(_onRobotChanged);
    }
    final isCurrentRoute = ModalRoute.of(context)?.isCurrent ?? true;
    if (!isCurrentRoute &&
        (_activePointerId != null ||
            _wasMoving ||
            _pressedSteeringKeys.isNotEmpty)) {
      _forceResetToCenter(sendStop: true, animate: false, deferStop: true);
    }
  }

  void _onRobotChanged() {
    final robot = _robot;
    if (robot == null) return;
    final connected = robot.isConnected;
    final stopCount = robot.emergencyStopCount;
    final speedPct = robot.speedPercent;
    if (_lastConnected && !connected) {
      _forceResetToCenter(sendStop: false, animate: mounted);
    } else if (stopCount != _lastEmergencyStopCount) {
      _lastEmergencyStopCount = stopCount;
      if (_activePointerId != null ||
          _wasMoving ||
          _pressedSteeringKeys.isNotEmpty ||
          _stickNormalized != Offset.zero) {
        _forceResetToCenter(sendStop: false, animate: mounted);
      }
    } else if (connected && speedPct != _lastSpeedPercent) {
      _lastSpeedPercent = speedPct;
      if (_wasMoving &&
          (_activePointerId != null || _pressedSteeringKeys.isNotEmpty)) {
        _scheduleDifferentialSend();
      }
    }
    _lastConnected = connected;
    _lastSpeedPercent = speedPct;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _forceResetToCenter(sendStop: true, animate: mounted);
    }
  }

  @override
  void deactivate() {
    // Durante deactivate() a árvore está sendo desmontada/reconstruída:
    // nunca chamar setState, AnimationController ou notifyListeners() síncrono aqui.
    _forceResetToCenter(sendStop: true, animate: false, deferStop: true);
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _robot?.removeListener(_onRobotChanged);
    _cancelTimers();
    if (_wasMoving && (_robot?.isConnected ?? false)) {
      _robot?.stopJoystick();
    }
    _returnController.dispose();
    super.dispose();
  }

  void _cancelTimers() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingDeferredSend = false;
  }

  void _handlePointerDown(PointerDownEvent event, double baseDiameter) {
    final robot = _robot;
    if (robot == null || !robot.isConnected) return;
    if (_activePointerId != null) return;

    _activePointerId = event.pointer;
    _returnController.stop();
    HapticFeedback.selectionClick();
    _updateFromLocalPosition(event.localPosition, baseDiameter);
    _startKeepAlive();
  }

  void _handlePointerMove(PointerMoveEvent event, double baseDiameter) {
    if (event.pointer != _activePointerId) return;
    if (!(_robot?.isConnected ?? false)) {
      _forceResetToCenter(sendStop: false, animate: true);
      return;
    }
    _updateFromLocalPosition(event.localPosition, baseDiameter);
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.pointer != _activePointerId) return;
    _releaseAndStop();
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    if (event.pointer != _activePointerId) return;
    _releaseAndStop();
  }

  void _updateFromLocalPosition(Offset localPos, double baseDiameter) {
    final baseRadius = baseDiameter / 2.0;
    final knobRadius = baseRadius * 0.36;
    final maxTravel = math.max(24.0, baseRadius - knobRadius - 6.0);
    final center = Offset(baseRadius, baseRadius);

    final delta = localPos - center;
    final distance = delta.distance;
    final clampedDelta =
        distance > maxTravel && distance > 0 ? delta * (maxTravel / distance) : delta;

    final nextNormalized = Offset(
      (clampedDelta.dx / maxTravel).clamp(-1.0, 1.0),
      (-clampedDelta.dy / maxTravel).clamp(-1.0, 1.0),
    );

    if (mounted) {
      setState(() {
        _stickNormalized = nextNormalized;
      });
    }

    _scheduleDifferentialSend();
  }

  void _scheduleDifferentialSend() {
    final robot = _robot;
    if (robot == null || !robot.isConnected) return;

    final (left, right) = AnalogJoystick.computeMotorSpeeds(
      _stickNormalized,
      speedLimitPercent: robot.speedPercent,
    );

    if (left == 0 && right == 0) {
      _throttleTimer?.cancel();
      _throttleTimer = null;
      _pendingDeferredSend = false;
      if (_wasMoving) {
        _wasMoving = false;
        _lastSentLeft = 0;
        _lastSentRight = 0;
        unawaited(robot.stopJoystick());
      }
      return;
    }

    if (left == _lastSentLeft && right == _lastSentRight && _wasMoving) {
      return;
    }

    if (_throttleTimer == null || !_throttleTimer!.isActive) {
      _dispatchDrive(left, right);
      _throttleTimer = Timer(BleConstants.joystickMinSendInterval, () {
        if (!mounted || !_pendingDeferredSend) return;
        _pendingDeferredSend = false;
        _scheduleDifferentialSend();
      });
    } else {
      _pendingDeferredSend = true;
    }
  }

  void _dispatchDrive(int left, int right) {
    final robot = _robot;
    if (robot == null || !robot.isConnected) return;
    _lastSentLeft = left;
    _lastSentRight = right;
    _wasMoving = true;
    unawaited(robot.joystickControl(left: left, right: right));
  }

  void _startKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(
      BleConstants.joystickKeepAliveInterval,
      (_) {
        if (!mounted ||
            (_activePointerId == null && _pressedSteeringKeys.isEmpty) ||
            !(_robot?.isConnected ?? false)) {
          _keepAliveTimer?.cancel();
          _keepAliveTimer = null;
          return;
        }
        final (left, right) = AnalogJoystick.computeMotorSpeeds(
          _stickNormalized,
          speedLimitPercent: _robot!.speedPercent,
        );
        if (left != 0 || right != 0) {
          _dispatchDrive(left, right);
        }
      },
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.escape)) {
      _releaseAndStop();
      return KeyEventResult.handled;
    }

    if (!_keyVectors.containsKey(event.logicalKey)) {
      return KeyEventResult.ignored;
    }

    if (!(_robot?.isConnected ?? false)) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      if (_pressedSteeringKeys.add(event.logicalKey)) {
        _applyKeyboardVector();
      }
      return KeyEventResult.handled;
    }

    if (event is KeyUpEvent) {
      if (_pressedSteeringKeys.remove(event.logicalKey)) {
        _applyKeyboardVector();
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  void _applyKeyboardVector() {
    if (!(_robot?.isConnected ?? false)) {
      _forceResetToCenter(sendStop: false, animate: true);
      return;
    }

    double x = 0;
    double y = 0;
    for (final key in _pressedSteeringKeys) {
      final v = _keyVectors[key];
      if (v != null) {
        x += v.dx;
        y += v.dy;
      }
    }
    x = x.clamp(-1.0, 1.0);
    y = y.clamp(-1.0, 1.0);

    if (x == 0 && y == 0) {
      _releaseAndStop();
      return;
    }

    final dist = math.sqrt(x * x + y * y);
    final next = dist > 1.0 ? Offset(x / dist, y / dist) : Offset(x, y);

    _returnController.stop();
    if (mounted) {
      setState(() {
        _stickNormalized = next;
      });
    }
    _scheduleDifferentialSend();
    if (_keepAliveTimer == null || !_keepAliveTimer!.isActive) {
      _startKeepAlive();
    }
  }

  void _releaseAndStop() {
    _activePointerId = null;
    _pressedSteeringKeys.clear();
    _cancelTimers();
    _lastSentLeft = 0;
    _lastSentRight = 0;
    _wasMoving = false;
    if (_robot?.isConnected ?? false) {
      unawaited(_robot!.stopJoystick());
    }
    _animateToCenter();
  }

  void _forceResetToCenter({
    required bool sendStop,
    required bool animate,
    bool deferStop = false,
  }) {
    _activePointerId = null;
    _pressedSteeringKeys.clear();
    _cancelTimers();
    final hadMotion = _wasMoving || _lastSentLeft != 0 || _lastSentRight != 0;
    _lastSentLeft = 0;
    _lastSentRight = 0;
    _wasMoving = false;
    final robot = _robot;
    if (sendStop && hadMotion && (robot?.isConnected ?? false)) {
      if (deferStop) {
        Future<void>.microtask(() {
          if (robot!.isConnected) {
            unawaited(robot.stopJoystick());
          }
        });
      } else {
        unawaited(robot!.stopJoystick());
      }
    }
    if (animate && mounted) {
      _animateToCenter();
    } else {
      _returnController.stop();
      _stickNormalized = Offset.zero;
    }
  }

  void _animateToCenter() {
    if (_stickNormalized == Offset.zero) return;
    final disableAnimations =
        mounted && MediaQuery.of(context).disableAnimations;
    if (disableAnimations) {
      _returnController.stop();
      setState(() {
        _stickNormalized = Offset.zero;
      });
      return;
    }
    _returnAnimation = Tween<Offset>(
      begin: _stickNormalized,
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _returnController,
        curve: Curves.easeOutCubic,
      ),
    );
    _returnController.forward(from: 0);
  }

  String _semanticDirectionLabel(Offset stick) {
    final x = stick.dx;
    final y = stick.dy;
    final vertical = y > 0.25 ? 'frente' : (y < -0.25 ? 'ré' : '');
    final horizontal = x > 0.25 ? 'direita' : (x < -0.25 ? 'esquerda' : '');
    if (vertical.isNotEmpty && horizontal.isNotEmpty) {
      return '$vertical e $horizontal';
    }
    if (vertical.isNotEmpty) return vertical;
    if (horizontal.isNotEmpty) return horizontal;
    return 'neutro';
  }

  @override
  Widget build(BuildContext context) {
    final robot = context.watch<RobotService>();
    final isConnected = robot.isConnected;
    final disableAnimations = MediaQuery.of(context).disableAnimations;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxAvailable = math.min(
          constraints.maxWidth.isFinite ? constraints.maxWidth : 280.0,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 280.0,
        );
        final minBound = math.min(maxAvailable, 140.0);
        final maxBound = math.max(minBound, math.min(maxAvailable, 300.0));
        final diameter = (widget.diameter ?? maxAvailable).clamp(minBound, maxBound);
        final baseRadius = diameter / 2.0;
        final knobRadius = baseRadius * 0.36;
        final maxTravel = math.max(24.0, baseRadius - knobRadius - 6.0);

        final knobOffset = Offset(
          _stickNormalized.dx * maxTravel,
          -_stickNormalized.dy * maxTravel,
        );

        final intensity = _stickNormalized.distance.clamp(0.0, 1.0);
        final isSteered =
            _activePointerId != null || _pressedSteeringKeys.isNotEmpty;
        final isActive = isConnected && isSteered && intensity >= 0.10;
        final accent = isActive
            ? Color.lerp(
                McQueenColors.cyan,
                McQueenColors.crimson,
                intensity,
              )!
            : (isConnected ? McQueenColors.crimson : McQueenColors.textMuted);

        final powerPercent = (intensity * robot.speedPercent).round();
        final semanticValue = !isConnected
            ? 'Desconectado'
            : (isActive
                ? 'Direção ${_semanticDirectionLabel(_stickNormalized)}, potência $powerPercent%'
                : 'Neutro (parado)');
        final semanticHint = isConnected
            ? 'Arraste para dirigir ou use as setas do teclado e WASD. Espaço ou Escape para parar.'
            : 'Conecte o McQueen para dirigir';

        return Center(
          child: Semantics(
            container: true,
            label: 'Joystick analógico',
            value: semanticValue,
            hint: semanticHint,
            enabled: isConnected,
            customSemanticsActions: isConnected
                ? <CustomSemanticsAction, VoidCallback>{
                    const CustomSemanticsAction(label: 'Parar motores'):
                        _releaseAndStop,
                  }
                : null,
            child: Focus(
              onFocusChange: (focused) {
                if (mounted) {
                  setState(() => _hasFocus = focused);
                }
                if (!focused && _pressedSteeringKeys.isNotEmpty) {
                  _releaseAndStop();
                }
              },
              onKeyEvent: _handleKeyEvent,
              child: ExcludeSemantics(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _handlePointerDown(e, diameter),
                  onPointerMove: (e) => _handlePointerMove(e, diameter),
                  onPointerUp: _handlePointerUp,
                  onPointerCancel: _handlePointerCancel,
                  child: SizedBox(
                    width: diameter,
                    height: diameter,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CustomPaint(
                          size: Size.square(diameter),
                          painter: _JoystickBasePainter(
                            isConnected: isConnected,
                            isActive: isActive,
                            hasFocus: _hasFocus,
                            stickNormalized: _stickNormalized,
                            knobOffset: knobOffset,
                            accentColor: accent,
                          ),
                        ),
                        Transform.translate(
                          offset: knobOffset,
                          child: _JoystickKnob(
                            diameter: knobRadius * 2,
                            isConnected: isConnected,
                            isActive: isActive,
                            isDragging: isSteered,
                            disableAnimations: disableAnimations,
                            accentColor: accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _JoystickBasePainter extends CustomPainter {
  final bool isConnected;
  final bool isActive;
  final bool hasFocus;
  final Offset stickNormalized;
  final Offset knobOffset;
  final Color accentColor;

  const _JoystickBasePainter({
    required this.isConnected,
    required this.isActive,
    required this.hasFocus,
    required this.stickNormalized,
    required this.knobOffset,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.65)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(center.translate(0, 6), radius - 4, shadowPaint);

    final basePaint = Paint()
      ..shader = RadialGradient(
        colors: [
          McQueenColors.surfaceElevated,
          McQueenColors.surface,
          McQueenColors.bgSecondary,
        ],
        stops: const [0.0, 0.62, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius - 2, basePaint);

    final outerBorder = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = hasFocus ? 2.5 : 1.5
      ..color = hasFocus
          ? McQueenColors.cyan.withValues(alpha: 0.9)
          : (isActive
              ? accentColor.withValues(alpha: 0.65)
              : (isConnected
                  ? McQueenColors.borderStrong
                  : McQueenColors.borderSubtle));
    canvas.drawCircle(center, radius - 2, outerBorder);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withValues(alpha: isConnected ? 0.16 : 0.08);
    canvas.drawCircle(center, radius * 0.68, ringPaint);
    canvas.drawCircle(center, radius * 0.36, ringPaint);

    final tickPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.8
      ..color = Colors.white.withValues(alpha: isConnected ? 0.34 : 0.16);
    final diagTickPaint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 1.3
      ..color = Colors.white.withValues(alpha: isConnected ? 0.22 : 0.10);

    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi / 4.0;
      final isCardinal = i % 2 == 0;
      final inner = radius - (isCardinal ? 16.0 : 12.0);
      final outer = radius - 6.0;
      final p1 = center + Offset(math.cos(angle) * inner, math.sin(angle) * inner);
      final p2 = center + Offset(math.cos(angle) * outer, math.sin(angle) * outer);
      canvas.drawLine(p1, p2, isCardinal ? tickPaint : diagTickPaint);
    }

    if (isActive) {
      final angle = math.atan2(-stickNormalized.dy, stickNormalized.dx);
      final intensity = stickNormalized.distance.clamp(0.0, 1.0);
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..color = accentColor.withValues(alpha: 0.35 + 0.55 * intensity);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 3),
        angle - 0.42,
        0.84,
        false,
        arcPaint,
      );

      final linePaint = Paint()
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            accentColor.withValues(alpha: 0.05),
            accentColor.withValues(alpha: 0.55),
          ],
        ).createShader(Rect.fromPoints(center, center + knobOffset));
      canvas.drawLine(center, center + knobOffset, linePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _JoystickBasePainter oldDelegate) {
    return oldDelegate.isConnected != isConnected ||
        oldDelegate.isActive != isActive ||
        oldDelegate.hasFocus != hasFocus ||
        oldDelegate.stickNormalized != stickNormalized ||
        oldDelegate.knobOffset != knobOffset ||
        oldDelegate.accentColor != accentColor;
  }
}

class _JoystickKnob extends StatelessWidget {
  final double diameter;
  final bool isConnected;
  final bool isActive;
  final bool isDragging;
  final bool disableAnimations;
  final Color accentColor;

  const _JoystickKnob({
    required this.diameter,
    required this.isConnected,
    required this.isActive,
    required this.isDragging,
    required this.disableAnimations,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isDragging ? 0.94 : 1.0,
      duration:
          disableAnimations ? Duration.zero : const Duration(milliseconds: 90),
      curve: Curves.easeOut,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.25, -0.3),
            colors: isActive
                ? [
                    accentColor,
                    Color.lerp(accentColor, Colors.black, 0.38)!,
                    const Color(0xFF1A1217),
                  ]
                : (isConnected
                    ? const [
                        Color(0xFF2D354A),
                        Color(0xFF1C2232),
                        Color(0xFF111521),
                      ]
                    : const [
                        Color(0xFF1C202B),
                        Color(0xFF141721),
                        Color(0xFF0E1018),
                      ]),
            stops: const [0.0, 0.58, 1.0],
          ),
          border: Border.all(
            color: isActive
                ? accentColor.withValues(alpha: 0.75)
                : (isConnected
                    ? Colors.white.withValues(alpha: 0.16)
                    : Colors.white.withValues(alpha: 0.07)),
            width: isActive ? 2.0 : 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
            if (isActive)
              BoxShadow(
                color: accentColor.withValues(alpha: 0.35),
                blurRadius: 24,
                spreadRadius: 2,
              ),
          ],
        ),
        child: Center(
          child: Container(
            width: diameter * 0.42,
            height: diameter * 0.42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: isActive ? 0.16 : 0.05),
              border: Border.all(
                color: Colors.white.withValues(alpha: isActive ? 0.32 : 0.1),
              ),
            ),
            child: Center(
              child: Container(
                width: diameter * 0.12,
                height: diameter * 0.12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isActive
                      ? Colors.white
                      : (isConnected
                          ? McQueenColors.crimson.withValues(alpha: 0.75)
                          : McQueenColors.textMuted.withValues(alpha: 0.45)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
