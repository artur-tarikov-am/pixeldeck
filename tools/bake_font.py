#!/usr/bin/env python3
"""Turn the public-domain X11 6x10 BDF font into the JSON table the app draws text from.

Usage: bake_font.py path/to/6x10.bdf mac/PixeldeckMac/Board/Resources/font6x10.json
"""
import json
import re
import sys

EXTRA_SYMBOLS = "Ёё—–«»…•→←↑↓№·×"
WANTED = (
    set(range(0x20, 0x7F))
    | set(range(0x410, 0x450))
    | {ord(symbol) for symbol in EXTRA_SYMBOLS}
)
# The X11 font has no check mark, so it is drawn here, in the same 6-bit rows.
CHECK_MARK = [0, 0, 0b000001, 0b000010, 0b100010, 0b010100, 0b001000, 0, 0, 0]
GLYPH = re.compile(r"ENCODING (\d+)\n.*?BBX 6 10 0 -2\nBITMAP\n(.*?)ENDCHAR", re.S)


def main(source, target):
    with open(source, encoding="latin1") as file:
        bdf = file.read()
    glyphs = {}
    for codepoint, rows in GLYPH.findall(bdf):
        character = chr(int(codepoint))
        if ord(character) in WANTED:
            glyphs[character] = [int(row, 16) >> 2 for row in rows.split()]
    glyphs["✓"] = CHECK_MARK
    missing = sorted(chr(code) for code in WANTED - {ord(c) for c in glyphs})
    if missing:
        sys.exit(f"font has no glyphs for: {''.join(missing)}")
    with open(target, "w", encoding="utf8") as file:
        json.dump({"width": 6, "height": 10, "glyphs": glyphs}, file, ensure_ascii=False)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
