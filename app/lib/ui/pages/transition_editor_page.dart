import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, PointerScrollEvent, kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/desktop.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/engine.dart';
import '../../player/mix_lanes.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import '../../player/transitions.dart';
import '../widgets/band_waveform.dart';
import '../widgets/common.dart';

/// Colours of the editor, as in DJ software: low end orange, the rest blue, volume and bass curves on top.
const _volumeColor = Color(0xFF4FC3F7);
const _bassColor = Color(0xFFFFCA28);
const _filterColor = Color(0xFFF48FB1);
const _effectColor = Color(0xFFE0E0E0);
const _loopColor = Color(0xFFFF9800);

/// Shapes the transition from one song of a playlist to the next: preset, length in bars, where it starts in the
/// current song and where the next one comes in. Shown over both songs' spectra with the volume and bass curves.
class TransitionEditorPage extends ConsumerStatefulWidget {
  const TransitionEditorPage({
    super.key,
    required this.playlistId,
    required this.from,
    required this.to,
    required this.canEdit,
  });
  final String playlistId;
  final Track from;
  final Track to;
  final bool canEdit;

  @override
  ConsumerState<TransitionEditorPage> createState() => _TransitionEditorPageState();
}

class _TransitionEditorPageState extends ConsumerState<TransitionEditorPage> {
  MixPoints? _out;
  MixPoints? _in;
  Spectrum? _outSpectrum;
  Spectrum? _inSpectrum;
  bool _loading = true;
  CustomTransition? _saved;

  /// The edited transition; null while "automatic" is chosen.
  CustomTransition? _draft;
  bool _previewing = false;
  bool _saving = false;

  /// The visible stretch of the current song (seconds), kept still while a lane is dragged.
  (double, double)? _frozenWindow;
  // How far the waveforms are zoomed in around the transition (mouse wheel or the buttons).
  double _zoom = 1;
  double _dragSeconds = 0;

  /// The curves being drawn by hand (volume, bass or filter), null while the songs are dragged instead.
  _CurveGroup? _drawing;

  late final PlayerController _player = ref.read(playerProvider.notifier);
  String get _context => 'playlist:${widget.playlistId}';

  @override
  void initState() {
    super.initState();
    _player;
    _load();
  }

  @override
  void dispose() {
    _player.endPreview();
    super.dispose();
  }

