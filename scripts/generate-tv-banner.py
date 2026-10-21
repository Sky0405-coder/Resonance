#!/usr/bin/env python3
"""Render the Android TV banner from the existing Resonance launcher artwork (Pillow)."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "app/android/app/src/main/res"
SCALE = 3


def main():
    image = Image.new("RGB", (320 * SCALE, 180 * SCALE), "#121212")
    logo = Image.open(RES / "mipmap-xxxhdpi/ic_launcher.png").convert("RGBA")
    logo = logo.resize((96 * SCALE, 96 * SCALE), Image.Resampling.LANCZOS)
    image.paste(logo, (20 * SCALE, 42 * SCALE), logo)
    fonts = [
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"),
        Path("/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"),
    ]
    font_path = next((path for path in fonts if path.exists()), "DejaVuSans-Bold.ttf")
    font = ImageFont.truetype(str(font_path), 25 * SCALE)
    ImageDraw.Draw(image).text((130 * SCALE, 90 * SCALE), "Resonance", font=font, fill="white", anchor="lm")
    output = RES / "drawable-xhdpi/tv_banner.png"
    output.parent.mkdir(parents=True, exist_ok=True)
    image.resize((320, 180), Image.Resampling.LANCZOS).save(output)


if __name__ == "__main__":
    main()
