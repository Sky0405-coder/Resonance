"""The transition editor's lanes as the app plays them (a port of the app's `player/mix_lanes.dart`), evaluated for
many moments at once, for rendering a mix on the server.

Times are fractions of the transition (`u`, 0 to 1); the middle (0.5) is on a beat, as every transition lasts whole
bars. Each side's state matches the app's `FxState`: its volume curve (`level`), the volume after the effect's gate
(`dry`), EQ gains (dB), filter frequencies (Hz), how much feeds the effects and the effects' levels."""

import math

import numpy as np

CUT_DB = -15.0
HIGHPASS_OFF = 10.0
LOWPASS_OFF = 20000.0

_ECHO = {  # effect: (echo delay in beats, feedback)
    "echo_half_cut": (0.5, 0.5),
    "echo_half_tail": (0.5, 0.5),
    "echo_3q_cut": (0.75, 0.5),
    "echo_3q_tail": (0.75, 0.5),
    "echo_beat_cut": (1.0, 0.5),
    "echo_beat_tail": (1.0, 0.5),
    "delay_half_cut": (0.5, 0.0),
    "delay_3q_cut": (0.75, 0.0),
}
_REVERB = {"reverb_middle", "reverb_cut", "reverb_tail"}
_TAIL = {"reverb_tail", "echo_half_tail", "echo_3q_tail", "echo_beat_tail"}
DESKTOP_ONLY = {"flanger", "phaser", "gate", "beat_roll", "brake"}
FIELDS = (
    "level", "dry", "low", "mid", "high", "highpass", "lowpass", "fx_in", "echo", "reverb", "noise", "flanger",
    "phaser", "gate",
)

# What older transitions (a style without lanes) sound like, as the app plays them.
STYLE_LANES = {
    "crossfade": {},
    "fade_in": {"volume": "fade_in_hard_out"},
    "fade_out": {"volume": "fade_in_out", "eq": "bass_fade_out"},
    "filter": {"volume": "crossfade", "filter": "highpass_out"},
}


def echo_of(effect: str) -> tuple[float, float]:
    """(delay in beats, feedback) of an echo effect; (0, 0) for the others."""
    return _ECHO.get(effect, (0.0, 0.0))


def _ramp(u: np.ndarray, start: float, end: float) -> np.ndarray:
    if end <= start:
        return np.where(u < start, 0.0, 1.0)
    return np.clip((u - start) / (end - start), 0.0, 1.0)


def _smooth(t: np.ndarray) -> np.ndarray:
    return t * t * (3 - 2 * t)


def _sweep(a: float, b: float, t: np.ndarray) -> np.ndarray:
    return a * (b / a) ** np.clip(t, 0.0, 1.0)


def curve_at(points: list, u: np.ndarray) -> np.ndarray:
    """A drawn curve's values: straight lines between its points, flat beyond them."""
    xs = np.array([p[0] for p in points], dtype=np.float64)
    ys = np.array([p[1] for p in points], dtype=np.float64)
    return np.interp(u, xs, ys)


