import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class MacroProfile {
  final String id;
  final String username;

  const MacroProfile({required this.id, required this.username});

  factory MacroProfile.fromJson(Map<String, dynamic> json) => MacroProfile(
        id: json['id'] as String,
        username: json['username'] as String,
      );
}

/// PINs are sent only over TLS to the Edge Function and are never persisted.
/// The locally retained opaque session token can be revoked on sign-out.
class MacroSyncService {
  MacroSyncService._();
  static final MacroSyncService instance = MacroSyncService._();

  static const _projectUrl = 'https://rkazsjjlhfshltfvywyz.supabase.co';
  // This is the project's public publishable key, designed for browser/mobile clients.
  // It is intentionally not a secret; RLS denies direct table access and the Edge
  // Function separately authenticates opaque per-profile sessions.
  static const _publicKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_wvtuQNNwAp8l66oVvyyMOA_1GuPZmkZ',
  );
  static const _tokenKey = 'macro.session.token';
  static const _profileIdKey = 'macro.session.profile_id';
  static const _usernameKey = 'macro.session.username';

  String? _token;
  MacroProfile? _profile;

  MacroProfile? get profile => _profile;
  bool get isSignedIn => _token != null && _profile != null;

  Uri get _endpoint => Uri.parse('$_projectUrl/functions/v1/macro-api');

  Future<MacroProfile?> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_tokenKey);
    final profileId = prefs.getString(_profileIdKey);
    final username = prefs.getString(_usernameKey);
    if (token == null || profileId == null || username == null) return null;
    _token = token;
    _profile = MacroProfile(id: profileId, username: username);
    try {
      await snapshot();
      return _profile;
    } on MacroApiException catch (error) {
      if (error.statusCode == 401) await _clearLocalSession();
      rethrow;
    }
  }

  Future<MacroProfile> authenticate({
    required String username,
    required String pin,
    required bool createProfile,
  }) async {
    final data = await _request({
      'action': createProfile ? 'signup' : 'login',
      'username': username,
      'pin': pin,
    });
    _token = data['token'] as String;
    _profile = MacroProfile.fromJson(Map<String, dynamic>.from(data['profile'] as Map));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _token!);
    await prefs.setString(_profileIdKey, _profile!.id);
    await prefs.setString(_usernameKey, _profile!.username);
    return _profile!;
  }

  Future<Map<String, dynamic>> snapshot() => _request({'action': 'snapshot'}, authenticated: true);

  Future<Map<String, dynamic>> analyzeMeal({
    required String text,
    Uint8List? imageBytes,
    String? mimeType,
    String mode = 'meal',
    bool pro = false,
  }) async {
    final result = await _request({
      'action': 'analyze_meal',
      'text': text,
      'mode': mode,
      'pro': pro,
      if (imageBytes != null) 'image_base64': base64Encode(imageBytes),
      if (mimeType != null) 'mime_type': mimeType,
    }, authenticated: true);
    return Map<String, dynamic>.from(result['result'] as Map);
  }

  Future<Map<String, dynamic>> mutate({
    required String entity,
    required String operation,
    Map<String, dynamic>? row,
    Map<String, dynamic>? key,
  }) => _request({
        'action': 'mutate',
        'entity': entity,
        'operation': operation,
        if (row != null) 'row': row,
        if (key != null) 'key': key,
      }, authenticated: true);

  Future<void> mutateBatch({required String entity, required List<Map<String, dynamic>> rows}) async {
    if (rows.isEmpty) return;
    await _request({'action': 'mutate', 'entity': entity, 'operation': 'upsert', 'rows': rows}, authenticated: true);
  }

  Future<void> signOut() async {
    try {
      if (_token != null) await _request({'action': 'logout'}, authenticated: true);
    } catch (error) {
      debugPrint('Remote logout could not be reached; local session will still be cleared: $error');
    } finally {
      await _clearLocalSession();
    }
  }

  Future<void> _clearLocalSession() async {
    _token = null;
    _profile = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_profileIdKey);
    await prefs.remove(_usernameKey);
  }

  Future<Map<String, dynamic>> _request(
    Map<String, dynamic> body, {
    bool authenticated = false,
  }) async {
    if (_publicKey.isEmpty) {
      throw const MacroApiException(
        'חסר מפתח Supabase ציבורי. יש להגדיר SUPABASE_ANON_KEY בעת הבנייה.',
      );
    }
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'apikey': _publicKey,
    };
    if (authenticated && _token != null) headers['Authorization'] = 'Bearer $_token';
    late final http.Response response;
    try {
      response = await http
          .post(_endpoint, headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 50));
    } on TimeoutException {
      throw const MacroApiException(
        'הבקשה נמשכה יותר מ-50 שניות. בדקו את החיבור ונסו שוב.',
        statusCode: 408,
      );
    }
    Map<String, dynamic> data = {};
    try {
      data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    } catch (_) {
      if (kDebugMode) debugPrint('Macro API returned non-JSON (${response.statusCode}).');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MacroApiException(
        data['error'] as String? ?? 'הבקשה נכשלה (${response.statusCode}).',
        statusCode: response.statusCode,
      );
    }
    return data;
  }
}

class MacroApiException implements Exception {
  final String message;
  final int? statusCode;
  const MacroApiException(this.message, {this.statusCode});
  @override
  String toString() => message;
}
