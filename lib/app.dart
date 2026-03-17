import 'package:flutter/material.dart';

import 'core/di/app_registry.dart';
import 'features/home/presentation/screens/home_screen.dart';

class MapNowoeApp extends StatelessWidget {
  final AppRegistry registry;

  const MapNowoeApp({super.key, required this.registry});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Map Nowoe',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: Colors.black,
          surface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          foregroundColor: Colors.black,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.black,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
      ),
      home: Scaffold(
        appBar: AppBar(
          toolbarHeight: 40,
          title: const Text('MAP NOWOE'),
        ),
        body: HomeScreen(
          controller: registry.buildHomeController(),
          mapOnlyMode: true,
        ),
      ),
    );
  }
}
