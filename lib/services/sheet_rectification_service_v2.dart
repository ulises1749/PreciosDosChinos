import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Rectifies photographed daily-distribution sheets.
///
/// The detector looks for the paper/background transition. Grid lines are
/// dark on both sides, so they do not score nearly as well as the four
/// outer borders.
class SheetRectificationServiceV2 {
  const SheetRectificationServiceV2._();

  static Uint8List process(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    var source = img.bakeOrientation(decoded);
    if (source.height > source.width) {
      source = img.copyRotate(
        source,
        angle: 90,
        interpolation: img.Interpolation.linear,
      );
    }

    final detection = source.width > 900
        ? img.copyResize(
            source,
            width: 900,
            interpolation: img.Interpolation.linear,
          )
        : source;

    final corners = _findSheet(detection);
    if (corners == null) {
      return Uint8List.fromList(img.encodeJpg(source, quality: 95));
    }

    final sx = source.width.toDouble() / detection.width.toDouble();
    final sy = source.height.toDouble() / detection.height.toDouble();
    final mapped = corners
        .map(
          (p) => img.Point(
            p.x.toDouble() * sx,
            p.y.toDouble() * sy,
          ),
        )
        .toList();

    final rectified = img.copyRectify(
      source,
      topLeft: mapped[0],
      topRight: mapped[1],
      bottomLeft: mapped[3],
      bottomRight: mapped[2],
      interpolation: img.Interpolation.linear,
    );

    return Uint8List.fromList(img.encodeJpg(rectified, quality: 95));
  }

  static List<img.Point>? _findSheet(img.Image image) {
    final w = image.width;
    final h = image.height;
    if (w < 240 || h < 180) return null;

    final top = _findHorizontalBorder(
      image,
      from: h * 0.02,
      to: h * 0.45,
      topBorder: true,
    );
    final bottom = _findHorizontalBorder(
      image,
      from: h * 0.55,
      to: h * 0.98,
      topBorder: false,
    );
    final left = _findVerticalBorder(
      image,
      from: w * 0.02,
      to: w * 0.45,
      leftBorder: true,
    );
    final right = _findVerticalBorder(
      image,
      from: w * 0.55,
      to: w * 0.98,
      leftBorder: false,
    );

    if (top == null || bottom == null || left == null || right == null) {
      return null;
    }

    final topLeft = _intersection(left, top);
    final topRight = _intersection(right, top);
    final bottomRight = _intersection(right, bottom);
    final bottomLeft = _intersection(left, bottom);
    if (topLeft == null ||
        topRight == null ||
        bottomRight == null ||
        bottomLeft == null) {
      return null;
    }

    final quad = <img.Point>[topLeft, topRight, bottomRight, bottomLeft];
    return _validQuad(quad, w, h) ? quad : null;
  }

  static _Line? _findHorizontalBorder(
    img.Image image, {
    required double from,
    required double to,
    required bool topBorder,
  }) {
    final h = image.height.toDouble();
    final yStep = math.max(2, (h / 90).round());
    var bestScore = -double.infinity;
    _Line? best;

    for (var yInt = from; yInt <= to; yInt += yStep.toDouble()) {
      for (var slopeInt = -28; slopeInt <= 28; slopeInt++) {
        final slope = slopeInt.toDouble() / 100.0;
        final line = _Line(slope, yInt);
        final score = _scoreHorizontal(image, line, topBorder);
        if (score > bestScore) {
          bestScore = score;
          best = line;
        }
      }
    }

    if (best == null || bestScore < 8.0) return null;
    return best;
  }

  static _Line? _findVerticalBorder(
    img.Image image, {
    required double from,
    required double to,
    required bool leftBorder,
  }) {
    final w = image.width.toDouble();
    final xStep = math.max(2, (w / 90).round());
    var bestScore = -double.infinity;
    _Line? best;

    for (var xInt = from; xInt <= to; xInt += xStep.toDouble()) {
      for (var slopeInt = -28; slopeInt <= 28; slopeInt++) {
        final slope = slopeInt.toDouble() / 100.0;
        final line = _Line(slope, xInt);
        final score = _scoreVertical(image, line, leftBorder);
        if (score > bestScore) {
          bestScore = score;
          best = line;
        }
      }
    }

    if (best == null || bestScore < 8.0) return null;
    return best;
  }

