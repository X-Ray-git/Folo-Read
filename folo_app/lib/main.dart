import 'package:flutter/material.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'screens/login_screen.dart';

final GlobalKey<ScaffoldMessengerState> globalMessengerKey = GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> globalNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    debugPrint("Failed to set high refresh rate: $e");
  }
  runApp(const FoloApp());
}

class FoloApp extends StatelessWidget {
  const FoloApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Folo Read',
      scaffoldMessengerKey: globalMessengerKey,
      navigatorKey: globalNavigatorKey,
      theme: ThemeData(
        primarySwatch: Colors.orange,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      home: LoginScreen(),
    );
  }
}
