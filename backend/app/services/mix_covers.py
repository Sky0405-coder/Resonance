"""Deterministic covers for generated mixes."""

import colorsys
import hashlib
import io
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


def _font(size: int, bold: bool = False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    path = Path("/usr/share/fonts/truetype/dejavu") / name
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default(size=size)


def _wrap(name: str, font) -> list[str]:
    lines: list[str] = []
    for word in name.split():
        if lines and font.getlength(f"{lines[-1]} {word}") <= 560:
            lines[-1] += f" {word}"
        else:
            lines.append(word)
    return lines or [""]


def render(name: str, subtitle: str | None, covers: list[bytes], accent_seed: str) -> bytes:
    hue = int.from_bytes(hashlib.sha256(accent_seed.encode()).digest()[:4]) / 2**32
    accent = tuple(round(channel * 255) for channel in colorsys.hsv_to_rgb(hue, 0.65, 0.55))
    images = []
    seen = set()
    for data in covers:
        digest = hashlib.sha256(data).digest()
        if digest in seen:
            continue
        seen.add(digest)
        try:
            with Image.open(io.BytesIO(data)) as image:
                images.append(image.convert("RGB"))
        except (OSError, ValueError):
            continue
        if len(images) == 4:
            break
    image = Image.new("RGB", (640, 640), accent)
    if len(images) == 4:
        for index, cover in enumerate(images):
            image.paste(ImageOps.fit(cover, (320, 320)), ((index % 2) * 320, (index // 2) * 320))
    elif images:
        image = ImageOps.fit(images[0], (640, 640))
    image = Image.blend(image, Image.new("RGB", image.size, accent), 0.55).convert("RGBA")
    gradient = Image.new("RGBA", (1, 640))
    gradient.putdata([(*accent, round(255 * 0.9 * max(0, (y - 256) / 383))) for y in range(640)])
    image = Image.alpha_composite(image, gradient.resize(image.size))
    for size in range(72, 39, -1):
        font = _font(size, bold=True)
        lines = _wrap(name, font)
        if len(lines) <= 2 and all(font.getlength(line) <= 560 for line in lines):
            break
    if len(lines) > 2 or any(font.getlength(line) > 560 for line in lines):
        lines = lines[:2]
        for index, line in enumerate(lines):
            if font.getlength(line) > 560 or index == 1:
                while line and font.getlength(line + "…") > 560:
                    line = line[:-1]
                lines[index] = line.rstrip() + "…"
    text = "\n".join(lines)
    overlay = Image.new("RGBA", image.size)
    draw = ImageDraw.Draw(overlay)
    bounds = draw.multiline_textbbox((0, 0), text, font=font, spacing=10)
    top = 600 - (bounds[3] - bounds[1])
    draw.multiline_text((40, top - bounds[1]), text, font=font, fill="white", spacing=10)
    if subtitle:
        draw.text((40, top - 44), subtitle, font=_font(28), fill=(255, 255, 255, 204), anchor="lt")
    out = io.BytesIO()
    Image.alpha_composite(image, overlay).convert("RGB").save(out, "JPEG", quality=90)
    return out.getvalue()
