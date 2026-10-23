import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../pages/world_radio_page.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_focusable.dart';
import 'tv_shelves.dart';

final tvWorldRadioStationsProvider = FutureProvider.autoDispose.family<List<Station>, (String, String?)>((ref, query) {
  return ref.watch(apiProvider).worldRadioStations(country: query.$1, tag: query.$2);
});

final tvWorldRadioSearchProvider = FutureProvider.autoDispose.family<List<Station>, String>((ref, query) {
  return ref.watch(apiProvider).worldRadioStations(q: query, country: null);
});

class TvWorldRadioPage extends ConsumerStatefulWidget {
  const TvWorldRadioPage({super.key});

  @override
  ConsumerState<TvWorldRadioPage> createState() => _TvWorldRadioPageState();
}

class _TvWorldRadioPageState extends ConsumerState<TvWorldRadioPage> {
  late String _country;
  String? _tag;

  @override
  void initState() {
    super.initState();
    _country =
        ref.read(prefsProvider).getString(worldRadioCountryKey) ??
        WidgetsBinding.instance.platformDispatcher.locale.countryCode ??
        'DE';
  }

  Future<void> _chooseCountry() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _TvRadioCountryDialog(selected: _country),
    );
    if (!mounted || selected == null || selected == _country) return;
    await ref.read(prefsProvider).setString(worldRadioCountryKey, selected);
    if (mounted) setState(() => _country = selected);
  }

  Future<void> _chooseTag() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (_) => _TvRadioGenreDialog(selected: _tag),
    );
    if (!mounted || selected == null) return;
    setState(() => _tag = selected.isEmpty ? null : selected);
  }

  @override
  Widget build(BuildContext context) {
    final countries = ref.watch(worldRadioCountriesProvider).value ?? const <Map<String, dynamic>>[];
    final country = countries.where((item) => item['code'] == _country).firstOrNull;
    final countryName = country?['name'] as String? ?? _country;
    final favorites = ref.watch(worldRadioFavoritesProvider);
    final stations = ref.watch(tvWorldRadioStationsProvider((_country, null)));
    final tagged = _tag == null ? null : ref.watch(tvWorldRadioStationsProvider((_country, _tag)));
    final favoriteCards = [
      for (final station in favorites.value ?? const <Station>[]) _tvStation(context, ref, station),
      if ((favorites.value ?? const <Station>[]).isEmpty)
        TvCardData(
          title: context.l10n.worldRadioFavoriteHint,
          image: const Center(child: Icon(Icons.star_border, size: 76)),
          onActivate: () {},
        ),
    ];

    return TvAsync(
      value: stations,
      onRetry: () {
        ref.invalidate(tvWorldRadioStationsProvider((_country, null)));
        ref.invalidate(worldRadioFavoritesProvider);
      },
      builder: (popular) => TvShelves(
        title: context.l10n.worldRadioTitle,
        leading: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TvButton(
                icon: Icons.search,
                label: context.l10n.worldRadioSearch,
                autofocus: true,
                onPressed: () => context.push('/world-radio/search'),
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TvButton(
                icon: Icons.public,
                label: '${context.l10n.worldRadioCountry}: ${countryFlag(_country)} $countryName',
                onPressed: _chooseCountry,
              ),
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TvButton(
                icon: Icons.category_outlined,
                label: context.l10n.worldRadioGenres,
                onPressed: _chooseTag,
              ),
            ),
          ],
        ),
        shelves: [
          TvShelfData(context.l10n.worldRadioYourStations, favoriteCards),
          TvShelfData('${countryFlag(_country)} ${context.l10n.worldRadioPopularInCountry(countryName)}', [
            for (final station in popular) _tvStation(context, ref, station),
          ]),
          if (tagged?.value case final tagStations? when _tag != null)
            TvShelfData(_tag!, [for (final station in tagStations) _tvStation(context, ref, station)]),
        ],
      ),
    );
  }
}

