#!/usr/bin/env python3
"""Generate the built-in character sprites. This file is their source of truth.

Usage: make_sprites.py mac/PixeldeckMac/Board/Resources/sprites.json
"""
import json
import sys

SIZE = 16
PALETTE = {
    "o": "#E07A4B",  # body
    "s": "#A9502F",  # body shade
    "h": "#F4A679",  # body highlight
    "e": "#1B1420",  # eyes
    "w": "#F5EFE6",  # white
    "y": "#F2C14E",  # yellow accent
    "g": "#6BCB77",  # green accent
    "r": "#E5484D",  # red accent
    "b": "#6FB7E9",  # blue accent
    "t": "#B09A6B",  # dry grass
    "a": "#8A829A",  # asleep coat
    "d": "#5A5368",  # asleep coat shade
    "p": "#9B7FE8",  # octopus body
    "q": "#6A52B3",  # octopus shade
    "l": "#C4B3F5",  # octopus highlight
}
BODY = [
    "....oooooooo....",
    "...oooooooooo...",
    "..oooooooooooo..",
    "..oooooooooooo..",
    "..oooooooooooo..",
    "..oooooooooooo..",
    "..oooooooooooo..",
    "...oooooooooo...",
    "....ssssssss....",
]
BODY_TOP = 5
EYES_TOP = 7
LEFT_EYE_X = 5
RIGHT_EYE_X = 9
EYES = {
    "open": ["ee", "ee", "ee"],
    "wide": ["we", "we", "ww"],
    "up": ["ee", "ee", ".."],
    "shut": ["..", "..", "ee"],
    "happy": [".e", "e.", ".."],
    "cross": ["e.", ".e", "e."],
    "left": ["e.", "e.", "e."],
    "right": [".e", ".e", ".e"],
    "half": ["..", "ee", "ee"],
}
LEGS = {
    "stand": ["....ss....ss....", "....ss....ss...."],
    "step_left": ["....ss....ss....", "..........ss...."],
    "step_right": ["....ss....ss....", "....ss.........."],
    "tucked": ["................", "....ss....ss...."],
}


class Canvas:
    def __init__(self, width=SIZE, height=SIZE):
        self.width = width
        self.height = height
        self.rows = [["."] * width for _ in range(height)]

    def paint(self, x, y, pixels):
        for row_offset, row in enumerate(pixels):
            for column_offset, pixel in enumerate(row):
                target_x, target_y = x + column_offset, y + row_offset
                if pixel != "." and 0 <= target_x < self.width and 0 <= target_y < self.height:
                    self.rows[target_y][target_x] = pixel

    def text(self):
        return ["".join(row) for row in self.rows]


def frame(eyes="open", legs="stand", lift=0, shift=0, antenna="y", arms=None, extras=()):
    canvas = Canvas()
    top = BODY_TOP - lift
    canvas.paint(0, 14, LEGS[legs])
    if lift and legs != "tucked":
        canvas.paint(0, 14 - lift, LEGS["stand"][:1])
    canvas.paint(shift, top, BODY)
    canvas.paint(4 + shift, top + 1, ["hhh"])
    canvas.paint(3 + shift, top + 2, ["h"])
    canvas.paint(7 + shift, top - 1, ["s"])
    canvas.paint(7 + shift, top - 3, [antenna, antenna])
    canvas.paint(7 + shift, top - 2, ["s"])
    eye_y = EYES_TOP - lift
    canvas.paint(LEFT_EYE_X + shift, eye_y, EYES[eyes])
    canvas.paint(RIGHT_EYE_X + shift, eye_y, EYES[eyes])
    if arms == "wave":
        canvas.paint(14 + shift, top + 1, ["s", "s", "s"])
    elif arms == "wave_low":
        canvas.paint(14 + shift, top + 3, ["ss"])
    elif arms == "shrug":
        canvas.paint(14 + shift, top + 2, ["s"])
        canvas.paint(15 + shift, top + 1, ["s"])
        canvas.paint(1 + shift, top + 2, ["s"])
        canvas.paint(shift, top + 1, ["s"])
    for x, y, pixels in extras:
        canvas.paint(x, y, pixels)
    return canvas.text()


