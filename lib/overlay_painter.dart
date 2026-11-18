import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'detection.dart';

const Color kShelfColor = Color(0xFF2979FF);
const Color kProductColor = Color(0xFF00E676);
const Color kEmptyColor = Color(0xFFFF1744);

/// Draws shelves (blue mask + box), products (green) and empty space (red)
/// over a widget whose aspect ratio equals the upright image.
class DetectionPainter extends CustomPainter {
  final ValueListenable<DetectionResult?> result;
  final bool showLabels;

  DetectionPainter(this.result, {this.showLabels = true}) : super(repaint: result);

  @override
  void paint(Canvas canvas, Size size) {
    final r = result.value;
    if (r == null) return;
    Rect px(Rect n) => Rect.fromLTRB(
        n.left * size.width, n.top * size.height, n.right * size.width, n.bottom * size.height);

    // shelves
    final fill = Paint()..color = kShelfColor.withValues(alpha: 0.18);
    final stroke = Paint()
      ..color = kShelfColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    for (int i = 0; i < r.shelves.length; i++) {
      final s = r.shelves[i];
      final path = Path();
      for (final run in s.runs) {
        path.addRect(px(run));
      }
      canvas.drawPath(path, fill);
      final b = px(s.box);
      canvas.drawRect(b, stroke);
      if (showLabels) _label(canvas, 'shelf ${(s.conf * 100).round()}%', b.topLeft, kShelfColor, 13);
    }

    // products + empty space
    final pp = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final d in r.products) {
      final col = d.cls == 1 ? kProductColor : kEmptyColor;
      pp.color = col;
      final b = px(d.box);
      canvas.drawRect(b, pp);
      if (showLabels && b.width > 34) {
        _label(canvas, '${d.label} ${(d.conf * 100).round()}%', b.topLeft, col, 9);
      }
    }
  }

  void _label(Canvas canvas, String text, Offset at, Color bg, double fs) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(color: Colors.black, fontSize: fs, fontWeight: FontWeight.w600)),
      textDirection: TextDirection.ltr,
    )..layout();
    final y = at.dy - tp.height < 0 ? at.dy : at.dy - tp.height;
    canvas.drawRect(Rect.fromLTWH(at.dx, y, tp.width + 4, tp.height), Paint()..color = bg);
    tp.paint(canvas, Offset(at.dx + 2, y));
  }

  @override
  bool shouldRepaint(covariant DetectionPainter old) =>
      old.showLabels != showLabels || old.result != result;
}
