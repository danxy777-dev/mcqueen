// lib/ui/widgets/oled_face_preview.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/robot_expression.dart';

/// Simulador visual fiel do display OLED 128x64 do McQueen 2.0.
/// Renderiza em tempo real as 12 expressões faciais com movimentos sutis,
/// piscadas automáticas, sobrancelhas, bocas e efeitos (corações, lágrimas, Zzz).
class OledFacePreview extends StatefulWidget {
  final RobotExpression expression;
  final String direction;
  final int speedPercent;
  final bool isConnected;
  final double height;
  final bool showBezel;
  final bool animate;
  final VoidCallback? onTap;

  const OledFacePreview({
    super.key,
    required this.expression,
    this.direction = 'PARADO',
    this.speedPercent = 70,
    this.isConnected = false,
    this.height = 96,
    this.showBezel = true,
    this.animate = true,
    this.onTap,
  });

  @override
  State<OledFacePreview> createState() => _OledFacePreviewState();
}

class _OledFacePreviewState extends State<OledFacePreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant OledFacePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    final disableAnimations =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final shouldRun = widget.animate && !disableAnimations;
    if (shouldRun && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!shouldRun && _controller.isAnimating) {
      _controller.stop();
      if (disableAnimations) {
        _controller.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final semanticValue = widget.isConnected
        ? 'Direção ${widget.direction}, velocidade ${widget.speedPercent}%'
        : 'Desconectado';
    final card = Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: const Color(0xFF05070B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: widget.expression.accentColor.withValues(alpha: 0.45),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: widget.expression.accentColor.withValues(alpha: 0.14),
            blurRadius: 16,
            spreadRadius: 1,
          ),
        ],
      ),
      padding: EdgeInsets.all(widget.showBezel ? 6 : 3),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              painter: _Oled128x64Painter(
                expression: widget.expression,
                direction: widget.direction,
                speedPercent: widget.speedPercent,
                isConnected: widget.isConnected,
                phase: _controller.value,
              ),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );

    return Semantics(
      container: true,
      button: widget.onTap != null,
      image: widget.onTap == null,
      label: 'Prévia do display OLED: expressão ${widget.expression.label}',
      value: semanticValue,
      hint: widget.onTap != null
          ? 'Toque duas vezes para enviar expressão'
          : null,
      excludeSemantics: true,
      child: widget.onTap != null
          ? Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: widget.onTap,
                child: card,
              ),
            )
          : card,
    );
  }
}

class _Oled128x64Painter extends CustomPainter {
  final RobotExpression expression;
  final String direction;
  final int speedPercent;
  final bool isConnected;
  final double phase;

  _Oled128x64Painter({
    required this.expression,
    required this.direction,
    required this.speedPercent,
    required this.isConnected,
    required this.phase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fundo matriz OLED
    final bgPaint = Paint()..color = const Color(0xFF04060A);
    canvas.drawRect(Offset.zero & size, bgPaint);

    // Escala virtual 128x64 preservando proporção
    final scaleX = size.width / 128.0;
    final scaleY = size.height / 64.0;
    final scale = math.min(scaleX, scaleY);
    final offsetX = (size.width - 128.0 * scale) / 2.0;
    final offsetY = (size.height - 64.0 * scale) / 2.0;

    canvas.save();
    canvas.translate(offsetX, offsetY);
    canvas.scale(scale, scale);

    const oledCyan = Color(0xFF5CE1E6);
    final glowPaint = Paint()
      ..color = oledCyan.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0);
    final whitePaint = Paint()
      ..color = const Color(0xFFE6FAFC)
      ..style = PaintingStyle.fill;
    final blackPaint = Paint()
      ..color = const Color(0xFF04060A)
      ..style = PaintingStyle.fill;
    final strokePaint = Paint()
      ..color = const Color(0xFFE6FAFC)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    // 1. Linha HUD superior (idêntica ao SSD1306 128x64)
    _drawHudText(
      canvas,
      isConnected ? 'BLE:OK' : (phase % 0.25 < 0.125 ? 'BLE:.' : 'BLE: '),
      const Offset(2, 0),
      const Color(0xFF7DD3FC),
    );
    final dirShort = switch (direction) {
      'FRENTE' => 'FRT',
      'TRAS' => 'TRS',
      'ESQUERDA' => 'ESQ',
      'DIREITA' => 'DIR',
      'PARADO' => 'PAR',
      _ => 'MOV',
    };
    _drawHudText(
      canvas,
      '$dirShort $speedPercent%',
      const Offset(80, 0),
      const Color(0xFF7DD3FC),
    );

    // 2. Cálculo de offset das pupilas e piscada
    double pupX = 0;
    double pupY = 0;
    if (direction == 'ESQUERDA') {
      pupX = -5.5;
    } else if (direction == 'DIREITA') {
      pupX = 5.5;
    } else if (direction == 'FRENTE') {
      pupY = -3.0;
    } else if (direction == 'TRAS') {
      pupY = 3.5;
    } else {
      final step = ((phase * 5).floor()) % 5;
      if (step == 1) pupX = 4.5;
      if (step == 2) pupX = -4.5;
      if (step == 3) pupY = -3.5;
      if (step == 4) pupY = 2.0;
    }

    final isBlinking =
        expression != RobotExpression.piscando && (phase > 0.92 && phase < 0.97);

    // 3. Desenho dos dois olhos (x=38 e x=90, y=34)
    _drawEye(
      canvas,
      cx: 38,
      cy: 34,
      pupX: pupX,
      pupY: pupY,
      isLeft: true,
      isBlinking: isBlinking,
      whitePaint: whitePaint,
      glowPaint: glowPaint,
      blackPaint: blackPaint,
      strokePaint: strokePaint,
    );
    _drawEye(
      canvas,
      cx: 90,
      cy: 34,
      pupX: pupX,
      pupY: pupY,
      isLeft: false,
      isBlinking: isBlinking,
      whitePaint: whitePaint,
      glowPaint: glowPaint,
      blackPaint: blackPaint,
      strokePaint: strokePaint,
    );

    // 4. Bocas e elementos extras
    _drawMouthAndExtras(canvas, whitePaint, strokePaint);

    canvas.restore();
  }

