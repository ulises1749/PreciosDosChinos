import 'package:flutter/material.dart';

import 'screens/home_page.dart';

class PreciosDosChinosApp extends StatelessWidget {
  const PreciosDosChinosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Precios Dos Chinos',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