  Future<void> _load() async {
    final api = ref.read(apiProvider);
    try {
      final results = await Future.wait<Object?>([
        api.mixPoints([widget.from.id, widget.to.id]),
        ref.read(playlistTransitionsProvider(widget.playlistId).future),
        ref.read(spectrumProvider(widget.from.id).future).catchError((Object _) => null),
        ref.read(spectrumProvider(widget.to.id).future).catchError((Object _) => null),
      ]);
      final points = results[0] as Map<String, MixPoints?>;
      final saved = (results[1] as Map<String, CustomTransition>)['${widget.from.id}>${widget.to.id}'];
      if (!mounted) return;
      setState(() {
        _out = points[widget.from.id];
        _in = points[widget.to.id];
        _outSpectrum = results[2] as Spectrum?;
        _inSpectrum = results[3] as Spectrum?;
        _saved = saved;
        _draft = saved;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showError(context, e);
    }
  }

  /// AutoMix's own transition, or a plain four-bar crossfade where AutoMix would not blend.
  AutomixPlan _autoPlan(MixPoints out, MixPoints inc) =>
      automixPlan(out, inc) ??
      customAutomixPlan(
        out,
        inc,
        CustomTransition(
          style: TransitionStyle.crossfade,
          bars: 4,
          start: math.max(0, out.end - 4 * 4 * _beat(out) - 1),
          incomingStart: inc.mixIn,
        ),
      );

  double _beat(MixPoints points) => 60 / (points.bpm != null && points.bpm! > 0 ? points.bpm! : 120);

  AutomixPlan _plan(MixPoints out, MixPoints inc) =>
      _draft == null ? _autoPlan(out, inc) : customAutomixPlan(out, inc, _draft!);

  /// The transition being edited, starting from the automatic one.
  CustomTransition _editable(MixPoints out, MixPoints inc) =>
      _draft ?? CustomTransition.fromPlan(_autoPlan(out, inc), out.bpm);

  void _update(CustomTransition? draft) {
    setState(() => _draft = draft);
    final out = _out, inc = _in;
    if (out != null && inc != null) {
      _player.updatePreview(widget.from, widget.to, draft ?? CustomTransition.fromPlan(_autoPlan(out, inc), out.bpm));
    }
  }

  double _snap(double seconds, double first, double beat) => first + ((seconds - first) / beat).round() * beat;

  Future<void> _togglePreview(MixPoints out, MixPoints inc) async {
    if (_previewing) {
      setState(() => _previewing = false);
      _player.endPreview();
      await _player.pause();
      return;
    }
    if (!_player.automix) {
      showInfo(context, context.l10n.transitionNeedsAutomix);
      return;
    }
    setState(() => _previewing = true);
    await _player.previewTransition(widget.from, widget.to, _editable(out, inc), context: _context);
  }

  Future<void> _save() async {
    final api = ref.read(apiProvider);
    setState(() => _saving = true);
    try {
      final draft = _draft;
      if (draft == null) {
        await api.resetTransition(widget.playlistId, widget.from.id, widget.to.id);
      } else {
        await api.saveTransition(widget.playlistId, widget.from.id, widget.to.id, draft);
      }
      ref.invalidate(playlistTransitionsProvider(widget.playlistId));
      _player.transitionsChanged();
      if (!mounted) return;
      showInfo(context, context.l10n.transitionSaved);
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final out = _out, inc = _in;
    final changed = _draft != _saved;
    return Scaffold(
      backgroundColor: Palette.background,
      appBar: AppBar(
        backgroundColor: Palette.background,
        leading: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(6)),
            child: const Text('Beta', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          if (widget.canEdit && _saved != null)
            PopupMenuButton<void>(
              itemBuilder: (_) => [
                PopupMenuItem(onTap: () => _update(null), child: Text(context.l10n.transitionReset)),
              ],
            ),
          if (widget.canEdit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton(
                onPressed: changed && !_saving && out != null && inc != null ? _save : null,
                child: Text(context.l10n.commonSave),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : out == null || inc == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(context.l10n.transitionNotAnalyzed, textAlign: TextAlign.center),
              ),
            )
          : _editor(context, out, inc),
    );
  }

  Widget _editor(BuildContext context, MixPoints out, MixPoints inc) {
    final plan = _plan(out, inc);
    final edit = _editable(out, inc);
    final lanes = edit.effectiveLanes;
    final l10n = context.l10n;
    final presets = transitionPresets(l10n);
    // Which chip is lit: automatic, a preset with exactly these lanes, or "custom".
    final preset = _draft == null ? null : presets.where((p) => p.$2 == lanes).firstOrNull;
    final custom = _draft != null && preset == null;

    void setLanes(MixLanes value) => _update(edit.copyWith(lanes: value));
    // Picking a lane's variant replaces what was drawn for it.
    MixLanes undrawn(_CurveGroup group) =>
        lanes.copyWith(curves: {...lanes.curves}..removeWhere((curve, _) => group.curves.contains(curve)));
    String laneValue(_CurveGroup group, String label) =>
        group.curves.any(lanes.curves.containsKey) ? l10n.transitionDrawn : label;

    Widget chip(String label, bool selected, VoidCallback? onSelected, {Widget? avatar}) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        avatar: avatar,
        label: Text(label),
        selected: selected,
        onSelected: !widget.canEdit || onSelected == null ? null : (_) => onSelected(),
      ),
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        _TrackHeader(track: widget.from, points: out),
        LayoutBuilder(
          builder: (context, constraints) => _waveforms(context, constraints.maxWidth, out, inc, plan, edit),
        ),
        _TrackHeader(track: widget.to, points: inc),
        if (widget.canEdit) ...[
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(l10n.transitionDraw, style: const TextStyle(color: Palette.textMuted)),
                const SizedBox(width: 12),
                for (final group in _CurveGroup.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      avatar: CircleAvatar(backgroundColor: group.color, radius: 5),
                      label: Text(switch (group) {
                        _CurveGroup.volume => l10n.transitionVolume,
                        _CurveGroup.bass => l10n.transitionBass,
                        _CurveGroup.filter => l10n.transitionFilterLane,
                      }),
                      selected: _drawing == group,
                      onSelected: (on) => setState(() => _drawing = on ? group : null),
                    ),
                  ),
                if (_drawing case final group? when group.curves.any(lanes.curves.containsKey))
                  TextButton.icon(
                    onPressed: () => setLanes(undrawn(group)),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: Text(l10n.transitionDrawReset),
                  ),
              ],
            ),
          ),
          if (_drawing != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(l10n.transitionDrawHint, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
            ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(child: Divider(indent: 16, endIndent: 12)),
            Text(l10n.transitionPresets, style: const TextStyle(color: Palette.textMuted)),
            const Expanded(child: Divider(indent: 12, endIndent: 16)),
          ],
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              chip(
                l10n.transitionAuto,
                _draft == null,
                () => _update(null),
                avatar: const Icon(Icons.auto_awesome, size: 18),
              ),
              if (custom) chip(l10n.transitionCustom, true, null),
              for (final (name, value) in presets) chip(name, preset?.$2 == value, () => setLanes(value)),
            ],
          ),
        ),
        _LaneRow(
          color: _volumeColor,
          label: l10n.transitionVolume,
          value: laneValue(_CurveGroup.volume, volumeLaneLabel(l10n, lanes.volume)),
          onTap: !widget.canEdit
              ? null
              : () => _pick(
                  l10n.transitionVolume,
                  _volumeColor,
                  [for (final v in VolumeLane.values) (volumeLaneLabel(l10n, v), v)],
                  lanes.volume,
                  (v) => setLanes(undrawn(_CurveGroup.volume).copyWith(volume: v)),
                ),
        ),
        _LaneRow(
          color: _bassColor,
          label: l10n.transitionEq,
          value: laneValue(_CurveGroup.bass, eqLaneLabel(l10n, lanes.eq)),
          onTap: !widget.canEdit
              ? null
              : () => _pick(
                  l10n.transitionEq,
                  _bassColor,
                  [for (final v in EqLane.values) (eqLaneLabel(l10n, v), v)],
                  lanes.eq,
                  (v) => setLanes(undrawn(_CurveGroup.bass).copyWith(eq: v)),
                ),
        ),
        _LaneRow(
          color: _filterColor,
          label: l10n.transitionFilterLane,
          value: laneValue(_CurveGroup.filter, filterLaneLabel(l10n, lanes.filter)),
          onTap: !widget.canEdit
              ? null
              : () => _pick(
                  l10n.transitionFilterLane,
                  _filterColor,
                  [for (final v in FilterLane.values) (filterLaneLabel(l10n, v), v)],
                  lanes.filter,
                  (v) => setLanes(undrawn(_CurveGroup.filter).copyWith(filter: v)),
                ),
        ),
        _LaneRow(
          color: _effectColor,
          label: l10n.transitionEffects,
          value: effectLaneLabel(l10n, lanes.effect),
          onTap: !widget.canEdit
              ? null
              : () => _pick(
                  l10n.transitionEffects,
                  _effectColor,
                  [
                    for (final v in EffectLane.values)
                      // Flanger, phaser, gate and beat roll exist only in the desktop players.
                      if (!v.desktopOnly || isDesktop || lanes.effect == v) (effectLaneLabel(l10n, v), v),
                  ],
                  lanes.effect,
                  (v) => setLanes(lanes.copyWith(effect: v)),
                ),
        ),
        _LaneRow(
          color: _loopColor,
          label: l10n.transitionLooping,
          value: loopLabel(l10n, lanes.loopBeats),
          onTap: !widget.canEdit
              ? null
              : () => _pick(
                  l10n.transitionLooping,
                  _loopColor,
                  [for (final v in MixLanes.loopChoices) (loopLabel(l10n, v), v)],
                  lanes.loopBeats,
                  (v) => setLanes(lanes.copyWith(loopBeats: v)),
                ),
        ),
        SwitchListTile(
          title: Text(l10n.transitionBeatmatching),
          subtitle: Text(l10n.transitionBeatmatchingHint, style: const TextStyle(color: Palette.textMuted)),
          value: lanes.beatmatch,
          onChanged: !widget.canEdit ? null : (v) => setLanes(lanes.copyWith(beatmatch: v)),
        ),
        if (kIsWeb && lanes.usesEffects)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(l10n.transitionFxUnavailable, style: const TextStyle(color: Palette.textMuted, fontSize: 13)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            widget.canEdit ? l10n.transitionDragHint : l10n.transitionViewOnly,
            style: const TextStyle(color: Palette.textMuted, fontSize: 13),
          ),
        ),
      ],
    );
  }

  /// A lane's choices in a sheet; the chosen one is ticked and changing it plays into the preview.
  Future<void> _pick<T>(String title, Color color, List<(String, T)> options, T current, void Function(T) onPick) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF282828),
        showDragHandle: true,
        builder: (sheet) {
          var selected = current;
          return StatefulBuilder(
            builder: (context, setSheet) => ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: Row(
                      children: [
                        Container(width: 4, height: 22, color: color),
                        const SizedBox(width: 12),
                        Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                  const Divider(height: 1, indent: 24, endIndent: 24),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final (label, value) in options)
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                            title: Text(label),
                            trailing: value == selected
                                ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
                                : null,
                            onTap: () {
                              setSheet(() => selected = value);
                              onPick(value);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );

  Widget _waveforms(
    BuildContext context,
    double width,
    MixPoints out,
    MixPoints inc,
    AutomixPlan plan,
    CustomTransition edit,
  ) {
    const height = 320.0;
    final start = plan.start.inMicroseconds / 1e6;
    final duration = plan.duration.inMicroseconds / 1e6;
    final bar = 4 * _beat(out);
    final center = start + duration / 2;
    final half = (duration / 2 + 2 * bar) / _zoom;
    final window = _frozenWindow ?? (center - half, center + half);
    final pixelsPerSecond = width / (window.$2 - window.$1);
    final position = ref.watch(positionProvider).value;
    final player = ref.watch(playerProvider);
    double? playhead;
    if (_previewing && position != null && player.queue.length == 2 && player.queue.first.id == widget.from.id) {
      final seconds = position.inMicroseconds / 1e6;
      playhead = player.index == 0 ? seconds : start + (seconds - plan.incomingStart.inMicroseconds / 1e6) / plan.ratio;
    }

    void dragStart(DragStartDetails _) {
      _frozenWindow = window;
      _dragSeconds = 0;
    }

    void dragEnd(DragEndDetails _) => setState(() => _frozenWindow = null);

    Widget lane({required bool outgoing}) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: widget.canEdit ? dragStart : null,
      onHorizontalDragEnd: widget.canEdit ? dragEnd : null,
      onHorizontalDragUpdate: !widget.canEdit
          ? null
          : (details) {
              // The song moves with the finger: the transition then happens earlier in it.
              _dragSeconds += details.delta.dx / pixelsPerSecond;
              if (outgoing) {
                final moved = _snap(edit.start - _dragSeconds, out.mixIn, _beat(out));
                final limited = moved.clamp(out.end / 3, math.max(out.end / 3, out.end - bar)).toDouble();
                if (limited != edit.start) {
                  _dragSeconds = 0;
                  _update(edit.copyWith(start: limited));
                }
              } else {
                final moved = _snap(edit.incomingStart - _dragSeconds * plan.ratio, inc.mixIn, _beat(inc));
                final limited = moved.clamp(0.0, math.max(0.0, inc.end / 2)).toDouble();
                if (limited != edit.incomingStart) {
                  _dragSeconds = 0;
                  _update(edit.copyWith(incomingStart: limited));
                }
              }
            },
      child: const SizedBox(height: height / 2, width: double.infinity),
    );

    void zoom(double factor) => setState(() => _zoom = (_zoom * factor).clamp(1.0, 8.0));

    return SizedBox(
      height: height,
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) zoom(event.scrollDelta.dy < 0 ? 1.25 : 0.8);
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _TransitionPainter(
                  plan: plan,
                  window: window,
                  outgoing: _outSpectrum,
                  incoming: _inSpectrum,
                  outBeat: _beat(out),
                  outFirstBeat: out.downbeat ?? out.mixIn,
                  outPhrases: out.phrases ?? const [],
                  inPhrases: inc.phrases ?? const [],
                  playhead: playhead,
                ),
              ),
            ),
            Column(children: [lane(outgoing: true), lane(outgoing: false)]),
            if (_drawing case final group? when widget.canEdit)
              Positioned(
                left: (start - window.$1) * pixelsPerSecond,
                width: duration * pixelsPerSecond,
                top: 0,
                height: height,
                child: _CurveEditor(
                  group: group,
                  lanes: edit.effectiveLanes,
                  bars: edit.bars,
                  onChanged: (lanes) => _update(edit.copyWith(lanes: lanes)),
                ),
              ),
            Center(
              child: IconButton.filled(
                tooltip: _previewing ? context.l10n.transitionStopPreview : context.l10n.transitionPreview,
                style: IconButton.styleFrom(backgroundColor: Colors.white24, foregroundColor: Colors.white),
                icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                onPressed: () => _togglePreview(out, inc),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: PopupMenuButton<int>(
                enabled: widget.canEdit,
                initialValue: edit.bars,
                onSelected: (bars) => _update(edit.copyWith(bars: bars)),
                itemBuilder: (_) => [
                  for (final bars in CustomTransition.barChoices)
                    PopupMenuItem(value: bars, child: Text(context.l10n.transitionBars(bars))),
                ],
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(color: Colors.white12, borderRadius: BorderRadius.circular(16)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text(context.l10n.transitionBars(edit.bars)), const Icon(Icons.expand_more, size: 18)],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: Row(
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: context.l10n.transitionZoomOut,
                    onPressed: _zoom > 1 ? () => zoom(0.8) : null,
                    icon: const Icon(Icons.zoom_out, size: 20),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: context.l10n.transitionZoomIn,
                    onPressed: _zoom < 8 ? () => zoom(1.25) : null,
                    icon: const Icon(Icons.zoom_in, size: 20),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.track, required this.points});
  final Track track;
  final MixPoints points;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    child: Row(
      children: [
        SizedBox(width: 52, child: CoverImage(albumId: track.album.id, size: 64)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
              Text(
                track.artistCredit,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textMuted),
              ),
            ],
          ),
        ),
        MixInfo(bpm: points.bpm, musicalKey: points.reliableKey),
        const SizedBox(width: 12),
        Text(formatDuration(track.length), style: const TextStyle(color: Palette.textMuted)),
      ],
    ),
  );
}

