import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/sheet_rectification_service_v2.dart';

class NewRenditionPage extends StatefulWidget {
  const NewRenditionPage({super.key});

  @override
  State<NewRenditionPage> createState() => _NewRenditionPageState();
}

class _NewRenditionPageState extends State<NewRenditionPage> {
  final ImagePicker _picker = ImagePicker();
  XFile? _image;
  Uint8List? _imageBytes;
  bool _capturing = false;
  int _rotationQuarterTurns = 0;

  Future<void> _captureSheet() async {
    setState(() => _capturing = true);
    try {
      final image = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      if (!mounted) return;
      if (image != null) {
        final originalBytes = await image.readAsBytes();
        final processedBytes =
            SheetRectificationServiceV2.process(originalBytes);

        setState(() {
          _image = image;
          _imageBytes = processedBytes;
          _rotationQuarterTurns = 0;
        });
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            kIsWeb
                ? 'En la versión web de PC, el navegador puede abrir el selector de archivos en lugar de la cámara.'
                : 'No se pudo abrir la cámara: $error',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _showPreview() async {
    final bytes = _imageBytes;
    if (bytes == null) return;
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _SheetPreviewDialog(
        bytes: bytes,
        initialQuarterTurns: _rotationQuarterTurns,
        onRotationChanged: (turns) {
          if (mounted) setState(() => _rotationQuarterTurns = turns);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final captureLabel = kIsWeb
        ? (_image == null ? 'Seleccionar fotografía' : 'Volver a seleccionar')
        : (_image == null ? 'Fotografiar planilla' : 'Volver a fotografiar');

    return Scaffold(
      appBar: AppBar(title: const Text('Nueva rendición')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              Icon(
                _image == null
                    ? Icons.camera_alt_outlined
                    : Icons.check_circle_outline,
                size: 80,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                _image == null ? 'Fotografiar planilla' : 'Planilla capturada',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                _image == null
                    ? (kIsWeb
                        ? 'En la versión de PC podés seleccionar una fotografía de la planilla. En el teléfono usaremos la cámara.'
                        : 'Capturá la planilla para que la aplicación pueda detectar automáticamente la hoja y leer sus cantidades.')
                    : 'La fotografía quedó lista para el siguiente paso de procesamiento.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const Spacer(),
              if (_image != null) ...[
                OutlinedButton.icon(
                  onPressed: _showPreview,
                  icon: const Icon(Icons.image_outlined),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('Ver fotografía y ampliar'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: _capturing ? null : _captureSheet,
                icon: _capturing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.camera_alt_outlined),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Text(captureLabel),
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('Volver'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetPreviewDialog extends StatefulWidget {
  const _SheetPreviewDialog({
    required this.bytes,
    required this.initialQuarterTurns,
    required this.onRotationChanged,
  });

  final Uint8List bytes;
  final int initialQuarterTurns;
  final ValueChanged<int> onRotationChanged;

  @override
  State<_SheetPreviewDialog> createState() => _SheetPreviewDialogState();
}

class _SheetPreviewDialogState extends State<_SheetPreviewDialog> {
  late int _quarterTurns;

  @override
  void initState() {
    super.initState();
    _quarterTurns = widget.initialQuarterTurns;
  }

  void _rotate(int delta) {
    setState(() => _quarterTurns = (_quarterTurns + delta) % 4);
    widget.onRotationChanged(_quarterTurns);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Planilla capturada'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Cerrar',
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                boundaryMargin: const EdgeInsets.all(80),
                child: Center(
                  child: RotatedBox(
                    quarterTurns: _quarterTurns,
                    child: Image.memory(
                      widget.bytes,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _rotate(-1),
                        icon: const Icon(Icons.rotate_left),
                        label: const Text('Girar izquierda'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _rotate(1),
                        icon: const Icon(Icons.rotate_right),
                        label: const Text('Girar derecha'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
