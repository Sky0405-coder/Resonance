"""Finds where a song's voice starts and ends (run with the Python of the Demucs environment, not the server's).

Reads one JSON request per line on stdin – {"path": "...", "duration": 215.3} – and answers each with one JSON line on
stdout: {"vocals_in": 12.5, "vocals_out": 201.0} or {"error": "..."}. The first line is {"ready": true} once the model
is loaded. Only the intro and the outro are separated (the parts AutoMix blends); a part without a voice reports the
edge of its window, a song without any voice its length and zero.
"""

import json
import os
import subprocess
import sys

import numpy as np
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model

# Seconds separated at the start and at the end; shorter songs are separated as a whole.
WINDOW = 75.0
_FRAME = 0.25
# The voice counts from this level relative to the loudest accompaniment of the window, for at least a second.
_THRESHOLD_DB = -35.0
_MIN_SECONDS = 1.0


def _decode(path: str, start: float, length: float, rate: int) -> np.ndarray:
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-ss", f"{start:.3f}", "-t", f"{length:.3f}", "-i", path,
         "-ac", "2", "-ar", str(rate), "-f", "f32le", "-"],
        capture_output=True, check=True, timeout=300,
    ).stdout
    return np.frombuffer(out, dtype=np.float32).reshape(-1, 2).T.copy()


def _voiced(model, path: str, start: float, length: float) -> np.ndarray:
    """Per frame of the window: whether the voice is there."""
    rate = model.samplerate
    wav = torch.from_numpy(_decode(path, start, length, rate))
    if wav.shape[1] < rate:
        return np.zeros(0, dtype=bool)
    ref = wav.mean(0)
    wav = (wav - ref.mean()) / (ref.std() + 1e-8)
    with torch.no_grad():
        sources = apply_model(model, wav[None], shifts=0, split=True, overlap=0.1, progress=False, device="cpu")[0]
    index = model.sources.index("vocals")
    voice = sources[index].mean(0).numpy()
    rest = (sources.sum(0) - sources[index]).mean(0).numpy()
    hop = int(rate * _FRAME)
    count = len(voice) // hop
    if count == 0:
        return np.zeros(0, dtype=bool)
    voice_rms = np.sqrt((voice[: count * hop].reshape(count, hop) ** 2).mean(1))
    rest_rms = np.sqrt((rest[: count * hop].reshape(count, hop) ** 2).mean(1))
    level = 20 * np.log10(voice_rms / (max(float(rest_rms.max()), float(voice_rms.max())) + 1e-9) + 1e-9)
    active = level > _THRESHOLD_DB
    # A voice lasts: drop single breaths and bleed shorter than a second.
    width = int(_MIN_SECONDS / _FRAME)
    sustained = np.convolve(active.astype(float), np.ones(width), mode="same") >= width * 0.75
    return sustained


def analyze(model, path: str, duration: float) -> dict:
    if duration <= 2 * WINDOW + 10:
        voiced = _voiced(model, path, 0.0, duration)
        frames = np.nonzero(voiced)[0]
        if not len(frames):
            return {"vocals_in": round(duration, 2), "vocals_out": 0.0}
        return {
            "vocals_in": round(float(frames[0] * _FRAME), 2),
            "vocals_out": round(min(duration, float((frames[-1] + 1) * _FRAME)), 2),
        }
    intro = np.nonzero(_voiced(model, path, 0.0, WINDOW))[0]
    outro_start = duration - WINDOW
    outro = np.nonzero(_voiced(model, path, outro_start, WINDOW))[0]
    vocals_out = min(duration, outro_start + float((outro[-1] + 1) * _FRAME)) if len(outro) else outro_start
    return {
        "vocals_in": round(float(intro[0] * _FRAME) if len(intro) else WINDOW, 2),
        "vocals_out": round(vocals_out, 2),
    }


def main() -> None:
    os.nice(15)
    torch.set_num_threads(max(1, (os.cpu_count() or 2) // 2))
    model = get_model("htdemucs")
    model.eval()
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            result = analyze(model, request["path"], float(request["duration"]))
        except Exception as e:  # noqa: BLE001 - every failure is reported and the next song goes on
            result = {"error": f"{type(e).__name__}: {e}"[:500]}
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
