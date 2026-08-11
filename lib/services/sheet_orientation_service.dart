import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class SheetOrientationService {
  const SheetOrientationService._();

  /// Normaliza primero la orientación EXIF y luego deja la planilla en
  /// orientación apaisada. La corrección manual sigue disponible para
  /// casos en los que la fotografía sea ambigua.
  static Uint8List autoRotateToLandscape(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    final normalized = img.bakeOrientation(decoded);
    final landscape = normalized.height > normalized.width
        ? img.copyRotate(
            normalized,
            angle: 90,
            interpolation: img.Interpolation.linear,
          )
        : normalized;

    return Uint8List.fromList(img.encodeJpg(landscape, quality: 95));
  }

  /// Intenta localizar la hoja dentro de la fotografía y corregir su
  /// perspectiva. La detección se hace sobre una copia reducida y usa una
  /// máscara de zonas claras, un cierre morfológico y el mayor componente
  /// conectado. Si la detección no es confiable, se conserva la fotografía
  /// apaisada en lugar de aplicar una deformación incorrecta.
  static Uint8List autoDetectAndRectifySheet(Uint8List bytes) {
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

    final detectionImage = source.width > 800
        ? img.copyResize(
            source,
            width: 800,
            interpolation: img.Interpolation.linear,
          )
        : source;

    final corners = _detectSheetCorners(detectionImage);
    if (corners == null) {
      return Uint8List.fromList(img.encodeJpg(source, quality: 95));
    }

    final scaleX = source.width / detectionImage.width;
    final scaleY = source.height / detectionImage.height;

    final topLeft = img.Point(
      corners.topLeft.x * scaleX,
      corners.topLeft.y * scaleY,
    );
    final topRight = img.Point(
      corners.topRight.x * scaleX,
      corners.topRight.y * scaleY,
    );
    final bottomLeft = img.Point(
      corners.bottomLeft.x * scaleX,
      corners.bottomLeft.y * scaleY,
    );
    final bottomRight = img.Point(
      corners.bottomRight.x * scaleX,
      corners.bottomRight.y * scaleY,
    );

    final rectified = img.copyRectify(
      source,
      topLeft: topLeft,
      topRight: topRight,
      bottomLeft: bottomLeft,
      bottomRight: bottomRight,
      interpolation: img.Interpolation.linear,
    );

    return Uint8List.fromList(img.encodeJpg(rectified, quality: 95));
  }

  static _SheetCorners? _detectSheetCorners(img.Image image) {
    final width = image.width;
    final height = image.height;
    if (width < 80 || height < 80) return null;

    // La planilla suele ser clara respecto del fondo. El umbral se adapta a
    // la iluminación de cada fotografía usando el borde como referencia.
    var borderSum = 0.0;
    var borderCount = 0;
    final borderStepX = math.max(1, width ~/ 80);
    final borderStepY = math.max(1, height ~/ 80);

    for (var x = 0; x < width; x += borderStepX) {
      borderSum += _luminance(image.getPixel(x, 0));
      borderSum += _luminance(image.getPixel(x, height - 1));
      borderCount += 2;
    }
    for (var y = 0; y < height; y += borderStepY) {
      borderSum += _luminance(image.getPixel(0, y));
      borderSum += _luminance(image.getPixel(width - 1, y));
      borderCount += 2;
    }

    final borderMean = borderSum / borderCount;
    final threshold = math.max(125.0, math.min(215.0, borderMean + 38.0));

    final step = math.max(1, math.max(width, height) ~/ 600);
    final maskWidth = (width + step - 1) ~/ step;
    final maskHeight = (height + step - 1) ~/ step;
    final mask = Uint8List(maskWidth * maskHeight);

    for (var my = 0; my < maskHeight; my++) {
      final y = math.min(height - 1, my * step);
      for (var mx = 0; mx < maskWidth; mx++) {
        final x = math.min(width - 1, mx * step);
        final pixel = image.getPixel(x, y);
        final luminance = _luminance(pixel);
        final saturation = _saturation(pixel);
        if (luminance >= threshold && saturation <= 100) {
          mask[my * maskWidth + mx] = 1;
        }
      }
    }

    // Une las zonas blancas separadas por las líneas de la planilla.
    _morphologicalClose(mask, maskWidth, maskHeight, radius: 2);

    final component = _largestComponent(mask, maskWidth, maskHeight);
    if (component == null) return null;

    final componentRatio = component.count / mask.length;
    if (componentRatio < 0.10 || componentRatio > 0.90) return null;

    // Tomamos una muestra del contorno para evitar ordenar cientos de miles
    // de píxeles al construir la envolvente convexa.
    final contour = <img.Point>[];
    final sampleEvery = math.max(1, component.count ~/ 6000);
    var sampleIndex = 0;
    for (var y = 0; y < maskHeight; y++) {
      for (var x = 0; x < maskWidth; x++) {
        final index = y * maskWidth + x;
        if (component.labels[index] != component.label) continue;
        if (!_isBoundary(component.labels, component.label, x, y, maskWidth, maskHeight)) {
          continue;
        }
        if (sampleIndex++ % sampleEvery == 0) {
          contour.add(img.Point(x * step, y * step));
        }
      }
    }

    if (contour.length < 20) return null;

    final hull = _convexHull(contour);
    if (hull.length < 4) return null;

    final topLeft = _extremePoint(hull, (p) => p.x + p.y, findMin: true);
    final topRight = _extremePoint(hull, (p) => p.x - p.y, findMax: true);
    final bottomRight = _extremePoint(hull, (p) => p.x + p.y, findMax: true);
    final bottomLeft = _extremePoint(hull, (p) => p.x - p.y, findMin: true);

    final corners = _SheetCorners(
      topLeft: topLeft,
      topRight: topRight,
      bottomLeft: bottomLeft,
      bottomRight: bottomRight,
    );

    if (!_isPlausible(corners, width, height)) return null;
    return corners;
  }

  static void _morphologicalClose(
    Uint8List mask,
    int width,
    int height, {
    required int radius,
  }) {
    final dilated = Uint8List(mask.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var found = false;
        for (var dy = -radius; dy <= radius && !found; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= height) continue;
          for (var dx = -radius; dx <= radius; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= width) continue;
            if (mask[yy * width + xx] != 0) {
              found = true;
              break;
            }
          }
        }
        if (found) dilated[y * width + x] = 1;
      }
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var filled = true;
        for (var dy = -radius; dy <= radius && filled; dy++) {
          final yy = y + dy;
          if (yy < 0 || yy >= height) {
            filled = false;
            break;
          }
          for (var dx = -radius; dx <= radius; dx++) {
            final xx = x + dx;
            if (xx < 0 || xx >= width || dilated[yy * width + xx] == 0) {
              filled = false;
              break;
            }
          }
        }
        mask[y * width + x] = filled ? 1 : 0;
      }
    }
  }

  static _Component? _largestComponent(
    Uint8List mask,
    int width,
    int height,
  ) {
    final labels = Int32List(mask.length);
    var nextLabel = 0;
    _Component? largest;
    final queue = Int32List(mask.length);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final start = y * width + x;
        if (mask[start] == 0 || labels[start] != 0) continue;

        nextLabel++;
        var head = 0;
        var tail = 0;
        queue[tail++] = start;
        labels[start] = nextLabel;
        var count = 0;

        while (head < tail) {
          final current = queue[head++];
          count++;
          final cx = current % width;
          final cy = current ~/ width;

          if (cx > 0) {
            final n = current - 1;
            if (mask[n] != 0 && labels[n] == 0) {
              labels[n] = nextLabel;
              queue[tail++] = n;
            }
          }
          if (cx + 1 < width) {
            final n = current + 1;
            if (mask[n] != 0 && labels[n] == 0) {
              labels[n] = nextLabel;
              queue[tail++] = n;
            }
          }
          if (cy > 0) {
            final n = current - width;
            if (mask[n] != 0 && labels[n] == 0) {
              labels[n] = nextLabel;
              queue[tail++] = n;
            }
          }
          if (cy + 1 < height) {
            final n = current + width;
            if (mask[n] != 0 && labels[n] == 0) {
              labels[n] = nextLabel;
              queue[tail++] = n;
            }
          }
        }

        if (largest == null || count > largest.count) {
          largest = _Component(label: nextLabel, count: count, labels: labels);
        }
      }
    }

    return largest;
  }

  static bool _isBoundary(
    Int32List labels,
    int label,
    int x,
    int y,
    int width,
    int height,
  ) {
    if (x == 0 || y == 0 || x == width - 1 || y == height - 1) return true;
    return labels[y * width + x - 1] != label ||
        labels[y * width + x + 1] != label ||
        labels[(y - 1) * width + x] != label ||
        labels[(y + 1) * width + x] != label;
  }

  static double _luminance(img.Pixel pixel) {
    return (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b).toDouble();
  }

  static double _saturation(img.Pixel pixel) {
    final maxChannel = math.max(pixel.r, math.max(pixel.g, pixel.b));
    final minChannel = math.min(pixel.r, math.min(pixel.g, pixel.b));
    return (maxChannel - minChannel).toDouble();
  }

  static List<img.Point> _convexHull(List<img.Point> points) {
    final sorted = List<img.Point>.from(points)
      ..sort((a, b) {
        final xCompare = a.x.compareTo(b.x);
        return xCompare != 0 ? xCompare : a.y.compareTo(b.y);
      });

    final unique = <img.Point>[];
    for (final point in sorted) {
      if (unique.isEmpty || unique.last.x != point.x || unique.last.y != point.y) {
        unique.add(point);
      }
    }
    if (unique.length <= 2) return unique;

    final lower = <img.Point>[];
    for (final point in unique) {
      while (lower.length >= 2 &&
          _cross(lower[lower.length - 2], lower.last, point) <= 0) {
        lower.removeLast();
      }
      lower.add(point);
    }

    final upper = <img.Point>[];
    for (final point in unique.reversed) {
      while (upper.length >= 2 &&
          _cross(upper[upper.length - 2], upper.last, point) <= 0) {
        upper.removeLast();
      }
      upper.add(point);
    }

    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  static double _cross(img.Point a, img.Point b, img.Point c) {
    return ((b.x - a.x) * (c.y - a.y) -
            (b.y - a.y) * (c.x - a.x))
        .toDouble();
  }

  static img.Point _extremePoint(
    List<img.Point> points,
    num Function(img.Point) score, {
    bool findMin = false,
    bool findMax = false,
  }) {
    var best = points.first;
    for (final point in points.skip(1)) {
      final value = score(point);
      final bestValue = score(best);
      if ((findMin && value < bestValue) ||
          (findMax && value > bestValue)) {
        best = point;
      }
    }
    return best;
  }

  static bool _isPlausible(_SheetCorners corners, int width, int height) {
    final diagonal = math.sqrt(width * width + height * height);
    final unique = <String>{
      '${corners.topLeft.x},${corners.topLeft.y}',
      '${corners.topRight.x},${corners.topRight.y}',
      '${corners.bottomRight.x},${corners.bottomRight.y}',
      '${corners.bottomLeft.x},${corners.bottomLeft.y}',
    };
    if (unique.length != 4) return false;

    final area = _polygonArea([
      corners.topLeft,
      corners.topRight,
      corners.bottomRight,
      corners.bottomLeft,
    ]).abs();
    final imageArea = width * height.toDouble();
    final areaRatio = area / imageArea;

    if (areaRatio < 0.15 || areaRatio > 0.92) return false;

    final minCornerDistance = diagonal * 0.08;
    final all = [
      corners.topLeft,
      corners.topRight,
      corners.bottomRight,
      corners.bottomLeft,
    ];
    for (var i = 0; i < all.length; i++) {
      for (var j = i + 1; j < all.length; j++) {
        if (_distance(all[i], all[j]) < minCornerDistance) return false;
      }
    }

    final topWidth = _distance(corners.topLeft, corners.topRight);
    final bottomWidth = _distance(corners.bottomLeft, corners.bottomRight);
    final leftHeight = _distance(corners.topLeft, corners.bottomLeft);
    final rightHeight = _distance(corners.topRight, corners.bottomRight);
    final averageWidth = (topWidth + bottomWidth) / 2;
    final averageHeight = (leftHeight + rightHeight) / 2;

    // Las planillas de este proyecto son apaisadas.
    if (averageWidth / averageHeight < 1.05) return false;

    return true;
  }

  static double _polygonArea(List<img.Point> points) {
    var sum = 0.0;
    for (var i = 0; i < points.length; i++) {
      final next = points[(i + 1) % points.length];
      sum += points[i].x * next.y - next.x * points[i].y;
    }
    return sum / 2;
  }

  static double _distance(img.Point a, img.Point b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }
}

class _Component {
  const _Component({
    required this.label,
    required this.count,
    required this.labels,
  });

  final int label;
  final int count;
  final Int32List labels;
}

class _SheetCorners {
  const _SheetCorners({
    required this.topLeft,
    required this.topRight,
    required this.bottomLeft,
    required this.bottomRight,
  });

  final img.Point topLeft;
  final img.Point topRight;
  final img.Point bottomLeft;
  final img.Point bottomRight;
}
