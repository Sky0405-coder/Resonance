import 'l10n/l10n.dart';
import 'l10n/locale.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/session.dart';
import 'core/theme.dart';
import 'router.dart';
import 'ui/pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialL10n = lookupAppLocalizations(resolveAppLocale(WidgetsBinding.instance.platformDispatcher.locales));
  // Clean URLs (/register?invite=…) so invite links work in the browser.
  usePathUrlStrategy();

  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows)) {
    // just_audio has no native Linux/Windows backend; media_kit (libmpv) provides it.
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    // Media notification, lock screen controls and background playback.
    await JustAudioBackground.init(
      androidNotificationChannelId: 'de.knode.resonance.playback',
      androidNotificationChannelName: initialL10n.settingsPlayback,
      androidNotificationOngoing: true,
    );
  }

  final prefs = await SharedPreferences.getInstance();
  runApp(ProviderScope(overrides: [prefsProvider.overrideWithValue(prefs)], child: const ResonanceApp()));
}

class ResonanceApp extends ConsumerStatefulWidget {
  const ResonanceApp({super.key});

  @override
  ConsumerState<ResonanceApp> createState() => _ResonanceAppState();
}

class _ResonanceAppState extends ConsumerState<ResonanceApp> {
  @override
  void initState() {
    super.initState();
    applyPlaybackPrefs(ref);
  }

  @override
  Widget build(BuildContext context) {
    final accent = parseHexColor(ref.watch(sessionProvider.select((s) => s.user?.accentColor)));
    return MaterialApp.router(
      onGenerateTitle: (context) => context.l10n.commonProductName,
      supportedLocales: const [Locale('de'), Locale('en')],
      localeListResolutionCallback: (locales, supportedLocales) => resolveAppLocale(locales),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final locale = Localizations.localeOf(context);
        if (ref.read(appLocaleProvider) != locale) {
          Future.microtask(() {
            if (mounted) ref.read(appLocaleProvider.notifier).setLocale(locale);
          });
        }
        return child!;
      },
      debugShowCheckedModeBanner: false,
      theme: buildTheme(accent),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
