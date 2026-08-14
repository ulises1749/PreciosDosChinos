import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class SheetRectificationService {
  const SheetRectificationService._();

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

    final detection = source.width > 1000
        ? img.copyResize(source, width: 1000, interpolation: img.Interpolation.linear)
        : source;

    final corners = _findSheet(detection);
    if (corners == null) {
      return Uint8List.fromList(img.encodeJpg(source, quality: 95));
    }

    final sx = source.width / detection.width;
    final sy = source.height / detection.height;
    final mapped = corners.map((p) => img.Point(p.x * sx, p.y * sy)).toList();

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
    if (w < 200 || h < 150) return null;

    final threshold = _adaptiveThreshold(image);
    final mask = Uint8List(w * h);

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        final lum = _lum(p);
        final sat = _sat(p);
        if (lum >= threshold && sat < 115) {
          mask[y * w + x] = 1;
        }
      }
    }

    final radius = math.max(4, math.min(12, math.min(w, h) ~/ 140));
    _close(mask, w, h, radius);

    final rows = <_Span>[];
    for (var y = 0; y < h; y++) {
      var count = 0;
      var minX = w;
      var maxX = -1;
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] != 0) {
          count++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
        }
      }
      if (count > w * 0.28 && maxX > minX) {
        rows.add(_Span(y.toDouble(), minX.toDouble(), maxX.toDouble(), count));
      }
    }

    if (rows.length < h * 0.18) return null;

    final usableRows = rows
        .where((r) => r.y > h * 0.04 && r.y < h * 0.96)
        .toList();
    if (usableRows.length < h * 0.12) return null;

    final topRows = usableRows.take(math.max(5, usableRows.length ~/ 5)).toList();
    final bottomRows = usableRows.skip(math.max(0, usableRows.length * 4 ~/ 5)).toList();

    final leftLine = _fitLine(usableRows.map((r) => _Pair(r.y, r.minX)).toList());
    final rightLine = _fitLine(usableRows.map((r) => _Pair(r.y, r.maxX)).toList());
    if (leftLine == null || rightLine == null) return null;

    final top = _median(topRows.map((r) => r.y));
    final bottom = _median(bottomRows.map((r) => r.y));
    if (bottom - top < h * 0.35) return null;

    final tl = img.Point(_lineAt(leftLine, top), top);
    final tr = img.Point(_lineAt(rightLine, top), top);
    final bl = img.Point(_lineAt(leftLine, bottom), bottom);
    final br = img.Point(_lineAt(rightLine, bottom), bottom);

    final topBottom = _columnBounds(
      mask,
      w,
      h,
      tl.x.toDouble(),
      tr.x.toDouble(),
      top,
      bottom,
    );
    final topY = topBottom.$1;
    final bottomY = topBottom.$2;

    final finalTl = img.Point(_lineAt(leftLine, topY), topY);
    final finalTr = img.Point(_lineAt(rightLine, topY), topY);
    final finalBl = img.Point(_lineAt(leftLine, bottomY), bottomY);
    final finalBr = img.Point(_lineAt(rightLine, bottomY), bottomY);

    final area = _quadArea([finalTl, finalTr, finalBr, finalBl]);
    if (area < w * h * 0.12 || area > w * h * 0.96) return null;

    final widthTop = _distance(finalTl, finalTr);
    final widthBottom = _distance(finalBl, finalBr);
    final heightLeft = _distance(finalTl, finalBl);
    final heightRight = _distance(finalTr, finalBr);
    if (widthTop < w * 0.3 || widthBottom < w * 0.3) return null;
    if (heightLeft < h * 0.25 || heightRight < h * 0.25) return null;

    return [finalTl, finalTr, finalBr, finalBl];
  }

  static (double, double) _columnBounds(
    Uint8List mask,
    int w,
    int h,
    double left,
    double right,
    double top,
    double bottom,
  ) {
    final x0 = math.max(0, left.round());
    final x1 = math.min(w - 1, right.round());
    final y0 = math.max(0, top.round());
    final y1 = math.min(h - 1, bottom.round());
    final candidatesTop = <double>[];
    final candidatesBottom = <double>[];
    for (var x = x0; x <= x1; x += math.max(1, (x1 - x0) ~/ 200)) {
      var first = -1;
      var last = -1;
      for (var y = y0; y <= y1; y++) {
        if (mask[y * w + x] != 0) {
          first = y;
          break;
        }
      }
      for (var y = y1; y >= y0; y--) {
        if (mask[y * w + x] != 0) {
          last = y;
          break;
        }
      }
      if (first >= 0 && last > first) {
        candidatesTop.add(first.toDouble());
        candidatesBottom.add(last.toDouble());
      }
    }
    if (candidatesTop.isEmpty || candidatesBottom.isEmpty) return (top, bottom);
    return (_median(candidatesTop), _median(candidatesBottom));
  }

  static double _adaptiveThreshold(img.Image image) {
    final values = <double>[];
    final sx = math.max(1, image.width ~/ 60);
    final sy = math.max(1, image.height ~/ 60);
    for (var y = 0; y < image.height; y += sy) {
      for (var x = 0; x < image.width; x += sx) {
        values.add(_lum(image.getPixel(x, y)));
      }
    }
    values.sort();
    final p70 = values[(values.length * 0.70).floor().clamp(0, values.length - 1)];
    return math.max(145.0, math.min(225.0, p70 - 8));
  }

  static void _close(Uint8List mask, int w, int h, int radius) {
    final dilated = Uint8List(mask.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var found = false;
        for (var dy = -radius; dy <= radius && !found; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (var dx = -radius; dx <= radius; dx++) {
            final xx = x + dx;
            if (xx >= 0 && xx < w && mask[yy * w + xx] != 0) {
              found = true;
              break;
            }
          }
        }
        if (found) dilated[y * w + x] = 1;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var filled = true;
        for (var dy = -radius; dy <= radius && filled; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= h) {
            filled = false;
            break;
          }
          for (var dx = -radius; dx <= radius; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= w || dilated[yy * w + xx] == 0) {
              filled = false;
              break;
            }
          }
        }
        mask[y * w + x] = filled ? 1 : 0;
      }
    }
  }

  static _Pair? _fitLine(List<_Pair> points) {
    if (points.length < 10) return null;
    var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0;
    for (final p in points) {
      sumX += p.x;
      sumY += p.y;
      sumXX += p.x * p.x;
      sumXY += p.x * p.y;
    }
    final n = points.length.toDouble();
    final denom = n * sumXX - sumX * sumX;
    if (denom.abs() < 1e-6) return null;
    final slope = (n * sumXY - sumX * sumY) / denom;
    final intercept = (sumY - slope * sumX) / n;
    return _Pair(slope, intercept);
  }

  static double _lineAt(_Pair line, double y) => line.x * y + line.y;

  static double _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return 0;
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double _lum(img.Pixel p) =>
      (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).toDouble();

  static double _sat(img.Pixel p) {
    final maxC = math.max(p.r, math.max(p.g, p.b));
    final minC = math.min(p.r, math.min(p.g, p.b));
    return (maxC - minC).toDouble();
  }

  static double _distance(img.Point a, img.Point b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _quadArea(List<img.Point> p) {
    var area = 0.0;
    for (var i = 0; i < p.length; i++) {
      final j = (i + 1) % p.length;
      area += p[i].x * p[j].y - p[j].x * p[i].y;
    }
    return area.abs() / 2;
  }
}

class _Span {
  const _Span(this.y, this.minX, this.maxX, this.count);
  final double y;
  final double minX;
  final double maxX;
  final int count;
}

class _Pair {
  const _Pair(this.x, this.y);
  final double x;
  final double y;
}
