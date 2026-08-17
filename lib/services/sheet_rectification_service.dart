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
        ? img.copyResize(
            source,
            width: 1000,
            interpolation: img.Interpolation.linear,
          )
        : source;

    final corners = _findSheet(detection);
    if (corners == null) {
      return Uint8List.fromList(img.encodeJpg(source, quality: 95));
    }

    final sx = source.width / detection.width;
    final sy = source.height / detection.height;
    final mapped = corners
        .map(
          (p) => img.Point(
            (p.x * sx).toDouble(),
            (p.y * sy).toDouble(),
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

  /// Detects the outer paper quadrilateral from the large bright region.
  ///
  /// The previous radial-ray detector could confuse the dark grid lines,
  /// handwriting, shadows and the paper clip with the physical sheet border.
  /// This detector instead follows the large continuous bright span in each
  /// image row and fits the two long side edges of the sheet.
  static List<img.Point>? _findSheet(img.Image image) {
    final w = image.width;
    final h = image.height;
    if (w < 240 || h < 180) return null;

    final threshold = _adaptiveThreshold(image);
    final rows = <_Span>[];

    const sampleStep = 2;
    const gapTolerance = 12;

    for (var y = 0; y < h; y++) {
      var runStart = -1;
      var bestStart = -1;
      var bestEnd = -1;
      var lastPaper = -1;
      var paperCount = 0;

      for (var x = 0; x < w; x += sampleStep) {
        final p = image.getPixel(x, y);
        final isPaper = _lum(p) >= threshold && _sat(p) < 110;

        if (isPaper) {
          if (runStart < 0) runStart = x;
          lastPaper = x;
          paperCount++;
        } else if (runStart >= 0 && x - lastPaper > gapTolerance) {
          if (lastPaper - runStart > bestEnd - bestStart) {
            bestStart = runStart;
            bestEnd = lastPaper;
          }
          runStart = -1;
        }
      }

      if (runStart >= 0 &&
          lastPaper - runStart > bestEnd - bestStart) {
        bestStart = runStart;
        bestEnd = lastPaper;
      }

      final spanWidth = bestEnd - bestStart;
      if (bestStart >= 0 &&
          spanWidth > w * 0.40 &&
          paperCount >= (spanWidth / sampleStep) * 0.22) {
        rows.add(
          _Span(
            y.toDouble(),
            bestStart.toDouble(),
            bestEnd.toDouble(),
            paperCount,
          ),
        );
      }
    }

    if (rows.length < h * 0.12) return null;

    final usable = rows
        .where((r) => r.y >= h * 0.04 && r.y <= h * 0.96)
        .toList();

    if (usable.length < h * 0.10) return null;

    final band = _largestRowBand(usable);
    if (band.length < h * 0.10) return null;

    final leftPoints = band.map((r) => _Pair(r.y, r.minX)).toList();
    final rightPoints = band.map((r) => _Pair(r.y, r.maxX)).toList();

    final leftLine = _robustFitLine(leftPoints);
    final rightLine = _robustFitLine(rightPoints);
    if (leftLine == null || rightLine == null) return null;

    final top = band.first.y;
    final bottom = band.last.y;

    final quad = <img.Point>[
      img.Point(_lineAt(leftLine, top), top),
      img.Point(_lineAt(rightLine, top), top),
      img.Point(_lineAt(rightLine, bottom), bottom),
      img.Point(_lineAt(leftLine, bottom), bottom),
    ];

    if (!_validQuad(quad, w, h)) return null;
    return quad;
  }

  static List<_Span> _largestRowBand(List<_Span> rows) {
    if (rows.isEmpty) return const [];

    var current = <_Span>[];
    var best = <_Span>[];

    for (final row in rows) {
      if (current.isEmpty || row.y - current.last.y <= 3) {
        current.add(row);
      } else {
        if (current.length > best.length) best = current;
        current = <_Span>[row];
      }
    }

    if (current.length > best.length) best = current;
    return best;
  }

  static _Pair? _robustFitLine(List<_Pair> points) {
    if (points.length < 10) return null;

    var working = List<_Pair>.from(points);

    for (var round = 0; round < 3; round++) {
      final line = _fitLine(working);
      if (line == null) return null;

      final residuals = working
          .map((p) => (p.y - _lineAt(line, p.x)).abs())
          .toList()
        ..sort();

      final cutoffIndex = _clampIndex(
        (residuals.length * 0.82).floor(),
        residuals.length - 1,
      );
      final cutoff = math.max(8.0, residuals[cutoffIndex]).toDouble();

      working = working
          .where((p) => (p.y - _lineAt(line, p.x)).abs() <= cutoff)
          .toList();

      if (working.length < 10) return line;
    }

    return _fitLine(working);
  }

  static _Pair? _fitLine(List<_Pair> points) {
    if (points.length < 10) return null;

    var sumX = 0.0;
    var sumY = 0.0;
    var sumXX = 0.0;
    var sumXY = 0.0;

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

  static double _lineAt(_Pair line, double x) {
    return line.x * x + line.y;
  }

  static bool _validQuad(List<img.Point> p, int w, int h) {
    if (p.length != 4) return false;

    final area = _quadArea(p);
    if (area < w * h * 0.20 || area > w * h * 0.99) return false;

    final top = _distance(p[0], p[1]);
    final bottom = _distance(p[3], p[2]);
    final left = _distance(p[0], p[3]);
    final right = _distance(p[1], p[2]);

    if (top < w * 0.40 || bottom < w * 0.40) return false;
    if (left < h * 0.30 || right < h * 0.30) return false;

    return true;
  }

  static double _adaptiveThreshold(img.Image image) {
    final values = <double>[];
    final sx = math.max(1, image.width ~/ 50).toInt();
    final sy = math.max(1, image.height ~/ 50).toInt();

    for (var y = 0; y < image.height; y += sy) {
      for (var x = 0; x < image.width; x += sx) {
        values.add(_lum(image.getPixel(x, y)));
      }
    }

    values.sort();
    if (values.isEmpty) return 165.0;

    final p55Index = _clampIndex(
      (values.length * 0.55).floor(),
      values.length - 1,
    );
    final p55 = values[p55Index];

    return math.max(135.0, math.min(210.0, p55 - 8.0)).toDouble();
  }

  static int _clampIndex(int value, int max) {
    if (value < 0) return 0;
    if (value > max) return max;
    return value;
  }

  static double _lum(img.Pixel p) {
    return (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).toDouble();
  }

  static double _sat(img.Pixel p) {
    final maxC = math.max(p.r, math.max(p.g, p.b));
    final minC = math.min(p.r, math.min(p.g, p.b));
    return (maxC - minC).toDouble();
  }

  static double _distance(img.Point a, img.Point b) {
    final dx = a.x.toDouble() - b.x.toDouble();
    final dy = a.y.toDouble() - b.y.toDouble();
    return math.sqrt(dx * dx + dy * dy);
  }

  static double _quadArea(List<img.Point> p) {
    var area = 0.0;

    for (var i = 0; i < p.length; i++) {
      final j = (i + 1) % p.length;
      area +=
          p[i].x.toDouble() * p[j].y.toDouble() -
          p[j].x.toDouble() * p[i].y.toDouble();
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
