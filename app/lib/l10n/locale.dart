import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

Locale resolveAppLocale(List<Locale>? locales) {
  for (final locale in locales ?? const <Locale>[]) {
    if (locale.languageCode == 'de') return const Locale('de');
    if (locale.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}

class AppLocale extends Notifier<Locale> {
  @override
  Locale build() => resolveAppLocale(WidgetsBinding.instance.platformDispatcher.locales);

  void setLocale(Locale locale) {
    if (state != locale) state = locale;
  }
}

final appLocaleProvider = NotifierProvider<AppLocale, Locale>(AppLocale.new);