SPARK = ["y"]
Z_SMALL = ["bb", ".b", "bb"]
QUESTION = ["yy.", "..y", ".y.", "...", ".y."]
NEAR_WAVE = [(5, 1, ["b"]), (10, 1, ["b"])]
FAR_WAVE = [(4, 0, ["b"]), (11, 0, ["b"])]
TUMBLEWEED = [
    "..t.t...",
    ".t.t.tt.",
    "t.t.t..t",
    ".t.ttt..",
    "..ttt.t.",
    "t..t.t.t",
    ".tt.t.t.",
    "...t.t..",
]


# Small enough for the strip beside the notch.
CRITTER_WIDTH = 14
CRITTER_HEIGHT = 12
CRITTER_EYES_TOP = 3
CRITTER_OFFLINE_COAT = str.maketrans({"o": "a", "h": "a", "s": "d"})
CRITTER_SITTING = [
    ".o......o.....",
    ".oh....ho.....",
    ".oooooooo.....",
    ".oooooooo.....",
    ".oooooooo.....",
    ".oooooooo.....",
    "..oooooo......",
    "..oooooo......",
    ".oooooooo.....",
    ".oooooooo.....",
    ".oooooooo.....",
    ".ss.ss.ss.....",
]
CRITTER_LYING = [
    "..............",
    "..............",
    "..............",
    "..............",
    ".o......o.....",
    ".oh....ho.....",
    ".ooooooooooo..",
    ".oooooooooooo.",
    ".oeeooeeooooo.",
    ".oooooooooooo.",
    ".oooooooooooo.",
    "..ssssssssss..",
]
CRITTER_EYES = {
    "open": ["e", "e"],
    "shut": ["e"],
}
CRITTER_TAILS = {
    "up": [
        "",
        "",
        "",
        "",
        "............o.",
        "............oo",
        ".............o",
        ".............o",
        "............oo",
        "...........oo.",
        ".........ooo..",
    ],
    "swish": [
        "",
        "",
        "",
        "",
        "",
        "",
        "..............",
        "..............",
        ".............o",
        "............oo",
        ".........oooo.",
    ],
}
Z_TINY = ["bbb", ".b.", "bbb"]


def quarter_turn(rows):
    return ["".join(column) for column in zip(*reversed(rows))]


def tumbleweed_frames():
    frames = []
    rows = TUMBLEWEED
    for index in range(4):
        canvas = Canvas()
        canvas.paint(4, 8 - index % 2, rows)
        frames.append(canvas.text())
        rows = quarter_turn(rows)
    return frames


def critter(eyes="open", tail="up", eye_shift=0, is_online=True, extras=()):
    canvas = Canvas(CRITTER_WIDTH, CRITTER_HEIGHT)
    canvas.paint(0, 0, CRITTER_SITTING)
    canvas.paint(0, 0, CRITTER_TAILS[tail])
    canvas.paint(3 + eye_shift, CRITTER_EYES_TOP, CRITTER_EYES[eyes])
    canvas.paint(6 + eye_shift, CRITTER_EYES_TOP, CRITTER_EYES[eyes])
    return finish_critter(canvas, is_online, extras)


def sleeping_critter(extras=()):
    canvas = Canvas(CRITTER_WIDTH, CRITTER_HEIGHT)
    canvas.paint(0, 0, CRITTER_LYING)
    return finish_critter(canvas, is_online=False, extras=extras)


def finish_critter(canvas, is_online, extras):
    rows = canvas.text()
    if not is_online:
        rows = [row.translate(CRITTER_OFFLINE_COAT) for row in rows]
    canvas.rows = [list(row) for row in rows]
    for x, y, pixels in extras:
        canvas.paint(x, y, pixels)
    return canvas.text()


