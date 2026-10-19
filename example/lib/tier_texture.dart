import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Draws a square texture at runtime: a gradient with a ring and a centered
/// label, encoded to PNG for [GlbMaterialOverride.baseColorTexture]. This is
/// how an app can make per-tier badge faces without shipping extra images.
Future<Uint8List> drawTierTexture(
  String label,
  List<Color> gradient, {
  int size = 512,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: gradient,
      ).createShader(rect),
  );
  canvas.drawCircle(
    rect.center,
    size * 0.38,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.04
      ..color = const Color(0xFFFFFFFF),
  );
  final text = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        color: const Color(0xFFFFFFFF),
        fontSize: size * 0.16,
        fontWeight: FontWeight.w800,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  text.paint(canvas, rect.center - Offset(text.width / 2, text.height / 2));
  text.dispose();

  final image = await recorder.endRecording().toImage(size, size);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}
