#!/usr/bin/env python3
"""Draw the app icons from the first idle frame, without any image library.

Usage: make_icon.py mac/PixeldeckMac/Board/Resources/sprites.json mac/PixeldeckMac/Assets.xcassets/AppIcon.appiconset
"""
import json
import struct
import sys
import zlib
from pathlib import Path

ICON_SIZE = 1024
BACKGROUND = (0x12, 0x0E, 0x18)
SPRITE_SIDE = 16
MARGIN_CELLS = 2

MAC_SIZES = (16, 32, 64, 128, 256, 512, 1024)
# The share of the canvas macOS expects the rounded square to fill, and its corner.
MAC_BODY_SHARE = 824 / 1024
MAC_CORNER_SHARE = 185 / 824
MAC_MAX_SAMPLES = 8


def hex_color(value):
    return tuple(int(value[index : index + 2], 16) for index in (1, 3, 5))


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))


def read_sprite(source):
    with open(source, encoding="utf8") as file:
        library = json.load(file)
    palette = {key: hex_color(value) for key, value in library["palette"].items()}
    return palette, library["sprites"]["idle"]["frames"][0]


def write_png(target, size, rows):
    """Writes 8-bit RGBA."""
    raw = b"".join(b"\0" + row for row in rows)
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    with open(target, "wb") as file:
        file.write(b"\x89PNG\r\n\x1a\n")
        file.write(chunk(b"IHDR", header))
        file.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        file.write(chunk(b"IEND", b""))


def inside_rounded_square(x, y, inset, corner):
    """Takes coordinates on a canvas from 0 to 1."""
    left, right = inset + corner, 1 - inset - corner
    nearest_x, nearest_y = min(max(x, left), right), min(max(y, left), right)
    return (x - nearest_x) ** 2 + (y - nearest_y) ** 2 <= corner**2


def mac_icon(palette, rows, size, target):
    """Averages several samples per pixel, so small sizes keep the eyes and the corners stay smooth."""
    samples = min(max(2, ICON_SIZE // size), MAC_MAX_SAMPLES)
    inset = (1 - MAC_BODY_SHARE) / 2
    corner = MAC_BODY_SHARE * MAC_CORNER_SHARE
    cell = MAC_BODY_SHARE / (SPRITE_SIDE + 2 * MARGIN_CELLS)
    origin = (1 - cell * SPRITE_SIDE) / 2

    def color_at(x, y):
        if not inside_rounded_square(x, y, inset, corner):
            return None
        column, row = int((x - origin) // cell), int((y - origin) // cell)
        if 0 <= column < SPRITE_SIDE and 0 <= row < SPRITE_SIDE:
            return palette.get(rows[row][column], BACKGROUND)
        return BACKGROUND

    def pixel(x, y):
        colors = [
            color_at((x + (u + 0.5) / samples) / size, (y + (v + 0.5) / samples) / size)
            for v in range(samples)
            for u in range(samples)
        ]
        solid = [color for color in colors if color is not None]
        if not solid:
            return bytes(4)
        channels = [sum(color[index] for color in solid) // len(solid) for index in range(3)]
        return bytes(channels + [255 * len(solid) // len(colors)])

    write_png(target, size, (b"".join(pixel(x, y) for x in range(size)) for y in range(size)))


def mac_icons(source, directory):
    palette, rows = read_sprite(source)
    for size in MAC_SIZES:
        mac_icon(palette, rows, size, Path(directory) / f"icon-{size}.png")


if __name__ == "__main__":
    mac_icons(sys.argv[1], sys.argv[2])