def filter_frequencies(knob: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """(high-pass, low-pass) of a DJ filter knob: -1 low-pass closed (250 Hz), 0 open, 1 high-pass closed (2.4 kHz)."""
    highpass = np.where(knob > 0, _sweep(HIGHPASS_OFF, 2400, np.maximum(knob, 0)), HIGHPASS_OFF)
    lowpass = np.where(knob < 0, _sweep(LOWPASS_OFF, 250, np.maximum(-knob, 0)), LOWPASS_OFF)
    return highpass, lowpass


def volumes(lane: str, u: np.ndarray, bar: float) -> tuple[np.ndarray, np.ndarray]:
    m = 0.5
    fade_in = _ramp(u, 0, m)
    fade_out = 1 - _ramp(u, m, 1)
    last_bar = np.where(u < 1 - bar, 1.0, 0.0)
    one, zero = np.ones_like(u), np.zeros_like(u)
    match lane:
        case "overlap":
            out, inc = one, one
        case "fade_in_out":
            out, inc = fade_out, fade_in
        case "hard_in_fade_out":
            out, inc = fade_out, one
        case "fade_in_hard_out":
            out, inc = one, fade_in
        case "center_cut":
            out, inc = np.where(u < m, 1.0, 0.0), np.where(u < m, 0.0, 1.0)
        case "crossfade":
            out, inc = 1 - u, u.copy()
        case "fade_in_quick_out":
            out, inc = 1 - _ramp(u, 0.75, 1), fade_in
        case "fade_in_cut_bar":
            out, inc = last_bar, fade_in
        case "overlap_cut_bar":
            out, inc = last_bar, one
        case _:
            out, inc = np.cos(_smooth(u) * math.pi / 2), np.sin(_smooth(u) * math.pi / 2)
    done = u >= 1
    return np.where(done, 0.0, out) + zero, np.where(done, 1.0, inc) + zero


def states(lanes: dict, u: np.ndarray, bars: int) -> tuple[dict, dict]:
    """Both players' states (arrays over `u`) in a transition with these lanes lasting `bars` bars."""
    u = np.asarray(u, dtype=np.float64)
    bar = 1 / max(1, bars)
    beat = bar / 4
    m = 0.5
    curves = lanes.get("curves") or {}

    def drawn(name: str) -> np.ndarray | None:
        return curve_at(curves[name], u) if name in curves and len(curves[name]) >= 2 else None

    vo, vi = volumes(lanes.get("volume", "smooth"), u, bar)
    live = u < 1
    if (curve := drawn("volume_out")) is not None:
        vo = np.where(live, curve, vo)
    if (curve := drawn("volume_in")) is not None:
        vi = np.where(live, curve, vi)

    zero = np.zeros_like(u)
    low_out, low_in, mid_out, mid_in, high_out, high_in = (zero.copy() for _ in range(6))

    def swap_at(point: float) -> np.ndarray:
        return _ramp(u, point - beat / 2, point + beat / 2)

    def cut_at(point: float) -> np.ndarray:
        return _ramp(u, point, point + beat / 8)

    match lanes.get("eq", "swap_middle"):
        case "swap_middle":
            low_out = swap_at(m)
            low_in = 1 - low_out
        case "swap_end":
            low_out = swap_at(1 - beat)
            low_in = 1 - low_out
        case "swap_start":
            low_out = swap_at(beat)
            low_in = 1 - low_out
        case "three_band":
            low_out = _smooth(_ramp(u, 0, 0.5))
            mid_out = _smooth(_ramp(u, 0.25, 0.75))
            high_out = _smooth(_ramp(u, 0.5, 1))
            low_in, mid_in, high_in = 1 - low_out, 1 - mid_out, 1 - high_out
        case "quick_bass_cut":
            low_out = cut_at(0.75)
            low_in = 1 - cut_at(1 - beat)
        case "long_bass_cut":
            low_out = cut_at(0)
            low_in = 1 - cut_at(1 - beat)
        case "bass_fade_out":
            low_out = _smooth(_ramp(u, 0, m))
    if (curve := drawn("bass_out")) is not None:
        low_out = 1 - curve
    if (curve := drawn("bass_in")) is not None:
        low_in = 1 - curve

    opening, closing = _ramp(u, 0, m), _ramp(u, m, 1)
    off_hp, off_lp = np.full_like(u, HIGHPASS_OFF), np.full_like(u, LOWPASS_OFF)
    hp_out, hp_in, lp_out, lp_in, noise = off_hp, off_hp.copy(), off_lp, off_lp.copy(), zero.copy()

    def hp_closing(to: float = 2400) -> np.ndarray:
        return _sweep(HIGHPASS_OFF, to, closing)

    def hp_opening() -> np.ndarray:
        return _sweep(2400, HIGHPASS_OFF, opening)

    def lp_closing() -> np.ndarray:
        return _sweep(LOWPASS_OFF, 250, closing)

    def lp_opening() -> np.ndarray:
        return _sweep(250, LOWPASS_OFF, opening)

    match lanes.get("filter", "none"):
        case "lowpass_out":
            lp_out = lp_closing()
        case "lowpass_in":
            lp_in = lp_opening()
        case "lowpass_in_out":
            lp_in, lp_out = lp_opening(), lp_closing()
        case "lowpass_in_highpass_out":
            lp_in, hp_out = lp_opening(), hp_closing()
        case "highpass_out":
            hp_out = hp_closing()
        case "highpass_in":
            hp_in = hp_opening()
        case "highpass_in_out":
            hp_in, hp_out = hp_opening(), hp_closing()
        case "highpass_in_lowpass_out":
            hp_in, lp_out = hp_opening(), lp_closing()
        case "highpass_half":
            hp_out = hp_closing(500)
        case "noise_end":
            noise = np.where(u >= 1, 0.0, _smooth(closing) ** 2)
    if (curve := drawn("filter_out")) is not None:
        hp_out, lp_out = filter_frequencies(curve)
    if (curve := drawn("filter_in")) is not None:
        hp_in, lp_in = filter_frequencies(curve)

    effect = lanes.get("effect", "none")
    feed, dry_gate = zero.copy(), np.ones_like(u)
    echo, reverb, flanger, phaser, gate = (zero.copy() for _ in range(5))
    if effect == "reverb_middle":
        feed = np.where(u < m, 1.0, 0.0)
        dry_gate = feed.copy()
        reverb = _smooth(_ramp(u, 0, m))
    elif effect in DESKTOP_ONLY:
        sweep = _smooth(_ramp(u, 0.25, m))
        if effect == "flanger":
            flanger = sweep
        if effect == "phaser":
            phaser = sweep
        if effect == "gate":
            gate = np.where((u >= m) & (u < 1), 1.0, 0.0)
        if effect == "brake":
            dry_gate = np.where(u >= m + 2 * beat, 0.0, 1.0)
    elif effect != "none":
        stop = 1 - bar if effect in _TAIL else 1.0
        feed = np.where((u >= m) & (u < stop), 1.0, 0.0)
        dry_gate = np.where(u < stop, 1.0, 0.0)
        if effect in _REVERB:
            reverb = _smooth(_ramp(u, m, min(1, m + 2 * bar)))
        if effect in _ECHO:
            echo = np.full_like(u, 0.6)

    out = {
        "level": vo, "dry": vo * dry_gate, "low": low_out * CUT_DB, "mid": mid_out * CUT_DB, "high": high_out * CUT_DB,
        "highpass": hp_out, "lowpass": lp_out, "fx_in": vo * feed, "echo": echo, "reverb": reverb, "noise": noise,
        "flanger": flanger, "phaser": phaser, "gate": gate,
    }
    inc = {
        "level": vi, "dry": vi, "low": low_in * CUT_DB, "mid": mid_in * CUT_DB, "high": high_in * CUT_DB,
        "highpass": hp_in, "lowpass": lp_in, "fx_in": zero, "echo": zero, "reverb": zero, "noise": zero,
        "flanger": zero, "phaser": zero, "gate": zero,
    }
    return out, inc


def brake_speed(u: np.ndarray, bars: int) -> np.ndarray:
    """The outgoing song's speed under the brake: from the middle it slows to a stop over two beats (1 elsewhere)."""
    beat = 1 / (max(1, bars) * 4)
    p = np.clip((u - 0.5) / (2 * beat), 0, 1)
    braking = (u >= 0.5) & (u < 0.5 + 2 * beat)
    return np.where(braking, np.maximum(0.05, (1 - p) ** 2), np.where(u >= 0.5 + 2 * beat, 0.05, 1.0))


def fitting_loop_beats(lanes: dict, bars: int) -> int:
    beats = int(lanes.get("loop", 0) or 0)
    while beats > 0 and beats > bars * 2:
        beats //= 2
    return beats
