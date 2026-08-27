import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/mjpeg_stream.dart';

/// Лайв-видео: кадры MjpegStream с поворотом, как на веб-странице робота:
/// при 90/270 сцена вертикальная (3:4), иначе 4:3; повёрнутый кадр
/// заполняет сцену целиком, без чёрных полей.
class MjpegView extends StatefulWidget {
  const MjpegView({super.key, required this.stream, required this.rot});

  final MjpegStream stream;
  final int rot; // 0/90/180/270

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  @override
  Widget build(BuildContext context) {
    final bool vertical = widget.rot % 180 != 0;
    return LayoutBuilder(builder: (context, constraints) {
      // декодируем кадр под фактический размер виджета (экономия памяти)
      final double dpr = MediaQuery.devicePixelRatioOf(context);
      final double biggest = math.max(constraints.maxWidth,
          constraints.maxHeight == double.infinity
              ? constraints.maxWidth
              : constraints.maxHeight);
      final int tw = (biggest * dpr).clamp(320, 1920).round();
      if (widget.stream.targetWidth != tw) {
        widget.stream.targetWidth = tw;
      }
      return AspectRatio(
        aspectRatio: vertical ? 3 / 4 : 4 / 3,
        child: ClipRect(
          child: ColoredBox(
            color: Colors.black,
            child: ListenableBuilder(
              listenable: widget.stream,
              builder: (context, _) => CustomPaint(
                foregroundPainter:
                    FramePainter(widget.stream.image, widget.rot),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Рисует кадр, повёрнутый на rot и растянутый «cover» по сцене.
class FramePainter extends CustomPainter {
  FramePainter(this.image, this.rot);

  final ui.Image? image;
  final int rot;

  @override
  void paint(Canvas canvas, Size size) {
    final ui.Image? img = image;
    if (img == null || size.isEmpty) {
      return;
    }
    final bool rotated = rot % 180 != 0;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(rot * math.pi / 180);
    // после поворота кадр занимает сцену «наоборот»: для заполнения без полей
    // масштаб — max(w/ih, h/iw), где i* — стороны кадра (аналог CSS 133.333%)
    final double k = rotated
        ? math.max(size.width / img.height, size.height / img.width)
        : math.max(size.width / img.width, size.height / img.height);
    final double dw = img.width * k;
    final double dh = img.height * k;
    final Paint paint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(-dw / 2, -dh / 2, dw, dh),
      paint,
    );
  }

  @override
  bool shouldRepaint(FramePainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.rot != rot;
}
