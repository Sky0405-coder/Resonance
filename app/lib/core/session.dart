import '../l10n/locale.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'models.dart';

const _kServer = 'server_url';
const _kToken = 'token';

class SessionState {
  const SessionState({this.serverUrl, this.token, this.user, this.loading = false});

  final String? serverUrl;
  final String? token;
  final User? user;
  final bool loading;

  bool get loggedIn => token != null && user != null;

  SessionState copyWith({String? serverUrl, String? token, User? user, bool? loading}) => SessionState(
    serverUrl: serverUrl ?? this.serverUrl,
    token: token ?? this.token,
    user: user ?? this.user,
    loading: loading ?? this.loading,
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
  SharedPreferences get _prefs => ref.read(prefsProvider);

  @override
  SessionState build() {
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
    try {
      final user = await ApiClient(
        state.serverUrl!,
        state.token,
        languageCode: ref.read(appLocaleProvider).languageCode,
      ).me();
      state = state.copyWith(user: user, loading: false);
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await _prefs.remove(_kToken);
        state = SessionState(serverUrl: state.serverUrl);
      } else {
        // Server unreachable: keep the token, show the login screen with the error.
        state = SessionState(serverUrl: state.serverUrl);
      }
    }
  }

  Future<void> setServer(String url) async {
    final normalized = normalizeServerUrl(url);
    await _prefs.setString(_kServer, normalized);
    state = SessionState(serverUrl: normalized);
  }

  Future<void> signedIn(String token, User user) async {
    await _prefs.setString(_kToken, token);
    state = SessionState(serverUrl: state.serverUrl, token: token, user: user);
  }

  void updateUser(User user) => state = state.copyWith(user: user);

  Future<void> logout() async {
    try {
      await ref.read(apiProvider).logout();
    } catch (_) {
      // Logging out locally is enough if the server is unreachable.
    }
    await _prefs.remove(_kToken);
    state = SessionState(serverUrl: state.serverUrl);
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, SessionState>(SessionNotifier.new);

final apiProvider = Provider<ApiClient>((ref) {
  final s = ref.watch(sessionProvider.select((s) => (s.serverUrl, s.token)));
  return ApiClient(s.$1 ?? '', s.$2, languageCode: ref.watch(appLocaleProvider).languageCode);
});

final currentUserIdProvider = Provider<String?>((ref) => ref.watch(sessionProvider.select((s) => s.user?.id)));
