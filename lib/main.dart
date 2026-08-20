import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppTheme.load();
  runApp(const ViewFileApp());
}

class ViewFileApp extends StatelessWidget {
  const ViewFileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppTheme.changes,
      builder: (context, _, __) => MaterialApp(
        title: 'ViewFile',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: AppTheme.themeMode,
        home: const HomePage(),
      ),
    );
  }
}
