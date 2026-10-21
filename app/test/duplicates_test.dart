import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/admin/duplicates_page.dart';

DuplicateGroup _group(String name, {String kind = 'same_album', bool pending = false, String? keeperId}) =>
    DuplicateGroup.fromJson({
      'kind': kind,
      'verified': !pending,
      'pending': pending,
      'album_id': name,
      'album_title': name,
      'artist_name': 'Artist',
      'tracks': [
        for (final keep in [true, false])
          {
            'id': keep && keeperId != null ? keeperId : '$name-$keep',
            'title': name,
            'path': '$name/$keep.flac',
            'codec': 'flac',
            'size': 5,
            'duration': 200,
            'keep': keep,
          },
      ],
    });

class _DuplicatesApi extends ApiClient {
  _DuplicatesApi(this.groups) : super('http://localhost', 'token');

  final List<DuplicateGroup> groups;
  final merges = <({List<String> keepIds, String? kind})>[];

  @override
  Future<List<DuplicateGroup>> duplicates() async => groups;

  @override
  Future<DuplicateMergeResult> mergeDuplicates(List<String> keepIds, {String? kind}) async {
    merges.add((keepIds: keepIds, kind: kind));
    return const DuplicateMergeResult(mergedGroups: 1, deletedTracks: 1, freedBytes: 5);
  }
}

Future<_DuplicatesApi> _showPage(WidgetTester tester, List<DuplicateGroup> groups, String locale) async {
  tester.view.physicalSize = const Size(1000, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final api = _DuplicatesApi(groups);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DuplicatesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('DuplicateGroup.fromJson parses tracks and keep flags', () {
    final group = DuplicateGroup.fromJson({
      'album_id': 'album',
      'album_title': 'Fallen',
      'artist_name': 'Evanescence',
      'tracks': [
        for (final keep in [true, false])
          {
            'id': keep ? 'flac' : 'mp3',
            'title': 'Going Under',
            'path': 'Evanescence/Fallen/01 - Going Under.${keep ? 'flac' : 'mp3'}',
            'codec': keep ? 'flac' : null,
            'bitrate': keep ? 989 : null,
            'size': keep ? 25100000 : 5000000,
            'duration': keep ? 210 : 210.5,
            'keep': keep,
          },
      ],
    });

    expect(group.albumId, 'album');
    expect(group.albumTitle, 'Fallen');
    expect(group.artistName, 'Evanescence');
    expect(group.kind, 'same_album');
    expect(group.verified, isTrue);
    expect(group.pending, isFalse);
    expect(group.tracks.first.album, '');
    expect(group.tracks.map((track) => track.keep), [true, false]);
    expect(group.tracks.first.codec, 'flac');
    expect(group.tracks.first.bitrate, 989);
    expect(group.tracks.first.size, 25100000);
    expect(group.tracks.first.duration, 210.0);
    expect(group.tracks.last.codec, isNull);
    expect(group.tracks.last.bitrate, isNull);
    expect(group.tracks.last.duration, 210.5);
  });

  test('DuplicateGroup.fromJson parses cross-album groups', () {
    final group = DuplicateGroup.fromJson({
      'kind': 'cross_album',
      'verified': true,
      'pending': false,
      'album_id': 'album',
      'album_title': 'Blurryface',
      'artist_name': 'twenty one pilots',
      'tracks': [
        for (final album in ['Blurryface', 'Stressed Out'])
          {
            'id': album,
            'title': 'Stressed Out',
            'album': album,
            'path': '$album/song.flac',
            'size': 5,
            'duration': 202.335,
            'keep': album == 'Blurryface',
          },
      ],
    });

    expect(group.kind, 'cross_album');
    expect(group.verified, isTrue);
    expect(group.pending, isFalse);
    expect(group.tracks.map((track) => track.album), ['Blurryface', 'Stressed Out']);
  });

  test('DuplicateGroup parses pending groups', () {
    final group = _group('Pending', kind: 'cross_album', pending: true);
    expect(group.verified, isFalse);
    expect(group.pending, isTrue);
  });

  for (final locale in ['en', 'de']) {
    testWidgets('duplicate selection defaults and pending label in $locale', (tester) async {
      await _showPage(tester, [
        _group('Same'),
        _group('Cross', kind: 'cross_album', keeperId: 'Same-true'),
        _group('Pending', kind: 'cross_album', pending: true),
      ], locale);
      List<CheckboxListTile> rows() => tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(rows().map((row) => row.value), [true, false, false]);
      expect(rows()[0].onChanged, isNotNull);
      expect(rows()[1].onChanged, isNotNull);
      expect(rows()[2].onChanged, isNull);
      expect(find.text(locale == 'en' ? 'Still being checked' : 'Wird noch geprüft'), findsOneWidget);
      expect(
        find.text(locale == 'en' ? 'Different albums · same recording' : 'Verschiedene Alben · gleiche Aufnahme'),
        findsOneWidget,
      );
      expect(find.text(locale == 'en' ? 'Delete 1 duplicates' : '1 Duplikate löschen'), findsOneWidget);
      final hint = tester.widget<Text>(find.textContaining(locale == 'en' ? 'songs have multiple' : 'Songs liegen'));
      expect(hint.data, startsWith('2 '));
      expect(hint.data, contains(locale == 'en' ? 'nothing needs to be re-added' : 'du musst nichts neu hinzufügen'));

      await tester.tap(find.text(locale == 'en' ? 'Select all' : 'Alle auswählen'));
      await tester.pumpAndSettle();
      expect(rows().map((row) => row.value), [true, true, false]);
      expect(rows()[2].onChanged, isNull);
      expect(find.text(locale == 'en' ? 'Delete 2 duplicates' : '2 Duplikate löschen'), findsOneWidget);

      await tester.tap(find.text(locale == 'en' ? 'Select none' : 'Keine auswählen'));
      await tester.pumpAndSettle();
      expect(rows().map((row) => row.value), [false, false, false]);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    });
  }

  testWidgets('pending-only groups cannot be selected or counted', (tester) async {
    await _showPage(tester, [_group('Pending', kind: 'cross_album', pending: true)], 'en');
    final row = tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(row.value, isFalse);
    expect(row.onChanged, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Select all')).onPressed, isNull);
    expect(find.text('Delete 0 duplicates'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  for (final kind in ['same_album', 'cross_album']) {
    testWidgets('merging $kind preserves selection when keepers overlap', (tester) async {
      final api = await _showPage(tester, [
        _group('Same'),
        _group('Cross', kind: 'cross_album', keeperId: 'Same-true'),
      ], 'en');
      if (kind == 'cross_album') {
        await tester.tap(find.byType(CheckboxListTile).first);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(CheckboxListTile).last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Delete 1 duplicates'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(api.merges, hasLength(1));
      expect(api.merges.single.keepIds, ['Same-true']);
      expect(api.merges.single.kind, kind);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
