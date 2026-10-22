import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import '../widgets/collection.dart';

String countryFlag(String code) {
  final upper = code.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(upper)) return '';
  return String.fromCharCodes(upper.codeUnits.map((unit) => unit + 0x1F1E6 - 65));
}

Future<void> playWorldRadio(BuildContext context, WidgetRef ref, Station station) async {
  try {
    await ref.read(playerProvider.notifier).playStation(station);
  } catch (error) {
    if (context.mounted) showError(context, error);
  }
}

class WorldRadioPage extends ConsumerStatefulWidget {
  const WorldRadioPage({super.key});

  @override
  ConsumerState<WorldRadioPage> createState() => _WorldRadioPageState();
}

class _WorldRadioPageState extends ConsumerState<WorldRadioPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _toggling = <String>{};
  Timer? _debounce;
  late String _country;
  String? _tag;
  String _query = '';
  bool _favorites = false;
  List<Station> _stations = [];
  bool _loading = false;
  bool _more = true;
  int _generation = 0;
  int _offset = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _country = WidgetsBinding.instance.platformDispatcher.locale.countryCode ?? 'DE';
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 300) _load();
    });
    Future.microtask(_reload);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    _generation++;
    setState(() {
      _stations = [];
      _offset = 0;
      _more = true;
      _loading = false;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  Future<void> _load() async {
    if (!mounted || _favorites || _loading || !_more) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final stations = await ref
          .read(apiProvider)
          .worldRadioStations(country: _country, tag: _tag, q: _query, offset: _offset);
      if (!mounted || generation != _generation) return;
      setState(() {
        _stations = [..._stations, ...stations];
        _offset += 50;
        _more = stations.isNotEmpty;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _scroll.position.extentAfter < 300) _load();
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _toggle(Station station, bool favorite) async {
    setState(() => _toggling.add(station.id));
    try {
      final api = ref.read(apiProvider);
      if (favorite) {
        await api.removeWorldRadioFavorite(station.id);
      } else {
        await api.addWorldRadioFavorite(station.id);
      }
      ref.invalidate(worldRadioFavoritesProvider);
      await ref.read(worldRadioFavoritesProvider.future);
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _toggling.remove(station.id));
    }
  }

  Future<void> _chooseCountry() async {
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CountrySheet(selected: _country),
    );
    if (!mounted || code == null || code == _country) return;
    setState(() => _country = code);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final favorites = ref.watch(worldRadioFavoritesProvider);
    final favoriteIds = {for (final station in favorites.value ?? <Station>[]) station.id};
    final countries = ref.watch(worldRadioCountriesProvider).value ?? [];
    final country = countries.where((item) => item['code'] == _country).firstOrNull;
    final tags = ref.watch(worldRadioTagsProvider).value ?? [];
    final stations = _favorites
        ? (favorites.value ?? <Station>[])
              .where((station) => station.name.toLowerCase().contains(_query.toLowerCase()))
              .toList()
        : _stations;
    final error = _favorites ? favorites.error : _error;
    final loading = _favorites ? favorites.isLoading : _loading;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.worldRadioTitle)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: TextField(
              controller: _search,
              decoration: searchDecoration(context.l10n.worldRadioSearchHint),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), () {
                  _query = value.trim();
                  _reload();
                });
              },
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(context.l10n.worldRadioFavorites),
                    selected: _favorites,
                    onSelected: (selected) {
                      setState(() {
                        _favorites = selected;
                        _tag = null;
                      });
                      _reload();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${countryFlag(_country)} ${country?['name'] ?? _country}'),
                    selected: !_favorites,
                    onSelected: (_) => _chooseCountry(),
                  ),
                ),
                for (final tag in tags)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(tag),
                      selected: _tag == tag,
                      onSelected: (selected) {
                        setState(() {
                          _favorites = false;
                          _tag = selected ? tag : null;
                        });
                        _reload();
                      },
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: loading && stations.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : error != null && stations.isEmpty
                ? AsyncBody<List<Station>>(
                    value: AsyncError(error, StackTrace.empty),
                    onRetry: () => _favorites ? ref.invalidate(worldRadioFavoritesProvider) : _reload(),
                    builder: (_) => const SizedBox.shrink(),
                  )
                : stations.isEmpty
                ? Center(child: Text(context.l10n.commonNothingFound))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.only(bottom: kBottomInset),
                    itemCount: stations.length + (loading || error != null ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == stations.length) {
                        return error != null
                            ? TextButton(onPressed: _load, child: Text(context.l10n.commonRetry))
                            : const Center(child: CircularProgressIndicator());
                      }
                      final station = stations[index];
                      final favorite = favoriteIds.contains(station.id);
                      return ListTile(
                        leading: SizedBox(
                          width: 48,
                          height: 48,
                          child: NetworkCover(url: station.favicon, radius: 6, icon: Icons.radio),
                        ),
                        title: Text(station.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            [station.country, if (station.tags.isNotEmpty) station.tags.join(', ')].join(' · '),
                            if (station.codec.isNotEmpty || station.bitrate != null)
                              [
                                if (station.codec.isNotEmpty) station.codec,
                                if (station.bitrate != null) '${station.bitrate} kbps',
                              ].join(' '),
                          ].join('\n'),
                        ),
                        trailing: IconButton(
                          tooltip: context.l10n.worldRadioFavorites,
                          icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
                          color: favorite ? Theme.of(context).colorScheme.primary : null,
                          onPressed: _toggling.contains(station.id) ? null : () => _toggle(station, favorite),
                        ),
                        onTap: () => playWorldRadio(context, ref, station),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _CountrySheet extends ConsumerStatefulWidget {
  const _CountrySheet({required this.selected});
  final String selected;

  @override
  ConsumerState<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends ConsumerState<_CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                autofocus: true,
                decoration: searchDecoration(context.l10n.worldRadioSearchCountry),
                onChanged: (value) => setState(() => _query = value.toLowerCase()),
              ),
            ),
            Expanded(
              child: AsyncBody(
                value: ref.watch(worldRadioCountriesProvider),
                onRetry: () => ref.invalidate(worldRadioCountriesProvider),
                builder: (countries) => ListView(
                  children: [
                    for (final country in countries)
                      if ('${country['name']} ${country['code']}'.toLowerCase().contains(_query))
                        ListTile(
                          leading: Text(countryFlag(country['code']), style: const TextStyle(fontSize: 28)),
                          title: Text(country['name']),
                          subtitle: Text('${country['stations']}'),
                          selected: country['code'] == widget.selected,
                          onTap: () => Navigator.pop(context, country['code']),
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

class StationCard extends ConsumerWidget {
  const StationCard({super.key, required this.station});
  final Station station;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
    width: 160,
    child: Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => playWorldRadio(context, ref, station),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NetworkCover(url: station.favicon, radius: 6, icon: Icons.radio),
              const SizedBox(height: 8),
              Text(
                station.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                station.country,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textMuted),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
