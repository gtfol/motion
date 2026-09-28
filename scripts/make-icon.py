#!/usr/bin/env python3
"""Render vitals' app icon with Python's standard library: a white lowercase "v" on an opaque #111 canvas.

This follows gtfol's single-lowercase-letter marks (freewrite's white "f" on #111, capsule's black "c" on white).
The outline is the "v" glyph of the bundled Lato Regular (SIL Open Font License, Vitals/Resources/Lato-OFL.txt),
in font units (2000 per em), as extracted with fontTools' RecordingPen. Run from the repository root.
"""
import struct
import zlib
from pathlib import Path

SIZE = 1024
CANVAS = 17  # #111111
MARK = 255
GLYPH = [
    ('moveTo', [(1009, 1013)]), ('lineTo', [(596, 0)]), ('lineTo', [(436, 0)]), ('lineTo', [(23, 1013)]),
    ('lineTo', [(168, 1013)]), ('qCurveTo', [(190, 1013), (218, 991), (223, 976)]), ('lineTo', [(480, 324)]),
    ('qCurveTo', [(492, 287), (510, 217), (518, 182)]), ('qCurveTo', [(526, 217), (544, 287), (557, 324)]),
    ('lineTo', [(817, 976)]), ('qCurveTo', [(823, 992), (851, 1013), (870, 1013)]), ('closePath', []),
]


def flatten(ops, steps=16):
    """TrueType quadratic curves may chain off-curve points with implied on-curve midpoints."""
    points, current = [], None
    for op, args in ops:
        if op == 'moveTo':
            current = args[0]; points.append(current)
        elif op == 'lineTo':
            current = args[0]; points.append(current)
        elif op == 'qCurveTo':
            *controls, end = args
            for index, control in enumerate(controls):
                target = end if index == len(controls) - 1 else (
                    (control[0] + controls[index + 1][0]) / 2, (control[1] + controls[index + 1][1]) / 2)
                for step in range(1, steps + 1):
                    t = step / steps
                    x = (1 - t) ** 2 * current[0] + 2 * (1 - t) * t * control[0] + t ** 2 * target[0]
                    y = (1 - t) ** 2 * current[1] + 2 * (1 - t) * t * control[1] + t ** 2 * target[1]
                    points.append((x, y))
                current = target
    return points


def render():
    outline = flatten(GLYPH)
    xs, ys = [p[0] for p in outline], [p[1] for p in outline]
    height = 410
    scale = height / (max(ys) - min(ys))
    width = (max(xs) - min(xs)) * scale
    left, top = (SIZE - width) / 2, (SIZE - height) / 2
    polygon = [((x - min(xs)) * scale + left, (max(ys) - y) * scale + top) for x, y in outline]
    edges = list(zip(polygon, polygon[1:] + polygon[:1]))
    coverage = [[0.0] * SIZE for _ in range(SIZE)]
    samples = 4
    for row in range(SIZE):
        for sub in range(samples):
            y = row + (sub + 0.5) / samples
            crossings = sorted(x0 + (y - y0) * (x1 - x0) / (y1 - y0)
                               for (x0, y0), (x1, y1) in edges if (y0 <= y < y1) or (y1 <= y < y0))
            for start, end in zip(crossings[0::2], crossings[1::2]):
                for column in range(max(0, int(start)), min(SIZE, int(end) + 1)):
                    overlap = min(end, column + 1) - max(start, column)
                    if overlap > 0: coverage[row][column] += overlap / samples
    rows = []
    for row in coverage:
        line = bytearray([0])  # PNG filter type 0 for each scanline
        for amount in row:
            value = round(CANVAS + (MARK - CANVAS) * min(1.0, amount))
            line += bytes((value, value, value))
        rows.append(bytes(line))
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xFFFFFFFF)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0)) \
        + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b'')
    Path('Vitals/Assets.xcassets/AppIcon.appiconset/AppIcon.png').write_bytes(png)


if __name__ == '__main__':
    render()
