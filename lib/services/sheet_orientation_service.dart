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
        ? img.copyRotate(normalized, angle: 90, interpolation: img.Interpolation.linear)
        : normalized;

    return Uint8List.fromList(img.encodeJpg(landscape, quality: 95));
  }

  /// Intenta localizar la hoja dentro de la fotografía y corregir su
  /// perspectiva. Si la detección no es suficientemente confiable, devuelve
  /// la imagen original para no deformarla accidentalmente.
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

    // El detector trabaja sobre una copia pequeña para que sea rápido incluso
    // con fotografías de cámara de varios megapíxeles.
    final detectionImage = source.width > 800
        ? img.copyResize(source, width: 800, interpolation: img.Interpolation.linear)
        : source;

    final corners = _detectSheetCorners(detectionImage);
    if (corners == null) {
      return Uint8List.fromList(img.encodeJpg(source, quality: 95));
    }

    final scaleX = source.width / detectionImage.width;
    final scaleY = source.height / detectionImage.height;

    final topLeft = img.Point(corners.topLeft.x * scaleX, corners.topLeft.y * scaleY);
    final topRight = img.Point(corners.topRight.x * scaleX, corners.topRight.y * scaleY);
    final bottomLeft = img.Point(corners.bottomLeft.x * scaleX, corners.bottomLeft.y * scaleY);
    final bottomRight = img.Point(corners.bottomRight.x * scaleX, corners.bottomRight.y * scaleY);

    // copyRectify transforma el cuadrilátero detectado en toda la imagen,
    // dejando una planilla frontal lista para el OCR posterior.
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
    final pixels = <img.Point>[];
    final width = image.width;
    final height = image.height;

    if (width < 80 || height < 80) return null;

    // La planilla suele ser clara y poco saturada respecto del fondo.
    // Calculamos el promedio del borde para adaptar el umbral a la foto.
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
    final threshold = math.max(135.0, math.min(210.0, borderMean + 45.0));

    final step = math.max(1, math.max(width, height) ~/ 500);
    for (var y = 0; y < height; y += step) {
      for (var x = 0; x < width; x += step) {
        final pixel = image.getPixel(x, y);
        final luminance = _luminance(pixel);
        final saturation = _saturation(pixel);
        if (luminance >= threshold && saturation <= 65) {
          pixels.add(img.Point(x, y));
        }
      }
    }

    if (pixels.length < 100) return null;

    final hull = _convexHull(pixels);
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

  static double _luminance(img.Pixel pixel) {
    return 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
  }

  static double _saturation(img.Pixel pixel) {
    final maxChannel = math.max(pixel.r, math.max(pixel.g, pixel.b));
    final minChannel = math.min(pixel.r, math.min(pixel.g, pixel.b));
    return maxChannel - minChannel;
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
      while (lower.length >= 2 && _cross(lower[lower.length - 2], lower.last, point) <= 0) {
        lower.removeLast();
      }
      lower.add(point);
    }

    final upper = <img.Point>[];
    for (final point in unique.reversed) {
      while (upper.length >= 2 && _cross(upper[upper.length - 2], upper.last, point) <= 0) {
        upper.removeLast();
      }
      upper.add(point);
    }

    lower.removeLast();
    upper.removeLast();
    return [...lower, ...upper];
  }

  static double _cross(img.Point a, img.Point b, img.Point c) {
    return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
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
      if ((findMin && value < bestValue) || (findMax && value > bestValue)) {
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

    // Evita interpretar una pared clara o el fondo completo como la hoja.
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

    // El flujo de rendición trabaja con planillas apaisadas.
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