# The GitHub tile has its own animal, so the two tiles do not read as one character.
OCTOPUS_HEAD = [
    ".....pppppp.....",
    "...pppppppppp...",
    "..pppppppppppp..",
    "..pppppppppppp..",
    "..pppppppppppp..",
    "..pppppppppppp..",
    "..pppppppppppp..",
    "...pppppppppp...",
    "...qqqqqqqqqq...",
]
OCTOPUS_HEAD_TOP = 3
OCTOPUS_EYES_TOP = 6
OCTOPUS_TENTACLES_TOP = 12
OCTOPUS_TENTACLES = {
    "rest": [
        "..qq.qq..qq.qq..",
        "..qq.qq..qq.qq..",
        ".qq..qq..qq..qq.",
        ".q....q..q....q.",
    ],
    "sway_left": [
        "..qq.qq..qq.qq..",
        "..qq.qq..qq.qq..",
        ".qq.qq..qq..qq..",
        ".q..q...q...q...",
    ],
    "sway_right": [
        "..qq.qq..qq.qq..",
        "..qq.qq..qq.qq..",
        "..qq..qq..qq.qq.",
        "...q...q...q..q.",
    ],
    "raised": [
        "..qq.qq..qq.....",
        "..qq.qq..qq.....",
        ".qq..qq..qq.....",
        ".q....q..q......",
    ],
    "limp": [
        ".qqq.qq..qq.qqq.",
        "qq....qq.qq...qq",
    ],
}
OCTOPUS_ARM_RAISED = [
    ".q",
    "qq",
    "q.",
    "q.",
    "q.",
    "q.",
    "q.",
    "q.",
    "qq",
]
OCTOPUS_ARM_LOWERED = [
    "qq",
    ".q",
    ".q",
    ".q",
    "q.",
    "q.",
    "qq",
]
OCTOPUS_LIMP_LIFT = -2
OCTOPUS_ASLEEP_COAT = str.maketrans({"p": "a", "l": "a", "q": "d"})
OCTOPUS_ALARM_COAT = str.maketrans({"p": "r", "l": "r", "q": "s"})
EXCLAMATION = ["y", "y", ".", "y"]
BUBBLE = ["bb", "bb"]
PAGE = [
    "wwwwww",
    "waaaww",
    "wwwwww",
    "waaaaw",
    "wwwwww",
]
CHECK_MARK = [
    "....g",
    "...g.",
    "g.g..",
    ".g...",
]


def octopus(eyes="open", tentacles="rest", lift=0, shift=0, coat=None, extras=()):
    canvas = Canvas()
    top = OCTOPUS_HEAD_TOP - lift
    canvas.paint(shift, OCTOPUS_TENTACLES_TOP - lift, OCTOPUS_TENTACLES[tentacles])
    canvas.paint(shift, top, OCTOPUS_HEAD)
    canvas.paint(5 + shift, top + 1, ["lll"])
    canvas.paint(3 + shift, top + 2, ["ll"])
    canvas.paint(3 + shift, top + 3, ["l"])
    eye_y = OCTOPUS_EYES_TOP - lift
    canvas.paint(LEFT_EYE_X + shift, eye_y, EYES[eyes])
    canvas.paint(RIGHT_EYE_X + shift, eye_y, EYES[eyes])
    if coat:
        canvas.rows = [list(row.translate(coat)) for row in canvas.text()]
    for x, y, pixels in extras:
        canvas.paint(x, y, pixels)
    return canvas.text()


def bubbles(step):
    return [(14, y - 3 * (step % 2), BUBBLE) for y in (11, 5)]


def lever(knob, is_on):
    canvas = Canvas()
    canvas.paint(3, 14, ["ssssssssss", "ssssssssss"])
    canvas.paint(7, 12, ["ww", "ww"])
    canvas.paint(6, 10, ["ww", "ww"])
    canvas.paint(5, 8, ["ww", "ww"])
    canvas.paint(3, 5, [knob * 3] * 3)
    rows = canvas.text()
    return [row[::-1] for row in rows] if is_on else rows


