// lib/main.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/real_ble_service.dart';
import 'core/robot_service.dart';
import 'theme/app_theme.dart';
import 'ui/control_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider<RobotService>(
      // Conexão Bluetooth BLE real centralizada com o ESP32-C3 McQueen
      create: (_) => RealBleService(),
      child: const McQueenApp(),
    ),
  );
}

class McQueenApp extends StatelessWidget {
  const McQueenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'McQueen',
      debugShowCheckedModeBanner: false,
      theme: McQueenTheme.darkTheme,
      home: const ControlPage(),
    );
  }
}
