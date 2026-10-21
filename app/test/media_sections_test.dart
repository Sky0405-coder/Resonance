import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/audiobooks.dart';
import 'package:resonance/core/books.dart';
import 'package:resonance/core/media_sections.dart';
import 'package:resonance/core/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container({
  Map<String, Object> saved = const {},
  bool ebooksEnabled = true,
  bool audiobooksEnabled = true,
}) async {
  SharedPreferences.setMockInitialValues(saved);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      booksStatusProvider.overrideWith(
        (ref) async => BooksStatus(enabled: ebooksEnabled, requestsEnabled: false, defaultLanguage: 'de'),
      ),
      absStatusProvider.overrideWith((ref) async => AbsStatus(enabled: audiobooksEnabled, url: '', linked: false)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final legacy in [null, false]) {
    test('no sections are hidden when the legacy preference is $legacy', () async {
      final container = await _container(saved: {'books.hide_tab': ?legacy});
      expect(container.read(hiddenMediaSectionsProvider), isEmpty);
      expect(container.read(prefsProvider).containsKey('hidden_media_sections'), false);
    });
  }

  test('the legacy hidden books preference migrates only ebooks and writes the new key', () async {
    final container = await _container(saved: {'books.hide_tab': true});
    expect(container.read(hiddenMediaSectionsProvider), {MediaSection.ebooks});
    final prefs = container.read(prefsProvider);
    await prefs.reload();
    expect(prefs.getStringList('hidden_media_sections'), ['ebooks']);

    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.ebooks, false);
    final restored = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    addTearDown(restored.dispose);
    expect(restored.read(hiddenMediaSectionsProvider), isEmpty);
  });

  for (final saved in [
    <String>[],
    ['audiobooks', 'podcasts'],
  ]) {
    test('an existing new preference $saved takes priority over the legacy preference', () async {
      final container = await _container(saved: {'books.hide_tab': true, 'hidden_media_sections': saved});
      expect(container.read(hiddenMediaSectionsProvider), {
        if (saved.isNotEmpty) ...[MediaSection.audiobooks, MediaSection.podcasts],
      });
      expect(container.read(prefsProvider).getStringList('hidden_media_sections'), saved);
    });
  }

  test('saved enum names are restored and unknown sections are ignored', () async {
    final container = await _container(
      saved: {
        'hidden_media_sections': ['ebooks', 'audiobooks', 'podcasts', 'unknown'],
      },
    );
    expect(container.read(hiddenMediaSectionsProvider), MediaSection.values.toSet());
  });

  test('sections can be hidden and shown independently and survive a reload', () async {
    final container = await _container();
    final notifier = container.read(hiddenMediaSectionsProvider.notifier);
    notifier.setHidden(MediaSection.ebooks, true);
    final before = container.read(hiddenMediaSectionsProvider);
    notifier.setHidden(MediaSection.audiobooks, true);
    notifier.setHidden(MediaSection.podcasts, true);
    notifier.setHidden(MediaSection.ebooks, false);
    expect(before, {MediaSection.ebooks});
    expect(container.read(hiddenMediaSectionsProvider), {MediaSection.audiobooks, MediaSection.podcasts});
    final prefs = container.read(prefsProvider);
    await prefs.reload();
    expect(prefs.getStringList('hidden_media_sections'), unorderedEquals(['audiobooks', 'podcasts']));

    final restored = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    addTearDown(restored.dispose);
    expect(restored.read(hiddenMediaSectionsProvider), {MediaSection.audiobooks, MediaSection.podcasts});
    restored.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.audiobooks, false);
    expect(restored.read(hiddenMediaSectionsProvider), {MediaSection.podcasts});
  });

  for (final ebooksEnabled in [false, true]) {
    for (final audiobooksEnabled in [false, true]) {
      test(
        'visibility follows each hidden flag with server ebooks=$ebooksEnabled, audiobooks=$audiobooksEnabled',
        () async {
          final container = await _container(ebooksEnabled: ebooksEnabled, audiobooksEnabled: audiobooksEnabled);
          await Future.wait([container.read(booksStatusProvider.future), container.read(absStatusProvider.future)]);
          final notifier = container.read(hiddenMediaSectionsProvider.notifier);
          for (final ebooksHidden in [false, true]) {
            for (final audiobooksHidden in [false, true]) {
              notifier.setHidden(MediaSection.ebooks, ebooksHidden);
              notifier.setHidden(MediaSection.audiobooks, audiobooksHidden);
              expect(container.read(ebooksVisibleProvider), ebooksEnabled && !ebooksHidden);
              expect(container.read(audiobooksVisibleProvider), audiobooksEnabled && !audiobooksHidden);
            }
          }
          notifier.setHidden(MediaSection.ebooks, false);
          notifier.setHidden(MediaSection.audiobooks, false);
          notifier.setHidden(MediaSection.podcasts, true);
          expect(container.read(ebooksVisibleProvider), ebooksEnabled);
          expect(container.read(audiobooksVisibleProvider), audiobooksEnabled);
        },
      );
    }
  }

  test('visibility waits for server status and updates when server features change', () async {
    final container = await _container();
    final prefs = container.read(prefsProvider);
    final books = Completer<BooksStatus>();
    final audiobooks = Completer<AbsStatus>();
    var enabled = true;
    final pending = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        booksStatusProvider.overrideWith((ref) async {
          await books.future;
          return BooksStatus(enabled: enabled, requestsEnabled: false, defaultLanguage: 'de');
        }),
        absStatusProvider.overrideWith((ref) async {
          await audiobooks.future;
          return AbsStatus(enabled: enabled, url: '', linked: false);
        }),
      ],
    );
    addTearDown(pending.dispose);
    expect(pending.read(ebooksVisibleProvider), false);
    expect(pending.read(audiobooksVisibleProvider), false);
    books.complete(const BooksStatus(enabled: true, requestsEnabled: false, defaultLanguage: 'de'));
    audiobooks.complete(const AbsStatus(enabled: true, url: '', linked: false));
    await Future.wait([pending.read(booksStatusProvider.future), pending.read(absStatusProvider.future)]);
    expect(pending.read(ebooksVisibleProvider), true);
    expect(pending.read(audiobooksVisibleProvider), true);

    enabled = false;
    pending.invalidate(booksStatusProvider);
    pending.invalidate(absStatusProvider);
    await Future.wait([pending.read(booksStatusProvider.future), pending.read(absStatusProvider.future)]);
    expect(pending.read(ebooksVisibleProvider), false);
    expect(pending.read(audiobooksVisibleProvider), false);
    expect(pending.read(hiddenMediaSectionsProvider), isEmpty);
  });
}
