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
    if (normalized.height > normalized.width) {
      final rotated = img.copyRotate(normalized, angle: 90);
      return Uint8List.fromList(img.encodeJpg(rotated, quality: 95));
    }

    return Uint8List.fromList(img.encodeJpg(normalized, quality: 95));
  }
}
