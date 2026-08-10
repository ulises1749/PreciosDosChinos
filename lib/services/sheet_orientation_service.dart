import 'dart:typed_data';

import 'package:image/image.dart' as img;

class SheetOrientationService {
  const SheetOrientationService._();

  /// Las planillas de Los Dos Chinos se trabajan en formato apaisado.
  /// Si la imagen recibida es claramente vertical, la gira 90 grados.
  /// La corrección manual sigue disponible para casos ambiguos.
  static Uint8List autoRotateToLandscape(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;

    if (decoded.height > decoded.width) {
      final rotated = img.copyRotate(decoded, angle: 90);
      return Uint8List.fromList(img.encodeJpg(rotated, quality: 95));
    }

    return bytes;
  }
}
