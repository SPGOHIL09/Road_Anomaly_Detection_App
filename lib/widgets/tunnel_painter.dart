import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class TunnelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Deep dark bg
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()
          ..shader = RadialGradient(
            center: Alignment.center,
            radius: 1.2,
            colors: [const Color(0xFF0A1E35), AppColors.backgroundDark],
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height)));

    final cx = size.width / 2;
    final roadBottom = size.height;
    final vanishY = size.height * 0.42;

    // Road
    final roadPath = Path()
      ..moveTo(0, roadBottom)
      ..lineTo(cx - 8, vanishY)
      ..lineTo(cx + 8, vanishY)
      ..lineTo(size.width, roadBottom)
      ..close();
    canvas.drawPath(roadPath, Paint()..color = const Color(0xFF0D1520));

    // Road centre line
    canvas.drawLine(
        Offset(cx, roadBottom),
        Offset(cx, vanishY),
        Paint()
          ..color = const Color(0xFFD4891A)
          ..strokeWidth = 3);

    // Glowing arcs
    for (int i = 6; i >= 1; i--) {
      final t = i / 6.0;
      final rx = size.width * 0.52 * t;
      final ry = size.height * 0.30 * t;
      canvas.drawArc(
        Rect.fromCenter(
            center: Offset(cx, roadBottom * 0.78),
            width: rx * 2,
            height: ry),
        -3.14159, 3.14159, false,
        Paint()
          ..color = AppColors.primary.withOpacity(0.06 + (1 - t) * 0.18)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    }

    // Digital rain particles
    final particlePaint = Paint()
      ..color = AppColors.primary.withOpacity(0.25)
      ..strokeWidth = 1;
    for (int i = 0; i < 30; i++) {
      final x = (size.width / 30) * i;
      final y1 = (size.height * 0.05) + (i * 19) % (size.height * 0.55);
      canvas.drawLine(Offset(x, y1), Offset(x, y1 + 10), particlePaint);
    }
  }

  @override
  bool shouldRepaint(_) => false;
}