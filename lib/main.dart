import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'; // <-- הוספת החבילה
import 'features/tracker/tracker_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // --- התיקון הקריטי ל-Windows! ---
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // ---------------------------------

  runApp(const MacroTrackerApp());
}

class MacroTrackerApp extends StatelessWidget {
  const MacroTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color neonGreen = Color(0xFF00FF87);
    const Color deepPurple = Color(0xFF1A1A2E);
    const Color darkBlue = Color(0xFF16213E);

    return MaterialApp(
      title: 'Macro Tracker',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('he', 'IL'),
      ],
      locale: const Locale('he', 'IL'),
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: neonGreen,
          brightness: Brightness.dark,
          primary: neonGreen,
          secondary: Colors.amberAccent,
          surface: const Color(0xFF0F3460),
        ),
        scaffoldBackgroundColor: deepPurple,

        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          iconTheme: IconThemeData(color: neonGreen),
        ),

        cardTheme: CardThemeData(
          color: darkBlue.withValues(alpha: 0.6),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1),
          ),
        ),

        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: neonGreen,
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
            elevation: 8,
            shadowColor: neonGreen.withValues(alpha: 0.5),
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.black.withValues(alpha: 0.3),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: neonGreen, width: 2),
          ),
          labelStyle: const TextStyle(color: Colors.white70),
        ),
      ),
      home: const TrackerScreen(),
    );
  }
}