TvCardData _tvStation(BuildContext context, WidgetRef ref, Station station) => TvCardData(
  title: station.name,
  subtitle: station.country,
  image: NetworkCover(url: station.favicon, icon: Icons.radio),
  onActivate: () => playWorldRadio(context, ref, station),
);

class _TvRadioCountryDialog extends ConsumerWidget {
  const _TvRadioCountryDialog({required this.selected});

  final String selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
    title: Text(context.l10n.worldRadioCountry),
    content: SizedBox(
      width: 700,
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: TvAsync(
        value: ref.watch(worldRadioCountriesProvider),
        onRetry: () => ref.invalidate(worldRadioCountriesProvider),
        builder: (countries) => ListView(
          children: [
            for (final country in countries)
              TvFocusable(
                autofocus: country['code'] == selected,
                focusScale: 1.015,
                onActivate: () => Navigator.pop(context, country['code'] as String),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 56,
                        child: Text(countryFlag(country['code'] as String), style: const TextStyle(fontSize: 30)),
                      ),
                      Expanded(child: Text(country['name'] as String)),
                      Text(
                        context.l10n.worldRadioStationCount((country['stations'] as num?)?.toInt() ?? 0),
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _TvRadioGenreDialog extends ConsumerWidget {
  const _TvRadioGenreDialog({required this.selected});

  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
    title: Text(context.l10n.worldRadioGenres),
    content: SizedBox(
      width: 700,
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: TvAsync(
        value: ref.watch(worldRadioTagsProvider),
        onRetry: () => ref.invalidate(worldRadioTagsProvider),
        builder: (tags) => ListView(
          children: [
            TvFocusable(
              autofocus: selected == null,
              focusScale: 1.015,
              onActivate: () => Navigator.pop(context, ''),
              child: Padding(padding: const EdgeInsets.all(16), child: Text(context.l10n.worldRadioAllGenres)),
            ),
            for (final tag in tags)
              TvFocusable(
                autofocus: tag == selected,
                focusScale: 1.015,
                onActivate: () => Navigator.pop(context, tag),
                child: Padding(padding: const EdgeInsets.all(16), child: Text(tag)),
              ),
          ],
        ),
      ),
    ),
  );
}

class TvRadioSearchPage extends ConsumerStatefulWidget {
  const TvRadioSearchPage({super.key});

  @override
  ConsumerState<TvRadioSearchPage> createState() => _TvRadioSearchPageState();
}

class _TvRadioSearchPageState extends ConsumerState<TvRadioSearchPage> {
  final _text = TextEditingController();
  final _field = FocusNode();
  Timer? _debounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (_field.hasFocus && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _field.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _debounce?.cancel();
    _text.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(32),
        child: TvFocusable(
          focusScale: 1.015,
          skipTraversal: true,
          descendantsAreFocusable: true,
          onActivate: () {
            _field.requestFocus();
            SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          },
          child: TextField(
            controller: _text,
            focusNode: _field,
            autofocus: true,
            style: const TextStyle(fontSize: 28),
            decoration: searchDecoration(context.l10n.worldRadioSearchHint),
            textInputAction: TextInputAction.search,
            onChanged: (value) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () {
                if (mounted) setState(() => _query = value.trim());
              });
            },
          ),
        ),
      ),
      Expanded(
        child: _query.isEmpty
            ? const SizedBox.shrink()
            : TvAsync(
                value: ref.watch(tvWorldRadioSearchProvider(_query)),
                onRetry: () => ref.invalidate(tvWorldRadioSearchProvider(_query)),
                builder: (stations) => TvShelves(
                  title: context.l10n.worldRadioSearch,
                  shelves: [
                    TvShelfData(context.l10n.worldRadioTitle, [
                      for (final station in stations) _tvStation(context, ref, station),
                    ]),
                  ],
                ),
              ),
      ),
    ],
  );
}