/// What can be drawn by hand: a song's volume, its bass or its filter, for both songs at once.
enum _CurveGroup {
  volume(_volumeColor, MixCurve.volumeOut, MixCurve.volumeIn),
  bass(_bassColor, MixCurve.bassOut, MixCurve.bassIn),
  filter(_filterColor, MixCurve.filterOut, MixCurve.filterIn);

  const _CurveGroup(this.color, this.outgoing, this.incoming);
  final Color color;
  final MixCurve outgoing;
  final MixCurve incoming;

  List<MixCurve> get curves => [outgoing, incoming];
}

/// Drawing a curve over the transition like an EQ's: the current song's in the upper half, the next one's in the
/// lower. A click adds a point (on a sixteenth note), dragging moves one, a right click or long press removes it.
/// The ends stay at the start and end of the transition and only move up and down.
class _CurveEditor extends StatefulWidget {
  const _CurveEditor({required this.group, required this.lanes, required this.bars, required this.onChanged});
  final _CurveGroup group;
  final MixLanes lanes;
  final int bars;
  final ValueChanged<MixLanes> onChanged;

  @override
  State<_CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<_CurveEditor> {
  (MixCurve, int)? _dragged;
  Offset? _down;
  bool _removed = false;

  // The curves as changed during this gesture (the page shows them a frame later).
  final _changed = <MixCurve, List<CurvePoint>>{};

  void _release() {
    _down = null;
    _dragged = null;
    _changed.clear();
  }

  List<CurvePoint> _points(MixCurve curve) =>
      _changed[curve] ?? widget.lanes.curves[curve] ?? curve.sample(widget.lanes, widget.bars);

  /// Height on screen of a curve's value: as the painter draws it (the filter's open position in the middle).
  static double _shown(MixCurve curve, double value) =>
      curve == MixCurve.filterOut || curve == MixCurve.filterIn ? 0.5 + 0.5 * value : value;
  static double _stored(MixCurve curve, double shown) =>
      curve == MixCurve.filterOut || curve == MixCurve.filterIn ? shown * 2 - 1 : shown;

  MixCurve _curveAt(double y, Size size) => y < size.height / 2 ? widget.group.outgoing : widget.group.incoming;

  Offset _offset(MixCurve curve, CurvePoint point, Size size) {
    final lane = size.height / 2;
    final top = curve.outgoing ? 0.0 : lane;
    return Offset(point.$1 * size.width, top + 10 + (1 - _shown(curve, point.$2)) * (lane - 20));
  }

  CurvePoint _point(MixCurve curve, Offset position, Size size) {
    final lane = size.height / 2;
    final top = curve.outgoing ? 0.0 : lane;
    final steps = widget.bars * 16;
    final u = ((position.dx / size.width).clamp(0.0, 1.0) * steps).round() / steps;
    var shown = (1 - (position.dy - top - 10) / (lane - 20)).clamp(0.0, 1.0);
    // Easy to hit the ends and the middle (an open filter).
    for (final snap in const [0.0, 0.5, 1.0]) {
      if ((shown - snap).abs() < 0.03) shown = snap;
    }
    return (u, _stored(curve, shown).clamp(curve.min, curve.max));
  }

  int? _nearest(MixCurve curve, Offset position, Size size) {
    final points = _points(curve);
    int? best;
    var distance = 18.0;
    for (var i = 0; i < points.length; i++) {
      final d = (_offset(curve, points[i], size) - position).distance;
      if (d < distance) (best, distance) = (i, d);
    }
    return best;
  }

  void _write(MixCurve curve, List<CurvePoint> points) {
    _changed[curve] = points;
    widget.onChanged(widget.lanes.copyWith(curves: {...widget.lanes.curves, ..._changed}));
  }

  /// Adds a point under [position] (between its neighbours) and returns its index.
  int _add(MixCurve curve, Offset position, Size size) {
    final points = [..._points(curve)];
    final point = _point(curve, position, size);
    var index = points.indexWhere((p) => p.$1 > point.$1);
    if (index <= 0) index = points.length - 1;
    // Never on top of another point's place.
    if (points.any((p) => p.$1 == point.$1)) {
      final same = points.indexWhere((p) => p.$1 == point.$1);
      if (same == 0 || same == points.length - 1) return same;
      points[same] = point;
      _write(curve, points);
      return same;
    }
    points.insert(index, point);
    _write(curve, points);
    return index;
  }

  void _move(MixCurve curve, int index, Offset position, Size size) {
    final points = [..._points(curve)];
    var point = _point(curve, position, size);
    if (index == 0 || index == points.length - 1) {
      point = (points[index].$1, point.$2);
    } else {
      // Stays between its neighbours.
      final step = 1 / (widget.bars * 16);
      point = (point.$1.clamp(points[index - 1].$1 + step, points[index + 1].$1 - step).toDouble(), point.$2);
      if (points[index + 1].$1 - points[index - 1].$1 < 2 * step) point = (points[index].$1, point.$2);
    }
    points[index] = point;
    _write(curve, points);
  }

  void _remove(Offset position, Size size) {
    final curve = _curveAt(position.dy, size);
    final index = _nearest(curve, position, size);
    final points = [..._points(curve)];
    if (index == null || index == 0 || index == points.length - 1) return;
    points.removeAt(index);
    _write(curve, points);
    _changed.clear();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      // Raw pointer events, so dragging a point wins over scrolling the page and moving the songs (which the
      // empty drag handlers below keep from starting).
      return Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (e.kind == PointerDeviceKind.mouse && e.buttons != kPrimaryMouseButton) return;
          _down = e.localPosition;
          _removed = false;
          final curve = _curveAt(e.localPosition.dy, size);
          final index = _nearest(curve, e.localPosition, size);
          _dragged = index == null ? null : (curve, index);
          setState(() {});
        },
        onPointerMove: (e) {
          final down = _down;
          if (down == null || _removed) return;
          if (_dragged == null && (e.localPosition - down).distance > 4) {
            final curve = _curveAt(down.dy, size);
            _dragged = (curve, _add(curve, down, size));
          }
          if (_dragged case (final curve, final index)) _move(curve, index, e.localPosition, size);
        },
        onPointerUp: (e) {
          final down = _down;
          if (down != null && _dragged == null && !_removed) {
            final curve = _curveAt(down.dy, size);
            if (_nearest(curve, down, size) == null) _add(curve, down, size);
          }
          setState(_release);
        },
        onPointerCancel: (_) => setState(_release),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) {},
          onHorizontalDragStart: (_) {},
          onSecondaryTapUp: (d) => _remove(d.localPosition, size),
          onLongPressStart: (d) {
            if (_dragged != null && _down != null) {
              // Held still on a point: remove it instead of moving it.
              _removed = true;
              _remove(d.localPosition, size);
            }
          },
          child: CustomPaint(
            size: size,
            painter: _HandlePainter(
              color: widget.group.color,
              handles: [
                for (final curve in widget.group.curves)
                  for (final (i, point) in _points(curve).indexed)
                    (_offset(curve, point, size), _dragged == (curve, i)),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// The points of the curve being drawn, as handles.
class _HandlePainter extends CustomPainter {
  _HandlePainter({required this.color, required this.handles});
  final Color color;
  final List<(Offset, bool)> handles;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color.withValues(alpha: 0.05));
    for (final (offset, active) in handles) {
      canvas.drawCircle(offset, active ? 8 : 6, Paint()..color = color);
      canvas.drawCircle(
        offset,
        active ? 8 : 6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.black54,
      );
    }
  }

  @override
  bool shouldRepaint(_HandlePainter old) => true;
}

class _LaneRow extends StatelessWidget {
  const _LaneRow({required this.color, required this.label, required this.value, this.onTap});
  final Color color;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Container(width: 3, height: 20, color: color),
          const SizedBox(width: 10),
          SizedBox(width: 110, child: Text(label, style: const TextStyle(fontSize: 15))),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Palette.textMuted),
            ),
          ),
          if (onTap != null) const Icon(Icons.expand_more, color: Palette.textMuted, size: 20),
        ],
      ),
    ),
  );
}

