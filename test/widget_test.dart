import 'package:flutter_test/flutter_test.dart';

import 'package:precios_dos_chinos/app.dart';

void main() {
  testWidgets('Muestra la pantalla principal de rendición',
      (WidgetTester tester) async {
    await tester.pumpWidget(const PreciosDosChinosApp());

    expect(find.text('Precios Dos Chinos'), findsOneWidget);
    expect(find.text('Rendición diaria'), findsOneWidget);
    expect(find.text('Nueva rendición'), findsOneWidget);
    expect(find.text('Historial'), findsOneWidget);
  });
}
