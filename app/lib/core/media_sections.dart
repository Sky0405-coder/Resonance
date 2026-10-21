import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session.dart';

const _kHiddenMediaSections = 'hidden_media_sections';
const _kHideBooks = 'books.hide_tab';

enum MediaSection { ebooks, audiobooks, podcasts }

final hiddenMediaSectionsProvider = NotifierProvider<HiddenMediaSections, Set<MediaSection>>(HiddenMediaSections.new);

class HiddenMediaSections extends Notifier<Set<MediaSection>> {
  @override
  Set<MediaSection> build() {
    final prefs = ref.read(prefsProvider);
    if (!prefs.containsKey(_kHiddenMediaSections) && (prefs.getBool(_kHideBooks) ?? false)) {
      prefs.setStringList(_kHiddenMediaSections, [MediaSection.ebooks.name]);
      return const {MediaSection.ebooks};
    }
    final saved = prefs.getStringList(_kHiddenMediaSections) ?? const <String>[];
    return Set.unmodifiable(MediaSection.values.where((section) => saved.contains(section.name)));
  }

  void setHidden(MediaSection section, bool hidden) {
    final sections = {...state};
    if (hidden) {
      sections.add(section);
    } else {
      sections.remove(section);
    }
    ref.read(prefsProvider).setStringList(_kHiddenMediaSections, sections.map((section) => section.name).toList());
    state = Set.unmodifiable(sections);
  }
}
