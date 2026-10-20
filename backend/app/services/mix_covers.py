"""Deterministic covers for generated mixes."""

import colorsys
import hashlib
import io
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


def _font(size: int, bold: bool = False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    # Debian (the container) and Fedora paths.
    for directory in ("/usr/share/fonts/truetype/dejavu", "/usr/share/fonts/dejavu-sans-fonts"):
        path = Path(directory) / name
        if path.exists():
            return ImageFont.truetype(str(path), size)
    return ImageFont.load_default(size=size)


def _rings(accent: tuple[int, ...], hue: float) -> Image.Image:
    """Covers without album art: a diagonal two-tone gradient with soft concentric rings (like sound waves)."""
    second = tuple(round(channel * 255) for channel in colorsys.hsv_to_rgb((hue + 0.12) % 1, 0.7, 0.32))
    # Top left to bottom right.
    mask = Image.frombytes("L", (640, 640), bytes((x + y) * 255 // 1278 for y in range(640) for x in range(640)))
    image = Image.composite(Image.new("RGB", (640, 640), second), Image.new("RGB", (640, 640), accent), mask)
    rings = Image.new("RGBA", (640, 640))
    draw = ImageDraw.Draw(rings)
    for index, radius in enumerate(range(90, 900, 90)):
        draw.ellipse(
            (560 - radius, 120 - radius, 560 + radius, 120 + radius),
            outline=(255, 255, 255, max(10, 60 - index * 6)),
            width=10,
        )
    return Image.alpha_composite(image.convert("RGBA"), rings).convert("RGB")


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
    if len(images) >= 2:
        # Two or three covers repeat diagonally so the mosaic stays a 2×2 grid.
        tiles = {2: [0, 1, 1, 0], 3: [0, 1, 2, 0]}.get(len(images), [0, 1, 2, 3])
        image = Image.new("RGB", (640, 640))
        for index, tile in enumerate(tiles):
            image.paste(ImageOps.fit(images[tile], (320, 320)), ((index % 2) * 320, (index // 2) * 320))
        image = Image.blend(image, Image.new("RGB", image.size, accent), 0.55)
    elif images:
        image = Image.blend(ImageOps.fit(images[0], (640, 640)), Image.new("RGB", (640, 640), accent), 0.55)
    else:
        image = _rings(accent, hue)
    image = image.convert("RGBA")
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


def mosaic(covers: list[bytes]) -> bytes | None:
    """A playlist's album covers as one image (2×2 from four, else the first), for clients that show a single
    picture such as Android Auto."""
    images = []
    for data in covers:
        try:
            with Image.open(io.BytesIO(data)) as image:
                images.append(image.convert("RGB"))
        except (OSError, ValueError):
            continue
    if not images:
        return None
    if len(images) >= 4:
        image = Image.new("RGB", (640, 640))
        for index, cover in enumerate(images[:4]):
            image.paste(ImageOps.fit(cover, (320, 320)), ((index % 2) * 320, (index // 2) * 320))
    else:
        image = ImageOps.fit(images[0], (640, 640))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=90)
    return out.getvalue()


def liked() -> bytes:
    """The Liked Songs cover: a white heart on a violet-to-blue gradient."""
    mask = Image.frombytes("L", (640, 640), bytes((x + y) * 255 // 1278 for y in range(640) for x in range(640)))
    image = Image.composite(Image.new("RGB", (640, 640), (120, 200, 230)), Image.new("RGB", (640, 640), (72, 24, 230)), mask)
    # The classic heart curve, drawn large and scaled down for smooth edges.
    scale = 4
    points = []
    for step in range(360):
        t = math.radians(step)
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        points.append(((320 + x * 9) * scale, (305 - y * 9) * scale))
    heart = Image.new("L", (640 * scale, 640 * scale))
    ImageDraw.Draw(heart).polygon(points, fill=255)
    image.paste(Image.new("RGB", (640, 640), "white"), mask=heart.resize((640, 640), Image.LANCZOS))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=92)
    return out.getvalue()
