import 'package:flutter/material.dart';
import 'screens/login_screen.dart';

void main() {
  runApp(FoloApp());
}

class FoloApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Folo Read',
      theme: ThemeData(
        primarySwatch: Colors.orange,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      home: LoginScreen(),
    );
  }
}
