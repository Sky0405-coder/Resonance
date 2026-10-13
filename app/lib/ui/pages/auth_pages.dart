import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';

final authStatusProvider = FutureProvider.autoDispose<AuthStatus>((ref) => ref.watch(apiProvider).status());

class _AuthFrame extends StatelessWidget {
  const _AuthFrame({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Theme.of(context).colorScheme.primary.withValues(alpha: 0.25), Palette.background],
        ),
      ),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.graphic_eq, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 32),
                ...children,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Native apps: pick the server first. (The web app is served by the server itself.)
class ServerPage extends ConsumerStatefulWidget {
  const ServerPage({super.key});

  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  late final _url = TextEditingController(text: ref.read(sessionProvider).serverUrl ?? '');
  String? _error;
  bool _busy = false;

  Future<void> _connect() async {
    final url = normalizeServerUrl(_url.text);
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiClient(url, null).status();
      await ref.read(sessionProvider.notifier).setServer(url);
      if (mounted) context.go('/login');
    } on ApiException catch (e) {
      setState(() => _error = '${e.message}\nIst die Adresse richtig?');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthFrame(
    title: 'Mit Server verbinden',
    children: [
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Server-Adresse', hintText: 'musik.example.com'),
        onSubmitted: (_) => _connect(),
      ),
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 24),
      FilledButton(onPressed: _busy ? null : _connect, child: const Text('Verbinden')),
    ],
  );
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (token, user) = await ref.read(apiProvider).login(_user.text.trim(), _pass.text, deviceName);
      await ref.read(sessionProvider.notifier).signedIn(token, user);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(authStatusProvider);
    final server = ref.watch(sessionProvider.select((s) => s.serverUrl));
    return status.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => _AuthFrame(
        title: 'Server nicht erreichbar',
        children: [
          Text('$server\n${ApiException.from(e).message}', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => ref.invalidate(authStatusProvider), child: const Text('Erneut versuchen')),
          if (!kIsWeb) TextButton(onPressed: () => context.go('/server'), child: const Text('Anderer Server')),
        ],
      ),
      data: (s) {
        if (s.setupRequired) {
          return const RegisterPage(firstSetup: true);
        }
        return _AuthFrame(
          title: 'Bei ${s.serverName} anmelden',
          children: [
            TextField(
              controller: _user,
              autofocus: true,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(labelText: 'Benutzername'),
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Passwort'),
              onSubmitted: (_) => _login(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : _login, child: const Text('Anmelden')),
            if (s.registrationMode == 'public')
              TextButton(onPressed: () => context.go('/register'), child: const Text('Konto erstellen')),
            if (!kIsWeb)
              TextButton(
                onPressed: () => context.go('/server'),
                child: Text('Server: $server', style: const TextStyle(color: Palette.textMuted)),
              ),
          ],
        );
      },
    );
  }
}

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key, this.invite, this.firstSetup = false});
  final String? invite;
  final bool firstSetup;

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  String? _error;
  bool _busy = false;
  bool? _inviteValid;

  @override
  void initState() {
    super.initState();
    if (widget.invite != null) {
      ref.read(apiProvider).checkInvite(widget.invite!).then(
        (v) => mounted ? setState(() => _inviteValid = v) : null,
        onError: (_) => mounted ? setState(() => _inviteValid = false) : null,
      );
    }
  }

  Future<void> _register() async {
    if (_pass.text != _pass2.text) {
      setState(() => _error = 'Passwörter stimmen nicht überein');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final (token, user) = await ref
          .read(apiProvider)
          .register(_user.text.trim(), _pass.text, deviceName, invite: widget.invite);
      await ref.read(sessionProvider.notifier).signedIn(token, user);
      if (mounted) context.go('/');
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.invite != null && _inviteValid == false) {
      return _AuthFrame(
        title: 'Einladung ungültig',
        children: [
          const Text(
            'Dieser Einladungslink wurde bereits benutzt oder ist abgelaufen. Bitte frag einen Admin nach einem neuen Link.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          OutlinedButton(onPressed: () => context.go('/login'), child: const Text('Zur Anmeldung')),
        ],
      );
    }
    return _AuthFrame(
      title: widget.firstSetup ? 'Willkommen! Admin-Konto anlegen' : 'Konto erstellen',
      children: [
        if (widget.firstSetup)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Das erste Konto auf diesem Server wird automatisch Administrator.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Palette.textMuted),
            ),
          ),
        TextField(
          controller: _user,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Benutzername'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Passwort (min. 8 Zeichen)'),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pass2,
          obscureText: true,
          decoration: const InputDecoration(labelText: 'Passwort wiederholen'),
          onSubmitted: (_) => _register(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _register, child: const Text('Registrieren')),
        if (!widget.firstSetup)
          TextButton(onPressed: () => context.go('/login'), child: const Text('Ich habe schon ein Konto')),
      ],
    );
  }
}