  void _drawEye(
    Canvas canvas, {
    required double cx,
    required double cy,
    required double pupX,
    required double pupY,
    required bool isLeft,
    required bool isBlinking,
    required Paint whitePaint,
    required Paint glowPaint,
    required Paint blackPaint,
    required Paint strokePaint,
  }) {
    if (isBlinking) {
      canvas.drawLine(Offset(cx - 15, cy), Offset(cx + 15, cy), strokePaint);
      return;
    }

    const double w = 32;
    const double h = 40;

    switch (expression) {
      case RobotExpression.normal:
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
          const Radius.circular(11),
        );
        canvas.drawRRect(rect, glowPaint);
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(Offset(cx + pupX, cy + pupY), 8.5, blackPaint);
        canvas.drawCircle(
            Offset(cx + pupX - 3, cy + pupY - 3), 2.8, whitePaint);
        break;

      case RobotExpression.feliz:
        final bounce = math.sin(phase * math.pi * 6) * 1.2;
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(cx, cy + bounce), width: w, height: h),
          const Radius.circular(11),
        );
        canvas.drawRRect(rect, glowPaint);
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(
            Offset(cx + pupX, cy - 3 + bounce), 8.0, blackPaint);
        canvas.drawCircle(
            Offset(cx + pupX - 3, cy - 6 + bounce), 2.8, whitePaint);
        canvas.drawCircle(Offset(cx, cy + 19 + bounce), 18.5, blackPaint);
        break;

      case RobotExpression.bravo:
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
          const Radius.circular(9),
        );
        canvas.drawRRect(rect, glowPaint);
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.5, cy + 2), 8.0, blackPaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.5 - 2, cy - 1), 2.2, whitePaint);
        final path = Path();
        if (isLeft) {
          path.moveTo(cx - 18, cy - 22);
          path.lineTo(cx + 18, cy - 22);
          path.lineTo(cx + 18, cy - 2);
          path.close();
          canvas.drawPath(path, blackPaint);
          canvas.drawLine(
              Offset(cx - 15, cy - 18), Offset(cx + 15, cy - 4), strokePaint);
        } else {
          path.moveTo(cx - 18, cy - 22);
          path.lineTo(cx + 18, cy - 22);
          path.lineTo(cx - 18, cy - 2);
          path.close();
          canvas.drawPath(path, blackPaint);
          canvas.drawLine(
              Offset(cx - 15, cy - 4), Offset(cx + 15, cy - 18), strokePaint);
        }
        break;

      case RobotExpression.triste:
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
          const Radius.circular(11),
        );
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.5, cy + 6), 8.5, blackPaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.5 - 2.5, cy + 3), 2.5, whitePaint);
        final path = Path();
        if (isLeft) {
          path.moveTo(cx - 18, cy - 22);
          path.lineTo(cx + 18, cy - 22);
          path.lineTo(cx - 18, cy);
          path.close();
        } else {
          path.moveTo(cx - 18, cy - 22);
          path.lineTo(cx + 18, cy - 22);
          path.lineTo(cx + 18, cy);
          path.close();
        }
        canvas.drawPath(path, blackPaint);
        break;

      case RobotExpression.surpreso:
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: 35, height: 44),
          const Radius.circular(16),
        );
        canvas.drawRRect(rect, glowPaint);
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.4, cy + pupY * 0.4), 5.8, blackPaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.4 - 2, cy + pupY * 0.4 - 2), 2.0, whitePaint);
        canvas.drawLine(
            Offset(cx - 12, cy - 24), Offset(cx + 12, cy - 24), strokePaint);
        break;

      case RobotExpression.curioso:
        final eyeH = isLeft ? 26.0 : 44.0;
        final eyeY = isLeft ? cy + 3.0 : cy - 1.0;
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, eyeY), width: w, height: eyeH),
          const Radius.circular(10),
        );
        canvas.drawRRect(rect, whitePaint);
        final px = pupX == 0 ? 4.0 : pupX;
        canvas.drawCircle(Offset(cx + px, eyeY), 7.8, blackPaint);
        canvas.drawCircle(Offset(cx + px - 2.5, eyeY - 2.5), 2.5, whitePaint);
        if (!isLeft) {
          canvas.drawLine(
              Offset(cx - 13, cy - 25), Offset(cx + 13, cy - 22), strokePaint);
        }
        break;

      case RobotExpression.sonolento:
        final breath = math.sin(phase * math.pi * 2) * 1.5;
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
          const Radius.circular(11),
        );
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(
            Offset(cx + pupX * 0.3, cy + 6), 8.0, blackPaint);
        canvas.drawRect(
          Rect.fromLTWH(cx - 17, cy - 21, 34, 21 + breath),
          blackPaint,
        );
        canvas.drawLine(
          Offset(cx - 16, cy + breath),
          Offset(cx + 16, cy + breath),
          strokePaint,
        );
        break;

      case RobotExpression.animado:
        final pulse = math.sin(phase * math.pi * 12) * 1.3;
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(cx, cy), width: 34 + pulse, height: 42 + pulse),
          const Radius.circular(13),
        );
        canvas.drawRRect(rect, glowPaint);
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(Offset(cx + pupX, cy + pupY), 8.8, blackPaint);
        canvas.drawCircle(
            Offset(cx + pupX - 3, cy + pupY - 3), 3.0, whitePaint);
        canvas.drawCircle(
            Offset(cx + pupX + 3, cy + pupY + 3), 1.8, whitePaint);
        canvas.drawCircle(Offset(cx, cy + 23), 14.0, blackPaint);
        break;

      case RobotExpression.confuso:
        final eyeH = isLeft ? 40.0 : 28.0;
        final yOff = isLeft ? -3.0 : 4.0;
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(cx, cy + yOff), width: w, height: eyeH),
          const Radius.circular(10),
        );
        canvas.drawRRect(rect, whitePaint);
        final pDir = isLeft ? -3.0 : 4.0;
        canvas.drawCircle(Offset(cx + pDir, cy + yOff), 7.2, blackPaint);
        canvas.drawCircle(
            Offset(cx + pDir - 2, cy + yOff - 2), 2.2, whitePaint);
        if (isLeft) {
          canvas.drawLine(
              Offset(cx - 14, cy - 24), Offset(cx + 14, cy - 20), strokePaint);
        } else {
          canvas.drawLine(
              Offset(cx - 14, cy - 14), Offset(cx + 14, cy - 18), strokePaint);
        }
        break;

      case RobotExpression.assustado:
        final jx = math.sin(phase * math.pi * 28) * 1.2;
        final jy = math.cos(phase * math.pi * 22) * 1.0;
        final rect = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(cx + jx, cy + jy), width: 30, height: 40),
          const Radius.circular(12),
        );
        canvas.drawRRect(rect, whitePaint);
        canvas.drawCircle(Offset(cx + jx * 2, cy + jy), 4.0, blackPaint);
        if (isLeft) {
          canvas.drawLine(
              Offset(cx - 14, cy - 18), Offset(cx + 12, cy - 24), strokePaint);
        } else {
          canvas.drawLine(
              Offset(cx - 12, cy - 24), Offset(cx + 14, cy - 18), strokePaint);
        }
        break;

      case RobotExpression.apaixonado:
        final beat = 14.0 + math.sin(phase * math.pi * 10).abs() * 2.5;
        _drawHeart(canvas, Offset(cx, cy - 1), beat, whitePaint, glowPaint);
        break;

      case RobotExpression.piscando:
        final winkRight = (phase % 0.5) < 0.25;
        final thisWinks = winkRight ? !isLeft : isLeft;
        if (thisWinks) {
          if (isLeft) {
            canvas.drawLine(
                Offset(cx - 12, cy - 6), Offset(cx + 10, cy), strokePaint);
            canvas.drawLine(
                Offset(cx - 12, cy + 6), Offset(cx + 10, cy), strokePaint);
          } else {
            canvas.drawLine(
                Offset(cx + 12, cy - 6), Offset(cx - 10, cy), strokePaint);
            canvas.drawLine(
                Offset(cx + 12, cy + 6), Offset(cx - 10, cy), strokePaint);
          }
        } else {
          final rect = RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(cx, cy), width: w, height: h),
            const Radius.circular(11),
          );
          canvas.drawRRect(rect, whitePaint);
          canvas.drawCircle(Offset(cx + pupX, cy), 8.0, blackPaint);
          canvas.drawCircle(
              Offset(cx + pupX - 3, cy - 3), 2.8, whitePaint);
        }
        break;
    }
  }

  void _drawHeart(
    Canvas canvas,
    Offset center,
    double radius,
    Paint fill,
    Paint glow,
  ) {
    final lobeOff = radius * 0.55;
    final lobeRad = radius * 0.58;
    final path = Path()
      ..addOval(Rect.fromCircle(
          center: Offset(center.dx - lobeOff, center.dy - lobeOff * 0.5),
          radius: lobeRad))
      ..addOval(Rect.fromCircle(
          center: Offset(center.dx + lobeOff, center.dy - lobeOff * 0.5),
          radius: lobeRad));
    final tri = Path()
      ..moveTo(center.dx - radius - 1, center.dy - 1)
      ..lineTo(center.dx + radius + 1, center.dy - 1)
      ..lineTo(center.dx, center.dy + radius + 2)
      ..close();
    canvas.drawPath(path, glow);
    canvas.drawPath(tri, glow);
    canvas.drawPath(path, fill);
    canvas.drawPath(tri, fill);
  }

  void _drawMouthAndExtras(Canvas canvas, Paint whitePaint, Paint strokePaint) {
    switch (expression) {
      case RobotExpression.feliz:
      case RobotExpression.animado:
      case RobotExpression.apaixonado:
        final path = Path()
          ..moveTo(54, 57)
          ..quadraticBezierTo(64, 63, 74, 57);
        canvas.drawPath(path, strokePaint);
        break;

      case RobotExpression.bravo:
        final path = Path()
          ..moveTo(48, 60)
          ..lineTo(58, 55)
          ..lineTo(70, 55)
          ..lineTo(80, 60);
        canvas.drawPath(path, strokePaint);
        break;

      case RobotExpression.triste:
        final path = Path()
          ..moveTo(54, 61)
          ..quadraticBezierTo(64, 55, 74, 61);
        canvas.drawPath(path, strokePaint);
        final tearY = 46.0 + ((phase * 4) % 1.0) * 14.0;
        canvas.drawCircle(Offset(102, tearY), 2.2, whitePaint);
        break;

      case RobotExpression.surpreso:
        canvas.drawCircle(const Offset(64, 58), 4.0, strokePaint);
        break;

      case RobotExpression.sonolento:
        final zStep = ((phase * 6).floor()) % 3;
        _drawHudText(canvas, 'z', const Offset(109, 25), Colors.white);
        if (zStep >= 1) {
          _drawHudText(canvas, 'Z', const Offset(115, 17), Colors.white);
        }
        if (zStep >= 2) {
          _drawHudText(canvas, 'Z', const Offset(120, 9), Colors.white);
        }
        break;

      case RobotExpression.confuso:
        final path = Path()
          ..moveTo(52, 59)
          ..lineTo(60, 56)
          ..lineTo(67, 60)
          ..lineTo(75, 57);
        canvas.drawPath(path, strokePaint);
        _drawHudText(canvas, '?', const Offset(61, 9), Colors.white);
        break;

      case RobotExpression.assustado:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(56, 55, 16, 7),
            const Radius.circular(2),
          ),
          strokePaint,
        );
        break;

      case RobotExpression.piscando:
        final path = Path()
          ..moveTo(57, 59)
          ..lineTo(68, 59)
          ..lineTo(75, 55);
        canvas.drawPath(path, strokePaint);
        break;

      default:
        break;
    }
  }

  void _drawHudText(Canvas canvas, String text, Offset pos, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: GoogleFonts.jetBrainsMono(
          color: color,
          fontSize: 7.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _Oled128x64Painter oldDelegate) => true;
}
