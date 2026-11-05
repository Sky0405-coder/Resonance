import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/library.dart';
import '../../core/review.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../widgets/common.dart';

/// The yearly review of [year] (this year without one).
final wrappedProvider = FutureProvider.autoDispose.family<Wrapped, int?>(
  (ref, year) => ref.watch(apiProvider).wrapped(year),
);

/// Which year the review is about: from December the current one, in January still the last one.
int wrappedSeasonYear(DateTime now) => now.month == 1 ? now.year - 1 : now.year;

/// Home shows the review in December and January, like Spotify Wrapped.
bool wrappedSeason(DateTime now) => now.month == 12 || now.month == 1;

/// The part of the day an hour belongs to, for "you listen most …".
String listeningTime(AppLocalizations l10n, int hour) => hour >= 5 && hour < 11
    ? l10n.wrappedMorning
    : hour >= 11 && hour < 17
    ? l10n.wrappedAfternoon
    : hour >= 17 && hour < 22
    ? l10n.wrappedEvening
    : l10n.wrappedNight;

/// One page of the story: its colors and content.
class _Slide {
  const _Slide(this.colors, this.build);
  final List<Color> colors;
  final Widget Function(BuildContext context) build;
}

const _slideDuration = Duration(seconds: 8);

/// The yearly review as a story: pages that move on by themselves, tap right for the next and left for the
/// previous one, hold to pause.
class WrappedPage extends ConsumerWidget {
  const WrappedPage({super.key, this.year});
  final int? year;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(wrappedProvider(year));
    return Scaffold(
      backgroundColor: Colors.black,
      body: value.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _Message(
          text: ApiException.from(e, context.l10n).message,
          onRetry: () => ref.invalidate(wrappedProvider(year)),
        ),
        data: (wrapped) => wrapped.isEmpty
            ? _Message(text: context.l10n.wrappedEmpty(wrapped.year), years: wrapped.years, year: wrapped.year)
            : _Story(key: ValueKey(wrapped.year), wrapped: wrapped),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry, this.years = const [], this.year});
  final String text;
  final VoidCallback? onRetry;
  final List<int> years;
  final int? year;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Stack(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(onPressed: onRetry, child: Text(context.l10n.commonRetry)),
                ],
                for (final other in years.reversed.where((y) => y != year))
                  TextButton(
                    onPressed: () => context.pushReplacement('/wrapped?year=$other'),
                    child: Text(context.l10n.wrappedYearButton(other)),
                  ),
              ],
            ),
          ),
        ),
        const Positioned(top: 8, right: 8, child: CloseButton(color: Colors.white)),
      ],
    ),
  );
}

class _Story extends ConsumerStatefulWidget {
  const _Story({super.key, required this.wrapped});
  final Wrapped wrapped;

  @override
  ConsumerState<_Story> createState() => _StoryState();
}

