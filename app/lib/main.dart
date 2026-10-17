import 'l10n/l10n.dart';
import 'l10n/locale.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/desktop.dart';
import 'core/session.dart';
import 'integrations/discord_presence.dart';
import 'offline/offline_store.dart';
import 'player/audio_handler.dart';
import 'core/theme.dart';
import 'router.dart';
import 'ui/pages/settings_page.dart';
import 'ui/widgets/shortcuts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final initialL10n = lookupAppLocalizations(resolveAppLocale(WidgetsBinding.instance.platformDispatcher.locales));
  // Clean URLs (/register?invite=…) so invite links work in the browser.
  usePathUrlStrategy();

  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows)) {
    // just_audio has no native Linux/Windows backend; media_kit (libmpv) provides it.
    JustAudioMediaKit.ensureInitialized(linux: true, windows: true);
  }
  final prefs = await SharedPreferences.getInstance();
  if (isDesktop) await initDesktopWindow(prefs);
  final container = ProviderContainer(
    overrides: [prefsProvider.overrideWithValue(prefs), audioHandlerProvider.overrideWithValue(null)],
  );
  if (!kIsWeb) await container.read(offlineProvider.notifier).load();
  if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || isDesktop)) {
    // Android: media notification, lock screen controls and background playback.
    // Linux (MPRIS) and Windows (media overlay): media keys and the system's player controls.
    final handler = await AudioService.init(
      builder: () => ResonanceAudioHandler(container),
      config: AudioServiceConfig(
        // Linux uses these for the MPRIS bus name (org.mpris.MediaPlayer2.resonance…) and the player's name.
        androidNotificationChannelId: isDesktop ? 'resonance' : 'de.knode.resonance.playback',
        androidNotificationChannelName: isDesktop ? 'Resonance' : initialL10n.settingsPlayback,
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'drawable/ic_stat_resonance',
        preloadArtwork: true,
        artDownscaleWidth: 512,
        artDownscaleHeight: 512,
        androidBrowsableRootExtras: const {
          'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT': 2,
          'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT': 1,
        },
      ),
    );
    container.updateOverrides([
      prefsProvider.overrideWithValue(prefs),
      audioHandlerProvider.overrideWith((ref) {
        ref.onDispose(handler.dispose);
        return handler;
      }),
    ]);
  }

  runApp(UncontrolledProviderScope(container: container, child: const ResonanceApp()));
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
    if (isDiscordDesktop) ref.watch(discordPresenceProvider);
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
        return PlayerShortcuts(child: child!);
      },
      debugShowCheckedModeBanner: false,
      theme: buildTheme(accent),
      routerConfig: ref.watch(routerProvider),
    );
  }
}
