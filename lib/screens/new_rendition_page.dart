import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class NewRenditionPage extends StatefulWidget {
  const NewRenditionPage({super.key});

  @override
  State<NewRenditionPage> createState() => _NewRenditionPageState();
}

class _NewRenditionPageState extends State<NewRenditionPage> {
  final ImagePicker _picker = ImagePicker();
  XFile? _image;
  bool _capturing = false;

  Future<void> _captureSheet() async {
    setState(() => _capturing = true);

    try {
      final image = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );

      if (!mounted) return;

      if (image != null) {
        setState(() => _image = image);
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
      if (mounted) {
        setState(() => _capturing = false);
      }
    }
  }

  Future<void> _showPreview() async {
    final image = _image;
    if (image == null) return;

    final bytes = await image.readAsBytes();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Planilla capturada'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
              tooltip: 'Cerrar',
            ),
          ),
          body: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final captureLabel = kIsWeb
        ? (_image == null ? 'Seleccionar fotografía' : 'Volver a seleccionar')
        : (_image == null ? 'Fotografiar planilla' : 'Volver a fotografiar');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nueva rendición'),
      ),
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
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
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