class _StoryState extends ConsumerState<_Story> with SingleTickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this, duration: _slideDuration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed) _go(1);
    });
  var _index = 0;
  late List<_Slide> _slides;

  @override
  void initState() {
    super.initState();
    _progress.forward();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _go(int step) {
    final next = (_index + step).clamp(0, _slides.length - 1);
    if (next == _index) {
      // The last page stays (with its buttons); the first one starts over.
      if (step < 0) _progress.forward(from: 0);
      return;
    }
    setState(() => _index = next);
    _progress.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    _slides = _buildSlides(
      context,
      ref,
      widget.wrapped,
      onReplay: () {
        setState(() => _index = 0);
        _progress.forward(from: 0);
      },
    );
    final slide = _slides[_index];
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) => _go(details.globalPosition.dx < MediaQuery.sizeOf(context).width / 3 ? -1 : 1),
      onLongPressStart: (_) => _progress.stop(),
      onLongPressEnd: (_) => _progress.forward(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 600),
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: slide.colors),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    for (var i = 0; i < _slides.length; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: AnimatedBuilder(
                              animation: _progress,
                              builder: (_, _) => LinearProgressIndicator(
                                minHeight: 3,
                                value: i < _index ? 1 : (i == _index ? _progress.value : 0),
                                backgroundColor: Colors.white24,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const CloseButton(color: Colors.white),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  child: KeyedSubtree(
                    key: ValueKey(_index),
                    child: DefaultTextStyle(
                      style: const TextStyle(color: Colors.white),
                      // Centered, and scrollable where a page is taller than a small phone.
                      child: LayoutBuilder(
                        builder: (context, constraints) => SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(minHeight: constraints.maxHeight - 44),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 520),
                                child: slide.build(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lets its children come in one after another (fading and rising), once per page.
class _Reveal extends StatefulWidget {
  const _Reveal({required this.children, this.crossAxisAlignment = CrossAxisAlignment.start});
  final List<Widget> children;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 500 + 250 * widget.children.length),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.children.length;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: widget.crossAxisAlignment,
      children: [
        for (var i = 0; i < count; i++)
          Builder(
            builder: (_) {
              final start = i / (count + 1);
              final animation = CurvedAnimation(
                parent: _controller,
                curve: Interval(start, (start + 2 / (count + 1)).clamp(0, 1), curve: Curves.easeOutCubic),
              );
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
                  child: widget.children[i],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// A number counting up to [value].
class _CountUp extends StatelessWidget {
  const _CountUp(this.value, {this.style});
  final int value;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final format = NumberFormat.decimalPattern(context.l10n.localeName);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.toDouble()),
      duration: const Duration(milliseconds: 1800),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => Text(format.format(v.round()), style: style),
    );
  }
}

const _big = TextStyle(fontSize: 64, fontWeight: FontWeight.w900, height: 1.05, letterSpacing: -1.5);
const _title = TextStyle(fontSize: 30, fontWeight: FontWeight.w900, height: 1.15);
const _text = TextStyle(fontSize: 18, fontWeight: FontWeight.w600, height: 1.35);
const _small = TextStyle(fontSize: 15, color: Colors.white70, height: 1.35);

Widget _gap([double height = 16]) => SizedBox(height: height);

List<_Slide> _buildSlides(BuildContext context, WidgetRef ref, Wrapped w, {required VoidCallback onReplay}) {
  final l10n = context.l10n;
  final format = NumberFormat.decimalPattern(l10n.localeName);
  final topArtist = w.topArtists.firstOrNull;
  final topTrack = w.topTracks.firstOrNull;
  final peak = w.peakHour;
  final months = w.months.length == 12 ? w.months : List.filled(12, 0);
  var bestMonth = 0;
  for (var i = 1; i < 12; i++) {
    if (months[i] > months[bestMonth]) bestMonth = i;
  }
  final monthName = DateFormat.MMMM(l10n.localeName);
  return [
    _Slide(const [Color(0xFF1E3264), Color(0xFF8D67AB)], (context) {
      return _Reveal(
        children: [
          Text(l10n.wrappedIntroKicker, style: _text),
          _gap(),
          Text(l10n.wrappedIntroTitle(w.year), style: _big),
          _gap(24),
          Text(l10n.wrappedIntroHint, style: _small),
          if (w.years.length > 1) ...[
            _gap(24),
            Wrap(
              spacing: 8,
              children: [
                for (final y in w.years.reversed)
                  ChoiceChip(
                    label: Text('$y'),
                    selected: y == w.year,
                    onSelected: y == w.year ? null : (_) => context.pushReplacement('/wrapped?year=$y'),
                  ),
              ],
            ),
          ],
        ],
      );
    }),
    _Slide(const [Color(0xFFE13300), Color(0xFFF59B23)], (context) {
      final days = w.minutes / (60 * 24);
      return _Reveal(
        children: [
          Text(l10n.wrappedMinutesBefore, style: _text),
          _gap(8),
          _CountUp(w.minutes, style: _big),
          Text(l10n.wrappedMinutesAfter, style: _title),
          _gap(24),
          if (days >= 1) Text(l10n.wrappedMinutesDays(NumberFormat('0.#', l10n.localeName).format(days)), style: _text),
          if (w.topDay != null) ...[
            _gap(),
            Text(
              l10n.wrappedTopDay(DateFormat.MMMMd(l10n.localeName).format(w.topDay!), format.format(w.topDayMinutes)),
              style: _small,
            ),
          ],
        ],
      );
    }),
    if (w.topGenres.isNotEmpty)
      _Slide(const [Color(0xFF148A08), Color(0xFF0D3B66)], (context) {
        return _Reveal(
          children: [
            Text(l10n.wrappedGenresTitle, style: _title),
            _gap(24),
            for (final (i, (name, share)) in w.topGenres.indexed) ...[
              Row(
                children: [
                  SizedBox(width: 32, child: Text('${i + 1}', style: _text)),
                  Expanded(
                    child: Text(name, style: _text.copyWith(fontSize: i == 0 ? 26 : 18)),
                  ),
                  Text('${(share * 100).round()} %', style: _small),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 32, top: 6, bottom: 14),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: share / w.topGenres.first.$2),
                    duration: const Duration(milliseconds: 1200),
                    curve: Curves.easeOutCubic,
                    builder: (_, v, _) => LinearProgressIndicator(
                      value: v,
                      minHeight: 6,
                      color: Colors.white,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      }),
    if (topArtist != null)
      _Slide(const [Color(0xFF503750), Color(0xFFDC148C)], (context) {
        return _Reveal(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(l10n.wrappedTopArtistKicker, style: _text, textAlign: TextAlign.center),
            _gap(24),
            SizedBox(
              width: 220,
              height: 220,
              child: ClipOval(child: ArtistImage(artist: topArtist.artist, size: 600)),
            ),
            _gap(24),
            Text(topArtist.name, style: _big.copyWith(fontSize: 44), textAlign: TextAlign.center),
            _gap(12),
            Text(
              l10n.wrappedArtistStats(format.format(topArtist.minutes), format.format(topArtist.plays)),
              style: _small,
              textAlign: TextAlign.center,
            ),
          ],
        );
      }),
    if (w.topArtists.length > 1)
      _Slide(const [Color(0xFF8C1932), Color(0xFF1E3264)], (context) {
        return _Reveal(
          children: [
            Text(l10n.wrappedTopArtistsTitle, style: _title),
            _gap(24),
            for (final (i, artist) in w.topArtists.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(width: 32, child: Text('${i + 1}', style: _title.copyWith(fontSize: 22))),
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: ClipOval(child: ArtistImage(artist: artist.artist, size: 200)),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(artist.name, style: _text, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(l10n.wrappedPlays(format.format(artist.plays)), style: _small),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      }),
    if (topTrack != null)
      _Slide(const [Color(0xFF0D73EC), Color(0xFF27856A)], (context) {
        return _Reveal(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(l10n.wrappedTopSongKicker, style: _text, textAlign: TextAlign.center),
            _gap(24),
            SizedBox(width: 240, child: CoverImage(albumId: topTrack.track.album.id, size: 600, radius: 8)),
            _gap(20),
            Text(topTrack.track.title, style: _title, textAlign: TextAlign.center),
            Text(
              topTrack.track.artistCredit,
              style: _text.copyWith(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            _gap(12),
            Text(l10n.wrappedSongStats(format.format(topTrack.plays)), style: _small),
            _gap(16),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: () => playMusic(context, ref, [for (final t in w.topTracks) t.track], index: 0),
              icon: const Icon(Icons.play_arrow),
              label: Text(l10n.wrappedPlay),
            ),
          ],
        );
      }),
    if (w.topTracks.length > 1)
      _Slide(const [Color(0xFF477D95), Color(0xFF1E3264)], (context) {
        return _Reveal(
          children: [
            Text(l10n.wrappedTopSongsTitle, style: _title),
            _gap(24),
            for (final (i, item) in w.topTracks.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(width: 32, child: Text('${i + 1}', style: _title.copyWith(fontSize: 22))),
                    SizedBox(width: 56, child: CoverImage(albumId: item.track.album.id, size: 200)),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.track.title, style: _text, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(item.track.artistCredit, style: _small, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Text('${format.format(item.plays)}×', style: _small),
                  ],
                ),
              ),
          ],
        );
      }),
    if (peak != null)
      _Slide(const [Color(0xFF2D46B9), Color(0xFF0B0B2B)], (context) {
        final top = months.reduce((a, b) => a > b ? a : b);
        return _Reveal(
          children: [
            Text(l10n.wrappedClockKicker, style: _text),
            _gap(8),
            Text(listeningTime(l10n, peak), style: _big.copyWith(fontSize: 48)),
            _gap(8),
            Text(l10n.wrappedPeakHour('${peak.toString().padLeft(2, '0')}:00'), style: _small),
            _gap(32),
            Text(l10n.wrappedBestMonth(monthName.format(DateTime(w.year, bestMonth + 1))), style: _text),
            _gap(),
            SizedBox(
              height: 120,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (var i = 0; i < 12; i++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0, end: top == 0 ? 0 : months[i] / top),
                              duration: Duration(milliseconds: 700 + 60 * i),
                              curve: Curves.easeOutCubic,
                              builder: (_, v, _) => Container(
                                height: 96 * v + 2,
                                decoration: BoxDecoration(
                                  color: i == bestMonth ? Colors.white : Colors.white38,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              monthName.format(DateTime(w.year, i + 1)).characters.first,
                              style: const TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      }),
    _Slide(const [Color(0xFFAF2896), Color(0xFF509BF5)], (context) {
      return _Reveal(
        children: [
          Text(l10n.wrappedVarietyKicker, style: _text),
          _gap(20),
          _CountUp(w.songs, style: _big.copyWith(fontSize: 52)),
          Text(l10n.wrappedDifferentSongs, style: _text),
          _gap(20),
          _CountUp(w.artists, style: _big.copyWith(fontSize: 52)),
          Text(l10n.wrappedDifferentArtists, style: _text),
          if (w.newArtists > 0) ...[_gap(8), Text(l10n.wrappedNewArtists(format.format(w.newArtists)), style: _small)],
          if (w.firstTrack != null) ...[
            _gap(28),
            Text(l10n.wrappedFirstSong, style: _small),
            _gap(8),
            Row(
              children: [
                SizedBox(width: 48, child: CoverImage(albumId: w.firstTrack!.album.id, size: 128)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${w.firstTrack!.title} · ${w.firstTrack!.artistCredit}',
                    style: _text.copyWith(fontSize: 16),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      );
    }),
    _Slide(const [Color(0xFF1DB954), Color(0xFF0B3D1F)], (context) => _Summary(wrapped: w, onReplay: onReplay)),
  ];
}

/// The last page: the year at a glance, with the top songs as a playlist.
class _Summary extends ConsumerStatefulWidget {
  const _Summary({required this.wrapped, required this.onReplay});
  final Wrapped wrapped;
  final VoidCallback onReplay;

  @override
  ConsumerState<_Summary> createState() => _SummaryState();
}

class _SummaryState extends ConsumerState<_Summary> {
  late String? _playlistId = widget.wrapped.playlistId;
  var _saving = false;

  Future<void> _save() async {
    final l10n = context.l10n;
    final year = widget.wrapped.year;
    setState(() => _saving = true);
    try {
      final id = await ref
          .read(apiProvider)
          .saveWrappedPlaylist(
            year,
            name: l10n.wrappedPlaylistName(year),
            description: l10n.wrappedPlaylistDescription(year),
          );
      ref.invalidate(playlistsProvider);
      if (mounted) setState(() => _playlistId = id);
      if (mounted) context.push('/playlist/$id');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.wrapped;
    final l10n = context.l10n;
    final format = NumberFormat.decimalPattern(l10n.localeName);
    Widget column(String title, List<String> items) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: _small),
          const SizedBox(height: 6),
          for (final (i, item) in items.indexed)
            Text('${i + 1}  $item', style: _text.copyWith(fontSize: 15), maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
    return _Reveal(
      children: [
        Text(l10n.wrappedSummaryTitle(w.year), style: _title),
        _gap(20),
        if (w.topArtists.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 140,
              width: double.infinity,
              child: ArtistImage(artist: w.topArtists.first.artist, size: 600),
            ),
          ),
        _gap(20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            column(l10n.wrappedTopArtistsTitle, [for (final a in w.topArtists) a.name]),
            const SizedBox(width: 16),
            column(l10n.wrappedTopSongsTitle, [for (final t in w.topTracks) t.track.title]),
          ],
        ),
        _gap(20),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.wrappedMinutesLabel, style: _small),
                  Text(format.format(w.minutes), style: _title),
                ],
              ),
            ),
            if (w.topGenres.isNotEmpty)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.wrappedTopGenreLabel, style: _small),
                    Text(w.topGenres.first.$1, style: _title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
          ],
        ),
        _gap(28),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: _saving
                  ? null
                  : _playlistId == null
                  ? _save
                  : () => context.push('/playlist/$_playlistId'),
              icon: Icon(_playlistId == null ? Icons.playlist_add : Icons.queue_music),
              label: Text(_playlistId == null ? l10n.wrappedSavePlaylist : l10n.wrappedOpenPlaylist),
            ),
            if (_playlistId != null)
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.wrappedUpdatePlaylist),
              ),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: widget.onReplay,
              icon: const Icon(Icons.replay),
              label: Text(l10n.wrappedReplay),
            ),
          ],
        ),
      ],
    );
  }
}

/// Home's banner for the review, in December and January.
class WrappedBanner extends StatelessWidget {
  const WrappedBanner({super.key, required this.year});
  final int year;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Material(
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF8D67AB), Color(0xFFE13300), Color(0xFFF59B23)]),
        ),
        child: InkWell(
          onTap: () => context.push('/wrapped?year=$year'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.wrappedBannerTitle(year),
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(context.l10n.wrappedBannerText, style: const TextStyle(color: Colors.white)),
                    ],
                  ),
                ),
                const Icon(Icons.play_circle_fill, color: Colors.white, size: 44),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
