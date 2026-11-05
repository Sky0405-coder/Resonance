"""Ordering a playlist like a DJ set: neighbours in compatible keys and tempos, energy following an arc."""

import math
from collections.abc import Callable
from dataclasses import dataclass

# Energy over the set (0 = start, 1 = end) for each arc; None keeps the energy steady from song to song.
ARCS: dict[str, Callable[[float], float] | None] = {
    # Warm up, build to the peak in the last third, a short cool-down at the end.
    "peak": lambda x: 0.35 + 0.55 * math.sin(min(1.0, x / 0.8) * math.pi / 2) - (0.25 * (x - 0.8) / 0.2 if x > 0.8 else 0),
    "rise": lambda x: 0.3 + 0.6 * x,
    "down": lambda x: 0.85 - 0.55 * x,
    "flow": None,
}


@dataclass
class SetTrack:
    id: object
    bpm: float | None
    key: str | None
    energy: float | None


def camelot_compatible(a: str, b: str) -> bool:
    """Same key, a fifth up or down (±1 on the wheel) or the relative major/minor."""
    try:
        na, nb = int(a[:-1]), int(b[:-1])
    except ValueError:
        return False
    if a[-1] == b[-1]:
        return (na - nb) % 12 in (0, 1, 11)
    return na == nb


def harmonic_score(a: SetTrack, b: SetTrack) -> float:
    """1 for a perfect neighbour; like the app's harmonic shuffle (key 70 %, tempo 30 %)."""
    key = 0.5 if a.key is None or b.key is None else (1.0 if camelot_compatible(a.key, b.key) else 0.0)
    tempo = 0.5
    if a.bpm and b.bpm and a.bpm > 0 and b.bpm > 0:
        ratio = a.bpm / b.bpm
        while ratio >= 1.5:
            ratio /= 2
        while ratio < 0.75:
            ratio *= 2
        tempo = 1 - min(1.0, abs(ratio - 1) / 0.16)
    return 0.7 * key + 0.3 * tempo


def order(tracks: list[SetTrack], arc: str) -> list[SetTrack]:
    """Greedy: each next song is the best neighbour of the previous one whose energy fits the arc at that point."""
    if len(tracks) < 3:
        return list(tracks)
    target = ARCS[arc]
    remaining = list(tracks)

    def energy(track: SetTrack) -> float:
        return 0.5 if track.energy is None else track.energy

    first_target = target(0) if target else min(energy(t) for t in remaining)
    previous = min(remaining, key=lambda t: abs(energy(t) - first_target))
    remaining.remove(previous)
    result = [previous]
    total = len(tracks) - 1
    while remaining:
        wanted = target(len(result) / total) if target else energy(previous)

        def fit(track: SetTrack, wanted: float = wanted, previous: SetTrack = previous) -> float:
            return 0.55 * harmonic_score(previous, track) + 0.45 * max(0.0, 1 - 2 * abs(energy(track) - wanted))

        previous = max(remaining, key=fit)
        remaining.remove(previous)
        result.append(previous)
    return result