  static double _scoreHorizontal(
    img.Image image,
    _Line line,
    bool topBorder,
  ) {
    final w = image.width;
    final y0 = image.height * 0.05;
    final y1 = image.height * 0.95;
    var total = 0.0;
    var count = 0;

    for (var i = 0; i < 96; i++) {
      final x = w * (0.05 + i * 0.90 / 95.0);
      final y = line.y + line.x * (x - w / 2.0);
      if (y < y0 || y >= y1) continue;

      final xi = x.round();
      final yi = y.round();
      final above = _lum(image.getPixel(xi, yi - 3));
      final below = _lum(image.getPixel(xi, yi + 3));
      final signed = topBorder ? below - above : above - below;
      final edge = (below - above).abs();
      total += math.max(0.0, signed) + edge * 0.35;
      count++;
    }

    return count < 50 ? -double.infinity : total / count.toDouble();
  }

  static double _scoreVertical(
    img.Image image,
    _Line line,
    bool leftBorder,
  ) {
    final h = image.height;
    final x0 = image.width * 0.05;
    final x1 = image.width * 0.95;
    var total = 0.0;
    var count = 0;

    for (var i = 0; i < 96; i++) {
      final y = h * (0.05 + i * 0.90 / 95.0);
      final x = line.y + line.x * (y - h / 2.0);
      if (x < x0 || x >= x1) continue;

      final xi = x.round();
      final yi = y.round();
      final left = _lum(image.getPixel(xi - 3, yi));
      final right = _lum(image.getPixel(xi + 3, yi));
      final signed = leftBorder ? right - left : left - right;
      final edge = (right - left).abs();
      total += math.max(0.0, signed) + edge * 0.35;
      count++;
    }

    return count < 50 ? -double.infinity : total / count.toDouble();
  }

  static _Pair? _intersection(_Line side, _Line edge) {
    // side: x = a*y + b
    // edge: y = a*x + b
    final denominator = 1.0 - side.x * edge.x;
    if (denominator.abs() < 1e-6) return null;

    final x = (side.x * edge.y + side.y) / denominator;
    final y = edge.x * x + edge.y;
    return _Pair(x.toDouble(), y.toDouble());
  }

  static bool _validQuad(List<_Pair> p, int w, int h) {
    if (p.length != 4) return false;
    for (final point in p) {
      if (!point.x.isFinite || !point.y.isFinite) return false;
      if (point.x < -w * 0.10 || point.x > w * 1.10) return false;
      if (point.y < -h * 0.10 || point.y > h * 1.10) return false;
    }

    final area = _quadArea(p);
    if (area < w.toDouble() * h.toDouble() * 0.35) return false;

    final top = _distance(p[0], p[1]);
    final bottom = _distance(p[3], p[2]);
    final left = _distance(p[0], p[3]);
    final right = _distance(p[1], p[2]);

    return top >= w.toDouble() * 0.45 &&
        bottom >= w.toDouble() * 0.45 &&
        left >= h.toDouble() * 0.35 &&
        right >= h.toDouble() * 0.35;
  }

  static double _lum(img.Pixel p) {
    return (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).toDouble();
  }

  static double _distance(_Pair a, _Pair b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _quadArea(List<_Pair> p) {
    var area = 0.0;
    for (var i = 0; i < p.length; i++) {
      final j = (i + 1) % p.length;
      area += p[i].x * p[j].y - p[j].x * p[i].y;
    }
    return area.abs() / 2.0;
  }
}

class _Line {
  const _Line(this.x, this.y);
  final double x;
  final double y;
}

class _Pair {
  const _Pair(this.x, this.y);
  final double x;
  final double y;
}
