# Draws MacBeeb's Linux icons as SVG, from the same design as the Mac's
# (draw.py): the BASIC prompt in the SAA5050's ">" and a Mode 7 cursor, over
# a band of the BBC Micro's case with its red function keys. Shaped as
# GNOME's app icons are (a 128-unit grid, a rounded body with an edge below
# for depth), and a symbolic one for small sizes.
#
#   python3 Tools/icon/linux.py Resources/Linux/icons

import os
import sys

out = sys.argv[1]
APP = "com.accidentalfish.MacBeeb"

# The Mac icon's geometry, in its 1024 square (see draw.py).
S = 1024
GT = [0x00, 0x04, 0x08, 0x10, 0x20, 0x10, 0x08, 0x04, 0x00, 0x00]
U = 56
LEFT = (S - 10 * U) // 2 - 2 * U
TOP = 70
BAND = 690
n, w, gap = 5, 150, 22
x0 = (S - (n * w + (n - 1) * gap)) // 2

# GNOME's grid: the body 112 wide, 8 in from each side, 4 from the top,
# 108 tall, with 4 more of edge below it.
BODY = (8, 6, 112, 108)
EDGE = 4
scale = BODY[2] / S


def X(v):
    return BODY[0] + v * scale


def Y(v):
    return BODY[1] + v * scale


def L(v):
    return v * scale


def on(r, c):
    return 0 <= r < 10 and 0 <= c < 6 and GT[r] >> c & 1


def prompt_rects():
    rects = []
    for r in range(10):
        for c in range(6):
            if on(r, c):
                x, y = LEFT + c * U, TOP + r * U
                rects.append((x, y, U, U))
                # The SAA5050's character rounding.
                for dr, dc in ((1, 1), (1, -1)):
                    if on(r + dr, c + dc) and not on(r + dr, c) and not on(r, c + dc):
                        h = U // 2
                        if dc == 1:
                            rects.append((x + U, y + U - h, h, h))
                            rects.append((x + U - h, y + U, h, h))
                        else:
                            rects.append((x - h, y + U - h, h, h))
                            rects.append((x, y + U, h, h))
    # The cursor: the next cell's bottom row.
    rects.append((LEFT + 6 * U, TOP + 9 * U, 6 * U, U))
    return rects


def app_icon():
    bx, by, bw, bh = BODY
    radius = 14
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128">',
        "<defs>",
        f'<clipPath id="body"><rect x="{bx}" y="{by}" width="{bw}" height="{bh}" rx="{radius}"/></clipPath>',
        '<linearGradient id="screen" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#1b1e27"/><stop offset="1" stop-color="#101218"/></linearGradient>',
        "</defs>",
        # The edge below, the case's darker cream.
        f'<rect x="{bx}" y="{by + EDGE}" width="{bw}" height="{bh}" rx="{radius}" fill="#b9ab88"/>',
        '<g clip-path="url(#body)">',
        f'<rect x="{bx}" y="{by}" width="{bw}" height="{bh}" fill="url(#screen)"/>',
    ]
    for (x, y, rw, rh) in prompt_rects():
        parts.append(f'<rect x="{X(x):.3f}" y="{Y(y):.3f}" width="{L(rw):.3f}" height="{L(rh):.3f}" fill="#ffffff"/>')
    parts.append(f'<rect x="{bx}" y="{Y(BAND):.3f}" width="{bw}" height="{by + bh - Y(BAND):.3f}" fill="#e8ddc4"/>')
    for i in range(n):
        x = x0 + i * (w + gap)
        parts.append(f'<rect x="{X(x):.3f}" y="{Y(BAND + 60):.3f}" width="{L(w):.3f}" height="{L(110):.3f}" '
                     f'rx="{L(20):.3f}" fill="#d6402c"/>')
    for i in range(n - 1):
        x = x0 + i * (w + gap) + (w + gap) // 2
        parts.append(f'<rect x="{X(x):.3f}" y="{Y(BAND + 200):.3f}" width="{L(w):.3f}" height="{L(110):.3f}" '
                     f'rx="{L(20):.3f}" fill="#282624"/>')
    parts.append("</g>")
    # A faint highlight round the top edge.
    parts.append(f'<rect x="{bx + 0.5}" y="{by + 0.5}" width="{bw - 1}" height="{bh - 1}" rx="{radius - 0.5}" '
                 'fill="none" stroke="#ffffff" stroke-opacity="0.08"/>')
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def symbolic_icon():
    # 16x16: a rounded screen outline, the prompt and cursor inside it.
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">',
             '<path d="M3 1h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V3a2 2 0 0 1 2-2zm0 1.5a.5.5 0 0 0-.5.5v10'
             'a.5.5 0 0 0 .5.5h10a.5.5 0 0 0 .5-.5V3a.5.5 0 0 0-.5-.5z" fill="#222222"/>',
             # ">" as four steps, and the cursor.
             '<path d="M4 4h1v1h1v1h1v1H6v1H5v1H4V8h1V7h1V6H5V5H4z" fill="#222222"/>',
             '<rect x="8" y="10" width="4" height="1.5" fill="#222222"/>',
             "</svg>"]
    return "\n".join(parts) + "\n"


for folder, name, text in [("hicolor/scalable/apps", f"{APP}.svg", app_icon()),
                           ("hicolor/symbolic/apps", f"{APP}-symbolic.svg", symbolic_icon())]:
    path = os.path.join(out, folder)
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, name), "w") as f:
        f.write(text)
