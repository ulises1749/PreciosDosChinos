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
      final source = kIsWeb ? ImageSource.camera : ImageSource.camera;
      final image = await _picker.pickImage(
        source: source,
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
          content: Text('No se pudo abrir la cámara: $error'),
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
      builder: (context) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Planilla capturada',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 500),
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Continuar'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    ? 'Capturá la planilla para que la aplicación pueda detectar automáticamente la hoja y leer sus cantidades.'
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
                    child: Text('Ver fotografía'),
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
                  child: Text(_image == null ? 'Capturar planilla' : 'Volver a fotografiar'),
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