/// Both songs' spectra (current song on top, next one below, lined up in the current song's time), the beat grid,
/// the transition's box and its volume (blue) and bass (yellow) curves.
class _TransitionPainter extends CustomPainter {
  _TransitionPainter({
    required this.plan,
    required this.window,
    required this.outgoing,
    required this.incoming,
    required this.outBeat,
    required this.outFirstBeat,
    required this.playhead,
    this.outPhrases = const [],
    this.inPhrases = const [],
  });
  final AutomixPlan plan;
  final (double, double) window;
  final Spectrum? outgoing;
  final Spectrum? incoming;
  final double outBeat;
  final double outFirstBeat;
  final double? playhead;

  /// Section starts (song times) of both songs, marked on their lanes.
  final List<double> outPhrases;
  final List<double> inPhrases;

  double get _start => plan.start.inMicroseconds / 1e6;
  double get _duration => plan.duration.inMicroseconds / 1e6;

  @override
  void paint(Canvas canvas, Size size) {
    final pixelsPerSecond = size.width / (window.$2 - window.$1);
    double x(double seconds) => (seconds - window.$1) * pixelsPerSecond;
    final lane = size.height / 2;
    final boxLeft = x(_start), boxRight = x(_start + _duration);

    canvas.drawRRect(
      RRect.fromLTRBR(boxLeft, 0, boxRight, size.height, const Radius.circular(12)),
      Paint()..color = Colors.white.withValues(alpha: 0.07),
    );
    // Beat grid, bars brighter.
    final grid = Paint()..strokeWidth = 1;
    final firstBeat = ((window.$1 - outFirstBeat) / outBeat).ceil();
    for (var b = firstBeat; outFirstBeat + b * outBeat <= window.$2; b++) {
      grid.color = Colors.white.withValues(alpha: b % 4 == 0 ? 0.12 : 0.04);
      final px = x(outFirstBeat + b * outBeat);
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), grid);
    }

    // Three-band waveforms as in DJ software; outside the transition each song is dimmed.
    void wave(Spectrum? spectrum, double top, double Function(double outSeconds) songTime, bool Function(double) live) {
      if (spectrum == null) return;
      paintBandWaveform(
        canvas,
        Rect.fromLTWH(0, top + lane * 0.08, size.width, lane * 0.84),
        spectrum,
        songTime: (px) => songTime(window.$1 + px / pixelsPerSecond),
        opacity: (px) => live(window.$1 + px / pixelsPerSecond) ? 1 : 0.3,
      );
    }

    // Section starts: a bright line with a small flag on the song's lane.
    void phrases(List<double> times, double top, double Function(double songTime) editorTime) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.5;
      for (final time in times) {
        final px = x(editorTime(time));
        if (px < 0 || px > size.width) continue;
        canvas.drawLine(Offset(px, top), Offset(px, top + lane), paint);
        canvas.drawPath(
          Path()
            ..moveTo(px, top)
            ..lineTo(px + 7, top + 4)
            ..lineTo(px, top + 8)
            ..close(),
          paint,
        );
      }
    }

    final end = _start + _duration;
    final incomingStart = plan.incomingStart.inMicroseconds / 1e6;
    wave(outgoing, 0, (s) => s, (s) => s <= end);
    wave(incoming, lane, (s) => incomingStart + (s - _start) * plan.ratio, (s) => s >= _start);
    phrases(outPhrases, 0, (t) => t);
    phrases(inPhrases, lane, (t) => _start + (t - incomingStart) / plan.ratio);

    // The loop: the beats the current song repeats, from the middle on.
    final lanes = plan.lanes;
    final loopBeats = lanes == null ? 0 : fittingLoopBeats(lanes, plan.bars);
    if (loopBeats > 0) {
      final middle = _start + _duration / 2;
      final loopPaint = Paint()..color = _loopColor.withValues(alpha: 0.22);
      canvas.drawRect(Rect.fromLTRB(x(middle - loopBeats * outBeat), 0, x(middle), lane), loopPaint);
      canvas.drawRect(
        Rect.fromLTRB(x(middle), lane - 6, boxRight, lane),
        Paint()..color = _loopColor.withValues(alpha: 0.8),
      );
    }

    // Curves inside the box: volume, bass (or the EQ bands) and filters, from the lanes or AutoMix's plan.
    final swap = plan.bassSwap.inMicroseconds / 1e6;
    final paths = {
      for (final key in ['outVolume', 'inVolume', 'outBass', 'inBass', 'outMid', 'inMid', 'outFilter', 'inFilter'])
        key: Path(),
    };
    final showMids = lanes?.eq == EqLane.threeBand;
    final showFilter =
        lanes != null &&
        (lanes.filter != FilterLane.none ||
            lanes.curves.containsKey(MixCurve.filterOut) ||
            lanes.curves.containsKey(MixCurve.filterIn));
    double filterValue(FxState state) {
      // Neutral in the middle of the lane; a high-pass rises, a low-pass sinks, noise rises.
      final hp = math.log(state.highpass / mixHighpassOff) / math.log(2400 / mixHighpassOff);
      final lp = math.log(mixLowpassOff / state.lowpass) / math.log(mixLowpassOff / 250);
      return (0.5 + 0.5 * hp - 0.5 * lp + 0.5 * state.noise).clamp(0.0, 1.0);
    }

    const steps = 120;
    for (var i = 0; i <= steps; i++) {
      final t = _duration * i / steps;
      double vo, vi, bassOut, bassIn, midOut = 1, midIn = 1, filterOut = 0.5, filterIn = 0.5;
      if (lanes != null) {
        final (o, n) = laneStates(lanes, i / steps, plan.bars);
        (vo, vi) = (o.dry, n.dry);
        (bassOut, bassIn) = (1 - o.low / mixCutDb, 1 - n.low / mixCutDb);
        (midOut, midIn) = (1 - o.mid / mixCutDb, 1 - n.mid / mixCutDb);
        (filterOut, filterIn) = (filterValue(o), filterValue(n));
      } else {
        (vo, vi) = planVolumes(
          plan,
          elapsed: Duration(microseconds: (t * 1e6).round()),
          outgoingTarget: 1,
          incomingTarget: 1,
        );
        bassOut = plan.filterOut ? (1 - t / (_duration * 0.8)).clamp(0.0, 1.0) : (t < swap ? 1.0 : 0.0);
        bassIn = plan.filterOut ? 1.0 : (t < swap ? 0.0 : 1.0);
      }
      final px = x(_start + t);
      double y(double top, double value) => top + 10 + (1 - value) * (lane - 20);
      void point(String key, double top, double value) =>
          i == 0 ? paths[key]!.moveTo(px, y(top, value)) : paths[key]!.lineTo(px, y(top, value));
      point('outVolume', 0, vo);
      point('inVolume', lane, vi);
      point('outBass', 0, bassOut);
      point('inBass', lane, bassIn);
      point('outMid', 0, midOut);
      point('inMid', lane, midIn);
      point('outFilter', 0, filterOut);
      point('inFilter', lane, filterIn);
    }
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    if (lanes == null ||
        lanes.eq != EqLane.none ||
        lanes.curves.containsKey(MixCurve.bassOut) ||
        lanes.curves.containsKey(MixCurve.bassIn)) {
      canvas.drawPath(paths['outBass']!, stroke..color = _bassColor);
      canvas.drawPath(paths['inBass']!, stroke..color = _bassColor);
    }
    if (showMids) {
      canvas.drawPath(paths['outMid']!, stroke..color = _bassColor.withValues(alpha: 0.5));
      canvas.drawPath(paths['inMid']!, stroke..color = _bassColor.withValues(alpha: 0.5));
    }
    if (showFilter) {
      canvas.drawPath(paths['outFilter']!, stroke..color = _filterColor);
      canvas.drawPath(paths['inFilter']!, stroke..color = _filterColor);
    }
    canvas.drawPath(paths['outVolume']!, stroke..color = _volumeColor);
    canvas.drawPath(paths['inVolume']!, stroke..color = _volumeColor);

    if (playhead != null) {
      final px = x(playhead!);
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = Colors.greenAccent
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_TransitionPainter old) =>
      old.plan != plan ||
      old.window != window ||
      old.outgoing != outgoing ||
      old.incoming != incoming ||
      old.playhead != playhead ||
      old.outPhrases != outPhrases ||
      old.inPhrases != inPhrases;
}
