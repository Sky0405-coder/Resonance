#!/usr/bin/env python3
"""Render branding/logo.svg with Pillow (circles + circular SVG arcs, no extra deps)."""
import math
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[3]
TARGET = Path(__file__).resolve().parents[1] / 'icon.png'
SCALE = 8
SIZE = 117
svg = ET.parse(ROOT / 'branding' / 'logo.svg').getroot()
view = [float(n) for n in svg.attrib['viewBox'].split()]
scale = SIZE * SCALE / view[2]
canvas = Image.new('RGBA', (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)

def circle(cx, cy, radius, fill):
    draw.ellipse(tuple(round(v * scale) for v in (cx-radius, cy-radius, cx+radius, cy+radius)), fill=fill)

for node in svg:
    if node.tag.endswith('circle'):
        circle(float(node.attrib['cx']), float(node.attrib['cy']), float(node.attrib['r']), node.attrib['fill'])
    elif node.tag.endswith('g'):
        width = float(node.attrib['stroke-width'])
        for path in node:
            values = [float(v) for v in re.findall(r'-?\d+(?:\.\d+)?', path.attrib['d'])]
            x1, y1, rx, ry, rotation, large, sweep, x2, y2 = values
            if rx != ry or rotation or large:
                raise ValueError('Logo now uses an unsupported arc; update this renderer.')
            dx, dy = (x2-x1)/2, (y2-y1)/2
            chord = math.hypot(dx, dy)
            distance = math.sqrt(max(0, rx*rx-chord*chord))
            sign = 1 if sweep else -1
            cx = (x1+x2)/2 - sign*dy/chord*distance
            cy = (y1+y2)/2 + sign*dx/chord*distance
            start = math.atan2(y1-cy, x1-cx)
            end = math.atan2(y2-cy, x2-cx)
            delta = (end-start) % (2*math.pi) if sweep else -((start-end) % (2*math.pi))
            points = [((cx+rx*math.cos(start+delta*i/160))*scale,
                       (cy+rx*math.sin(start+delta*i/160))*scale) for i in range(161)]
            draw.line(points, fill=node.attrib['stroke'], width=round(width*scale), joint='curve')
            circle(x1, y1, width/2, node.attrib['stroke'])
            circle(x2, y2, width/2, node.attrib['stroke'])
canvas.resize((SIZE, SIZE), Image.Resampling.LANCZOS).save(TARGET)
print(TARGET)
