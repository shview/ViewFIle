import 'package:flutter/material.dart';

import 'pages/home_page.dart';

void main() => runApp(const ViewFileApp());

class ViewFileApp extends StatelessWidget {
  const ViewFileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ViewFile',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4F8CFF),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
