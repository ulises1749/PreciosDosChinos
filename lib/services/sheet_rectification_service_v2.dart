import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

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
            (p.x.toDouble() * sx).toDouble(),
            (p.y.toDouble() * sy).toDouble(),
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

    final threshold = _adaptiveThreshold(image);
    final rows = _scanRows(image, threshold);
    final columns = _scanColumns(image, threshold);

    if (rows.length < h * 0.10 || columns.length < w * 0.10) return null;

    final rowBand = _largestRowBand(
      rows.where((r) => r.y >= h * 0.03 && r.y <= h * 0.97).toList(),
    );
    final columnBand = _largestColumnBand(
      columns.where((c) => c.x >= w * 0.03 && c.x <= w * 0.97).toList(),
    );

    if (rowBand.length < h * 0.08 || columnBand.length < w * 0.08) {
      return null;
    }

    // Vertical sides are represented as x = a*y+b.
    final left = _robustFitLine(
      rowBand.map((r) => _Pair(r.y, r.minX)).toList(),
    );
    final right = _robustFitLine(
      rowBand.map((r) => _Pair(r.y, r.maxX)).toList(),
    );

    // Horizontal sides are represented as y = a*x+b.
    final top = _robustFitLine(
      columnBand.map((c) => _Pair(c.x, c.minY)).toList(),
    );
    final bottom = _robustFitLine(
      columnBand.map((c) => _Pair(c.x, c.maxY)).toList(),
    );

    if (left == null || right == null || top == null || bottom == null) {
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

  static List<_Span> _scanRows(img.Image image, double threshold) {
    final result = <_Span>[];
    const step = 2;
    const gap = 12;

    for (var y = 0; y < image.height; y++) {
      var start = -1;
      var last = -1;
      var bestStart = -1;
      var bestEnd = -1;
      var count = 0;

      for (var x = 0; x < image.width; x += step) {
        final p = image.getPixel(x, y);
        final paper = _lum(p) >= threshold && _sat(p) < 110;

        if (paper) {
          if (start < 0) start = x;
          last = x;
          count++;
        } else if (start >= 0 && x - last > gap) {
          if (last - start > bestEnd - bestStart) {
            bestStart = start;
            bestEnd = last;
          }
          start = -1;
        }
      }

      if (start >= 0 && last - start > bestEnd - bestStart) {
        bestStart = start;
        bestEnd = last;
      }

      final width = bestEnd - bestStart;
      if (bestStart >= 0 &&
          width > image.width * 0.40 &&
          count >= (width / step) * 0.22) {
        result.add(
          _Span(y.toDouble(), bestStart.toDouble(), bestEnd.toDouble()),
        );
      }
    }

    return result;
  }

  static List<_ColumnSpan> _scanColumns(img.Image image, double threshold) {
    final result = <_ColumnSpan>[];
    const step = 2;
    const gap = 12;

    for (var x = 0; x < image.width; x++) {
      var start = -1;
      var last = -1;
      var bestStart = -1;
      var bestEnd = -1;
      var count = 0;

      for (var y = 0; y < image.height; y += step) {
        final p = image.getPixel(x, y);
        final paper = _lum(p) >= threshold && _sat(p) < 110;

        if (paper) {
          if (start < 0) start = y;
          last = y;
          count++;
        } else if (start >= 0 && y - last > gap) {
          if (last - start > bestEnd - bestStart) {
            bestStart = start;
            bestEnd = last;
          }
          start = -1;
        }
      }

      if (start >= 0 && last - start > bestEnd - bestStart) {
        bestStart = start;
        bestEnd = last;
      }

      final height = bestEnd - bestStart;
      if (bestStart >= 0 &&
          height > image.height * 0.40 &&
          count >= (height / step) * 0.22) {
        result.add(
          _ColumnSpan(x.toDouble(), bestStart.toDouble(), bestEnd.toDouble()),
        );
      }
    }

    return result;
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

  static List<_ColumnSpan> _largestColumnBand(List<_ColumnSpan> columns) {
    if (columns.isEmpty) return const [];
    var current = <_ColumnSpan>[];
    var best = <_ColumnSpan>[];

    for (final column in columns) {
      if (current.isEmpty || column.x - current.last.x <= 3) {
        current.add(column);
      } else {
        if (current.length > best.length) best = current;
        current = <_ColumnSpan>[column];
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

      final index = _clampIndex(
        (residuals.length * 0.82).floor(),
        residuals.length - 1,
      );
      final cutoff = math.max(8.0, residuals[index]).toDouble();

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
    final denominator = n * sumXX - sumX * sumX;
    if (denominator.abs() < 1e-6) return null;

    final slope = (n * sumXY - sumX * sumY) / denominator;
    final intercept = (sumY - slope * sumX) / n;
    return _Pair(slope, intercept);
  }

  static double _lineAt(_Pair line, double x) {
    return line.x * x + line.y;
  }

  static img.Point? _intersection(_Pair side, _Pair edge) {
    final denominator = 1.0 - side.x * edge.x;
    if (denominator.abs() < 1e-6) return null;

    final x = (side.x * edge.y + side.y) / denominator;
    final y = edge.x * x + edge.y;
    return img.Point(x.toDouble(), y.toDouble());
  }

  static bool _validQuad(List<img.Point> p, int w, int h) {
    if (p.length != 4) return false;

    for (final point in p) {
      if (!point.x.isFinite || !point.y.isFinite) return false;
      if (point.x < -w * 0.15 || point.x > w * 1.15) return false;
      if (point.y < -h * 0.15 || point.y > h * 1.15) return false;
    }

    final area = _quadArea(p);
    if (area < w * h * 0.20 || area > w * h * 0.99) return false;

    final top = _distance(p[0], p[1]);
    final bottom = _distance(p[3], p[2]);
    final left = _distance(p[0], p[3]);
    final right = _distance(p[1], p[2]);

    return top >= w * 0.40 &&
        bottom >= w * 0.40 &&
        left >= h * 0.30 &&
        right >= h * 0.30;
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

    final index = _clampIndex(
      (values.length * 0.55).floor(),
      values.length - 1,
    );
    return math.max(135.0, math.min(210.0, values[index] - 8.0)).toDouble();
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
  const _Span(this.y, this.minX, this.maxX);
  final double y;
  final double minX;
  final double maxX;
}

class _ColumnSpan {
  const _ColumnSpan(this.x, this.minY, this.maxY);
  final double x;
  final double minY;
  final double maxY;
}

class _Pair {
  const _Pair(this.x, this.y);
  final double x;
  final double y;
}
