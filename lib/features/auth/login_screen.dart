import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/macro_sync_service.dart';

class LoginScreen extends StatefulWidget {
  final Future<void> Function(MacroProfile profile) onAuthenticated;
  const LoginScreen({super.key, required this.onAuthenticated});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _pin = TextEditingController();
  bool _creating = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final username = _username.text.trim().toLowerCase();
    final pin = _pin.text.trim();
    if (!RegExp(r'^[a-z0-9_.-]{3,32}$').hasMatch(username)) {
      setState(() => _error = 'שם המשתמש חייב להכיל 3–32 תווים באנגלית, ספרות, נקודה, מקף או קו תחתון.');
      return;
    }
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin)) {
      setState(() => _error = 'יש להזין PIN בן 4–6 ספרות.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = await MacroSyncService.instance.authenticate(
        username: username,
        pin: pin,
        createProfile: _creating,
      );
      await widget.onAuthenticated(profile);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.restaurant_menu, size: 48, color: Color(0xFF00FF87)),
                    const SizedBox(height: 12),
                    Text(
                      _creating ? 'יצירת פרופיל Macro Tracker' : 'כניסה ל־Macro Tracker',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _username,
                      textDirection: TextDirection.ltr,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLength: 32,
                      decoration: const InputDecoration(
                        labelText: 'שם משתמש',
                        hintText: 'לדוגמה: dana_1',
                        counterText: '',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _pin,
                      textDirection: TextDirection.ltr,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      obscureText: true,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onSubmitted: (_) => _submit(),
                      decoration: const InputDecoration(
                        labelText: 'PIN (4–6 ספרות)',
                        counterText: '',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                    ],
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : Text(_creating ? 'צור פרופיל' : 'התחברות'),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _creating = !_creating;
                                _error = null;
                              }),
                      child: Text(_creating ? 'כבר יש לך פרופיל? התחברות' : 'משתמש חדש? יצירת פרופיל'),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'ה-PIN נשמר רק בצד השרת כשהוא מגובב, ואינו נשמר במכשיר. '
                      'PIN קצר אינו תחליף לסיסמה חזקה; בחרו PIN שאינו משמש אתכם במקום אחר.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.white60),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
