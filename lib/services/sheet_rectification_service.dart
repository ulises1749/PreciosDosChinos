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
        .map((p) => img.Point(
              (p.x * sx).toDouble(),
              (p.y * sy).toDouble(),
            ))
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

    final center = _findPaperCenter(image);
    final rays = <_RayHit>[];
    const rayCount = 96;

    for (var i = 0; i < rayCount; i++) {
      final angle = (2 * math.pi * i) / rayCount;
      final hit = _tracePaperBoundary(image, center.x, center.y, angle);
      if (hit != null) rays.add(hit);
    }

    if (rays.length < rayCount * 0.65) return _legacyFindSheet(image);

    final radii = List<double>.filled(rayCount, 0);
    final points = List<img.Point>.filled(
      rayCount,
      img.Point(0, 0),
    );
    final valid = List<bool>.filled(rayCount, false);

    for (final hit in rays) {
      final index = ((hit.angle / (2 * math.pi)) * rayCount).round() % rayCount;
      radii[index] = hit.radius;
      points[index] = hit.point;
      valid[index] = true;
    }

    if (valid.where((v) => v).length < rayCount * 0.65) {
      return _legacyFindSheet(image);
    }

    final smooth = List<double>.filled(rayCount, 0);
    for (var i = 0; i < rayCount; i++) {
      var total = 0.0;
      var count = 0;
      for (var d = -3; d <= 3; d++) {
        final j = (i + d + rayCount) % rayCount;
        if (valid[j]) {
          total += radii[j];
          count++;
        }
      }
      smooth[i] = count == 0 ? 0 : total / count;
    }

    final candidates = <_Peak>[];
    for (var i = 0; i < rayCount; i++) {
      final prev = smooth[(i - 2 + rayCount) % rayCount];
      final next = smooth[(i + 2) % rayCount];
      if (smooth[i] > prev && smooth[i] >= next && smooth[i] > math.min(w, h) * 0.30) {
        candidates.add(_Peak(i, smooth[i]));
      }
    }

    candidates.sort((a, b) => b.radius.compareTo(a.radius));

    final selected = <_Peak>[];
    for (final candidate in candidates) {
      final separated = selected.every((other) {
        var diff = (candidate.index - other.index).abs();
        diff = math.min(diff, rayCount - diff);
        return diff >= rayCount * 0.12;
      });
      if (separated) selected.add(candidate);
      if (selected.length == 4) break;
    }

    if (selected.length != 4) return _legacyFindSheet(image);

    selected.sort((a, b) => a.index.compareTo(b.index));
    final quad = selected.map((p) => points[p.index]).toList();
    final ordered = _orderQuad(quad);
    if (ordered == null || !_validQuad(ordered, w, h)) {
      return _legacyFindSheet(image);
    }

    return ordered;
  }

  static img.Point _findPaperCenter(img.Image image) {
    final w = image.width;
    final h = image.height;
    var bestX = w / 2;
    var bestY = h / 2;
    var bestScore = -1.0;

    final stepX = math.max(12, w ~/ 35);
    final stepY = math.max(12, h ~/ 35);
    final radiusX = math.max(6, w ~/ 55);
    final radiusY = math.max(6, h ~/ 55);

    for (var y = (h * 0.18).round(); y <= (h * 0.82).round(); y += stepY) {
      for (var x = (w * 0.18).round(); x <= (w * 0.82).round(); x += stepX) {
        var total = 0.0;
        var count = 0;
        for (var yy = y - radiusY; yy <= y + radiusY; yy += 2) {
          if (yy < 0 || yy >= h) continue;
          for (var xx = x - radiusX; xx <= x + radiusX; xx += 2) {
            if (xx < 0 || xx >= w) continue;
            total += _lum(image.getPixel(xx, yy));
            count++;
          }
        }
        final score = count == 0 ? 0.0 : total / count;
        if (score > bestScore) {
          bestScore = score;
          bestX = x.toDouble();
          bestY = y.toDouble();
        }
      }
    }

    return img.Point(bestX, bestY);
  }

  static _RayHit? _tracePaperBoundary(
    img.Image image,
    double cx,
    double cy,
    double angle,
  ) {
    final w = image.width;
    final h = image.height;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final maxRadius = math.sqrt(w * w + h * h);

    var baselineTotal = 0.0;
    var baselineCount = 0;
    for (var r = 10.0; r <= math.min(45.0, maxRadius); r += 4) {
      final x = (cx + dx * r).round();
      final y = (cy + dy * r).round();
      if (x < 0 || x >= w || y < 0 || y >= h) break;
      baselineTotal += _patchLum(image, x, y, 3);
      baselineCount++;
    }
    if (baselineCount == 0) return null;
    final baseline = baselineTotal / baselineCount;
    if (baseline < 120) return null;

    final dropThreshold = math.max(75.0, baseline - 38.0);
    var lowRun = 0;
    var lastGoodRadius = 12.0;

    for (var r = 16.0; r <= maxRadius; r += 3) {
      final x = (cx + dx * r).round();
      final y = (cy + dy * r).round();
      if (x < 2 || x >= w - 2 || y < 2 || y >= h - 2) break;

      final value = _patchLum(image, x, y, 3);
      if (value < dropThreshold && value < baseline * 0.72) {
        lowRun++;
        if (lowRun >= 4) {
          final hitRadius = lastGoodRadius;
          return _RayHit(
            angle,
            hitRadius,
            img.Point(
              cx + dx * hitRadius,
              cy + dy * hitRadius,
            ),
          );
        }
      } else {
        lowRun = 0;
        lastGoodRadius = r;
      }
    }
    return null;
  }

  static double _patchLum(img.Image image, int cx, int cy, int radius) {
    var total = 0.0;
    var count = 0;
    for (var y = cy - radius; y <= cy + radius; y++) {
      for (var x = cx - radius; x <= cx + radius; x++) {
        if (x < 0 || x >= image.width || y < 0 || y >= image.height) continue;
        total += _lum(image.getPixel(x, y));
        count++;
      }
    }
    return count == 0 ? 0 : total / count;
  }

  static List<img.Point>? _legacyFindSheet(img.Image image) {
    final w = image.width;
    final h = image.height;
    final threshold = _adaptiveThreshold(image);
    final mask = Uint8List(w * h);

    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        if (_lum(p) >= threshold && _sat(p) < 130) {
          mask[y * w + x] = 1;
        }
      }
    }

    final radius = math.max(8, math.min(24, math.min(w, h) ~/ 70));
    _close(mask, w, h, radius);

    final rows = <_Span>[];
    for (var y = 0; y < h; y++) {
      var count = 0;
      var minX = w;
      var maxX = -1;
      for (var x = 0; x < w; x++) {
        if (mask[y * w + x] != 0) {
          count++;
          minX = math.min(minX, x);
          maxX = math.max(maxX, x);
        }
      }
      if (count > w * 0.32 && maxX - minX > w * 0.35) {
        rows.add(_Span(y.toDouble(), minX.toDouble(), maxX.toDouble(), count));
      }
    }

    if (rows.length < h * 0.18) return null;

    final usable = rows.where((r) => r.y > h * 0.03 && r.y < h * 0.97).toList();
    if (usable.length < h * 0.12) return null;

    final leftLine = _fitLine(usable.map((r) => _Pair(r.y, r.minX)).toList());
    final rightLine = _fitLine(usable.map((r) => _Pair(r.y, r.maxX)).toList());
    if (leftLine == null || rightLine == null) return null;

    final top = _median(usable.take(math.max(8, usable.length ~/ 6)).map((r) => r.y));
    final bottom = _median(usable.skip(usable.length * 5 ~/ 6).map((r) => r.y));
    final quad = <img.Point>[
      img.Point(_lineAt(leftLine, top), top),
      img.Point(_lineAt(rightLine, top), top),
      img.Point(_lineAt(rightLine, bottom), bottom),
      img.Point(_lineAt(leftLine, bottom), bottom),
    ];

    final ordered = _orderQuad(quad);
    return ordered != null && _validQuad(ordered, w, h) ? ordered : null;
  }

  static List<img.Point>? _orderQuad(List<img.Point> points) {
    if (points.length != 4) return null;
    final cx = points.map((p) => p.x).reduce((a, b) => a + b) / 4;
    final cy = points.map((p) => p.y).reduce((a, b) => a + b) / 4;
    final ordered = [...points]
      ..sort((a, b) => math.atan2(a.y - cy, a.x - cx).compareTo(
            math.atan2(b.y - cy, b.x - cx),
          ));

    img.Point? tl;
    img.Point? tr;
    img.Point? br;
    img.Point? bl;
    for (final p in ordered) {
      final dx = p.x - cx;
      final dy = p.y - cy;
      if (dx <= 0 && dy <= 0) tl ??= p;
      if (dx > 0 && dy <= 0) tr ??= p;
      if (dx > 0 && dy > 0) br ??= p;
      if (dx <= 0 && dy > 0) bl ??= p;
    }
    if (tl == null || tr == null || br == null || bl == null) return null;
    return [tl, tr, br, bl];
  }

  static bool _validQuad(List<img.Point> p, int w, int h) {
    if (p.length != 4) return false;
    final area = _quadArea(p);
    if (area < w * h * 0.18 || area > w * h * 0.98) return false;

    final top = _distance(p[0], p[1]);
    final bottom = _distance(p[3], p[2]);
    final left = _distance(p[0], p[3]);
    final right = _distance(p[1], p[2]);
    if (top < w * 0.35 || bottom < w * 0.35) return false;
    if (left < h * 0.30 || right < h * 0.30) return false;

    return true;
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
    final p60 = values[(values.length * 0.60).floor().clamp(0, values.length - 1)];
    return math.max(130.0, math.min(220.0, p60 - 10));
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

class _RayHit {
  const _RayHit(this.angle, this.radius, this.point);
  final double angle;
  final double radius;
  final img.Point point;
}

class _Peak {
  const _Peak(this.index, this.radius);
  final int index;
  final double radius;
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
