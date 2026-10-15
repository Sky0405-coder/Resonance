import 'dart:async';
import 'dart:convert';

import '../l10n/locale.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

const _kServer = 'server_url';
const _kToken = 'token';

class SessionState {
  const SessionState({this.serverUrl, this.token, this.user, this.loading = false, this.offline = false});

  final String? serverUrl;
  final String? token;
  final User? user;
  final bool loading;
  final bool offline;

  bool get loggedIn => token != null && user != null;

  SessionState copyWith({String? serverUrl, String? token, User? user, bool? loading, bool? offline}) => SessionState(
    serverUrl: serverUrl ?? this.serverUrl,
    token: token ?? this.token,
    user: user ?? this.user,
    loading: loading ?? this.loading,
    offline: offline ?? this.offline,
  );
}

final prefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError('overridden in main()'));

String get deviceName => kIsWeb ? 'Web' : defaultTargetPlatform.name;

/// Normalises user input like "music.example.com" to "https://music.example.com".
String normalizeServerUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  if (!url.startsWith('http://') && !url.startsWith('https://')) url = 'https://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  return url;
}

class SessionNotifier extends Notifier<SessionState> {
  Timer? _retry;
  bool _restoring = false;

  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  SessionState build() {
    ref.onDispose(() => _retry?.cancel());
    // The web build is served by the server itself, so default to the page origin.
    final server = _prefs.getString(_kServer) ?? (kIsWeb ? Uri.base.origin : null);
    final token = _prefs.getString(_kToken);
    if (server != null && token != null) {
      Future.microtask(_restore);
      return SessionState(serverUrl: server, token: token, loading: true);
    }
    return SessionState(serverUrl: server);
  }

  Future<void> _restore() async {
    if (_restoring || state.serverUrl == null || state.token == null) return;
    _restoring = true;
    final server = state.serverUrl!;
    final token = state.token;
    bool stillCurrent() => ref.mounted && state.serverUrl == server && state.token == token;
    try {
      final user = await ApiClient(server, token, languageCode: ref.read(appLocaleProvider).languageCode).me();
      if (!stillCurrent()) return;
      await _prefs.setString('session.user', jsonEncode(user.toJson()));
      if (!stillCurrent()) return;
      _retry?.cancel();
      _retry = null;
      state = state.copyWith(user: user, loading: false, offline: false);
    } on ApiException catch (e) {
      if (!stillCurrent()) return;
      if (e.statusCode == 401) {
        _retry?.cancel();
        _retry = null;
        await _prefs.remove(_kToken);
        await _prefs.remove('session.user');
        if (stillCurrent()) state = SessionState(serverUrl: server);
      } else {
        User? cached;
        final json = _prefs.getString('session.user');
        if (!kIsWeb && json != null) {
          try {
            cached = User.fromJson(jsonDecode(json));
          } on FormatException {
            // A damaged cache cannot restore a session.
          } on TypeError {
            // A cache from an incompatible version cannot restore a session.
          }
        }
        if (cached != null) {
          state = state.copyWith(user: cached, loading: false, offline: true);
          _retry ??= Timer.periodic(const Duration(seconds: 30), (_) => _restore());
        } else {
          state = SessionState(serverUrl: server);
        }
      }
    } finally {
      _restoring = false;
    }
  }

  Future<void> setServer(String url) async {
    _retry?.cancel();
    _retry = null;
    final normalized = normalizeServerUrl(url);
    if (normalized != state.serverUrl) await _prefs.remove('session.user');
    await _prefs.setString(_kServer, normalized);
    state = SessionState(serverUrl: normalized);
  }

  Future<void> signedIn(String token, User user) async {
    _retry?.cancel();
    _retry = null;
    await _prefs.setString(_kToken, token);
    await _prefs.setString('session.user', jsonEncode(user.toJson()));
    state = SessionState(serverUrl: state.serverUrl, token: token, user: user);
  }

  void updateUser(User user) {
    state = state.copyWith(user: user);
    _prefs.setString('session.user', jsonEncode(user.toJson())).ignore();
  }

  Future<void> logout() async {
    _retry?.cancel();
    _retry = null;
    try {
      await ref.read(apiProvider).logout();
    } catch (_) {
      // Logging out locally is enough if the server is unreachable.
    }
    await _prefs.remove(_kToken);
    await _prefs.remove('session.user');
    state = SessionState(serverUrl: state.serverUrl);
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

final apiProvider = Provider<ApiClient>((ref) {
  final s = ref.watch(sessionProvider.select((s) => (s.serverUrl, s.token)));
  return ApiClient(s.$1 ?? '', s.$2, languageCode: ref.watch(appLocaleProvider).languageCode);
});

final currentUserIdProvider = Provider<String?>((ref) => ref.watch(sessionProvider.select((s) => s.user?.id)));
