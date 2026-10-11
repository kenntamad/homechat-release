import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'state/app_state.dart';
import 'ui/call_screen.dart';
import 'ui/home_screen.dart';
import 'ui/setup_screens.dart';
import 'ui/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final state = AppState(prefs);
  WidgetsBinding.instance.addObserver(state);
  runApp(AppScope(state: state, child: const HomeChatApp()));
  await state.boot();
}

ThemeData _theme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: brand, brightness: b);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    appBarTheme: AppBarTheme(
      backgroundColor: b == Brightness.light ? brand : scheme.surface,
      foregroundColor: b == Brightness.light ? Colors.white : scheme.onSurface,
      elevation: 0,
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(backgroundColor: brand, foregroundColor: Colors.white),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

class HomeChatApp extends StatelessWidget {
  const HomeChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    Widget home;
    if (app.booting) {
      home = const Scaffold(body: Center(child: CircularProgressIndicator()));
    } else if (!app.hasIdentity) {
      home = const WelcomeScreen();
    } else if (app.channel == null) {
      home = const FrequencyScreen();
    } else {
      home = const HomeScreen();
    }
    return MaterialApp(
      title: 'Home Chat',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      home: home,
      // Calls float above every screen.
      builder: (context, child) => Stack(fit: StackFit.expand, children: [
        child ?? const SizedBox.shrink(),
        if (app.signedIn) const CallOverlay(),
      ]),
    );
  }
}