def sprites():
    return {
        "idle": {
            "fps": 4,
            "frames": [frame()] * 6 + [frame(lift=1)] * 2 + [frame()] * 3 + [frame(eyes="shut")],
        },
        "walk": {
            "fps": 6,
            "frames": [
                frame(legs="step_left", lift=1),
                frame(legs="stand"),
                frame(legs="step_right", lift=1),
                frame(legs="stand"),
            ],
        },
        "thinking": {
            "fps": 4,
            "frames": [
                frame(eyes="up", antenna="b"),
                frame(eyes="up", antenna="w"),
                frame(eyes="up", antenna="y", lift=1),
                frame(eyes="up", antenna="w", lift=1),
            ],
        },
        "waiting": {
            "fps": 3,
            "frames": [
                frame(arms="wave", antenna="y", extras=[(12, 0, ["y", "y", ".", "y"])]),
                frame(arms="wave_low", antenna="y"),
            ],
        },
        "done": {
            "fps": 5,
            "frames": [
                frame(eyes="happy", antenna="g"),
                frame(eyes="happy", antenna="g", legs="tucked", lift=2,
                      extras=[(1, 3, SPARK), (14, 5, SPARK)]),
                frame(eyes="happy", antenna="g", legs="tucked", lift=3,
                      extras=[(2, 1, SPARK), (13, 2, SPARK), (0, 7, SPARK)]),
                frame(eyes="happy", antenna="g", lift=1, extras=[(14, 1, SPARK)]),
            ],
        },
        "error": {
            "fps": 8,
            "frames": [
                frame(eyes="cross", antenna="r", shift=-1),
                frame(eyes="cross", antenna="r", shift=1),
                frame(eyes="cross", antenna="r", shift=-1),
                frame(eyes="cross", antenna="r"),
                frame(eyes="cross", antenna="r"),
                frame(eyes="cross", antenna="r"),
            ],
        },
        "alert": {
            "fps": 8,
            "frames": [
                frame(eyes="wide", legs="tucked", lift=2, antenna="w"),
                frame(eyes="wide", antenna="y"),
            ],
        },
        "sleep": {
            "fps": 2,
            "frames": [
                frame(eyes="shut", antenna="s", extras=[(12, 1, Z_SMALL)]),
                frame(eyes="shut", antenna="s", extras=[(13, 0, Z_SMALL)]),
                frame(eyes="shut", antenna="s", lift=1, extras=[(14, 0, ["b"])]),
            ],
        },
        "look": {
            "fps": 2,
            "frames": [
                frame(eyes="left", extras=[(11, 0, QUESTION)]),
                frame(eyes="left", extras=[(11, 0, QUESTION)]),
                frame(eyes="right", extras=[(11, 0, QUESTION)]),
                frame(eyes="right", extras=[(11, 0, QUESTION)]),
                frame(extras=[(11, 0, QUESTION)]),
            ],
        },
        "bored": {
            "fps": 2,
            "frames": [frame(eyes="half")] * 4 + [
                frame(eyes="half", extras=[(1, 9, ["w"])]),
                frame(eyes="half", extras=[(0, 7, ["w"])]),
            ],
        },
        "watch": {
            "fps": 4,
            "frames": [frame(eyes="right")] * 7 + [frame(eyes="shut")],
        },
        "leap": {"fps": 1, "frames": [frame(eyes="wide", legs="tucked")]},
        "press": {
            "fps": 6,
            "frames": [frame(eyes="wide", arms="wave_low", shift=1), frame(eyes="wide", arms="wave_low")],
        },
        "hopeful": {
            "fps": 5,
            "frames": [
                frame(eyes="happy", antenna="g", arms="wave"),
                frame(eyes="happy", antenna="g", arms="wave_low", lift=1),
            ],
        },
        "shrug": {
            "fps": 2,
            "frames": [frame(eyes="half", arms="shrug", lift=1), frame(eyes="half", arms="shrug")],
        },
        "listen": {
            "fps": 4,
            "frames": [
                frame(eyes="up", antenna="w"),
                frame(eyes="up", antenna="b", extras=NEAR_WAVE),
                frame(eyes="up", antenna="b", extras=NEAR_WAVE + FAR_WAVE),
                frame(eyes="up", antenna="w"),
                frame(eyes="up", antenna="r"),
                frame(eyes="up", antenna="r"),
            ],
        },
        "tumbleweed": {"fps": 6, "frames": tumbleweed_frames()},
        "lever_off": {"fps": 1, "frames": [lever("r", is_on=False)]},
        "lever_on": {"fps": 1, "frames": [lever("g", is_on=True)]},
        "critter_online": {
            "fps": 4,
            "frames": [critter()] * 5 + [critter(eyes="shut")] + [critter()] * 4 + [
                critter(tail="swish"),
                critter(),
                critter(tail="swish"),
                critter(),
            ],
        },
        "critter_connecting": {
            "fps": 2,
            "frames": [
                critter(eye_shift=-1, tail="swish", is_online=False),
                critter(eye_shift=-1, tail="swish", is_online=False),
                critter(eye_shift=1, tail="swish", is_online=False),
                critter(eye_shift=1, tail="swish", is_online=False),
            ],
        },
        "critter_offline": {
            "fps": 2,
            "frames": [
                sleeping_critter(extras=[(9, 3, Z_TINY)]),
                sleeping_critter(extras=[(10, 2, Z_TINY)]),
                sleeping_critter(extras=[(11, 0, Z_TINY)]),
                sleeping_critter(),
            ],
        },
        "octopus_idle": {
            "fps": 3,
            "frames": [
                octopus(),
                octopus(),
                octopus(tentacles="sway_left"),
                octopus(tentacles="sway_left"),
                octopus(),
                octopus(eyes="shut"),
                octopus(tentacles="sway_right"),
                octopus(tentacles="sway_right"),
            ],
        },
        "octopus_running": {
            "fps": 4,
            "frames": [
                octopus(eyes="up", tentacles=sway, extras=bubbles(step))
                for step, sway in enumerate(["sway_left", "rest", "sway_right", "rest"])
            ],
        },
        "octopus_waiting": {
            "fps": 3,
            "frames": [
                octopus(tentacles="raised", extras=[(14, 3, OCTOPUS_ARM_RAISED), (1, 0, EXCLAMATION)]),
                octopus(tentacles="raised", extras=[(14, 5, OCTOPUS_ARM_LOWERED)]),
            ],
        },
        "octopus_failed": {
            "fps": 6,
            "frames": [
                octopus(eyes="cross", shift=-1, coat=OCTOPUS_ALARM_COAT),
                octopus(eyes="cross", shift=1, coat=OCTOPUS_ALARM_COAT),
                octopus(eyes="cross", shift=-1, coat=OCTOPUS_ALARM_COAT),
                octopus(eyes="cross", shift=1, coat=OCTOPUS_ALARM_COAT),
            ] + [octopus(eyes="cross", tentacles="limp", lift=OCTOPUS_LIMP_LIFT)] * 14,
        },
        "octopus_review": {
            "fps": 2,
            "frames": [
                octopus(eyes=eyes, extras=[(5, 10, PAGE)])
                for eyes in ["left", "left", "right", "right", "left", "right", "shut", "right"]
            ],
        },
        "octopus_done": {
            "fps": 5,
            "frames": [octopus(eyes="happy", extras=[(11, 0, CHECK_MARK)])] * 12 + [
                octopus(eyes="happy", tentacles="sway_left", lift=1, extras=[(1, 6, SPARK)]),
                octopus(eyes="happy", lift=3, extras=[(1, 2, SPARK), (14, 4, SPARK)]),
                octopus(eyes="happy", tentacles="sway_right", lift=1, extras=[(14, 1, SPARK)]),
            ],
        },
        "octopus_asleep": {
            "fps": 2,
            "frames": [
                octopus(eyes="shut", tentacles="limp", lift=OCTOPUS_LIMP_LIFT, coat=OCTOPUS_ASLEEP_COAT,
                        extras=[extra])
                for extra in [(12, 2, Z_SMALL), (13, 1, Z_SMALL), (14, 0, ["b"])]
            ],
        },
    }


def main(target):
    with open(target, "w", encoding="utf8") as file:
        json.dump({"palette": PALETTE, "sprites": sprites()}, file, indent=1)


if __name__ == "__main__":
    main(sys.argv[1])
