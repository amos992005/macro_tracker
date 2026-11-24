import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/database_platform.dart';
import 'data/database_helper.dart';
import 'data/macro_sync_service.dart';
import 'features/auth/login_screen.dart';
import 'features/tracker/tracker_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDatabasePlatform();
  runApp(const MacroTrackerApp());
}

class MacroTrackerApp extends StatelessWidget {
  const MacroTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const Color neonGreen = Color(0xFF00FF87);
    const Color deepPurple = Color(0xFF0A0E21);
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
      home: const SessionGate(),
    );
  }
}

class SessionGate extends StatefulWidget {
  const SessionGate({super.key});

  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  MacroProfile? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      final profile = await MacroSyncService.instance.restoreSession();
      if (profile != null) {
        await DatabaseHelper().activateProfile(profile.id);
        try {
          await DatabaseHelper().synchronizeFromRemote();
        } catch (error) {
          debugPrint('Could not refresh profile snapshot; continuing with local cache: $error');
        }
      }
      if (mounted) setState(() => _profile = profile);
    } catch (error) {
      // A temporary network failure should not prevent access to a saved local profile.
      final savedProfile = MacroSyncService.instance.profile;
      if (savedProfile != null) {
        await DatabaseHelper().activateProfile(savedProfile.id);
        if (mounted) setState(() => _profile = savedProfile);
      } else {
        debugPrint('No local session could be restored: $error');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _onAuthenticated(MacroProfile profile) async {
    await DatabaseHelper().activateProfile(profile.id);
    try {
      await DatabaseHelper().synchronizeFromRemote();
    } catch (error) {
      debugPrint('Initial cloud sync failed; profile remains available locally: $error');
    }
    if (mounted) setState(() => _profile = profile);
  }

  Future<void> _signOut() async {
    await MacroSyncService.instance.signOut();
    await DatabaseHelper().deactivateProfile();
    if (mounted) setState(() => _profile = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final profile = _profile;
    if (profile != null) {
      return TrackerScreen(username: profile.username, onSignOut: _signOut);
    }
    return LoginScreen(onAuthenticated: _onAuthenticated);
  }
}