"""
Generates the Longhorn sprites embedded in mba_countdown.star.

    python3 sprite_gen.py > sprites.txt

Reads longhorn_src.png (the official silhouette, rasterized from the
PMS 159 EPS with the registered mark removed) and prints three base64
PNGs: the full-bleed 64x32 mark in burnt orange on black, the 26x13
header mark in burnt orange on black, and the same in white on burnt
orange for the band header. Edges are area-averaged, so the LEDs along
the outline dim toward the background instead of stair-stepping.
"""
import base64
import io

from PIL import Image

ORANGE = (191, 87, 0)  # #bf5700, UT burnt orange
WHITE = (255, 255, 255)
BLACK = (0, 0, 0)

SRC = Image.open("longhorn_src.png").convert("RGBA").split()[3]  # alpha = coverage


def sprite(w, h, fg, bg):
    cov = SRC.resize((w, h), Image.BOX).load()
    out = Image.new("RGB", (w, h), bg)
    px = out.load()
    for y in range(h):
        for x in range(w):
            v = cov[x, y] / 255.0
            px[x, y] = tuple(int(round(bg[i] + (fg[i] - bg[i]) * v)) for i in range(3))
    buf = io.BytesIO()
    out.save(buf, "PNG", optimize=True)
    return base64.b64encode(buf.getvalue()).decode()


if __name__ == "__main__":
    print('LONGHORN_64 = "%s"' % sprite(64, 32, ORANGE, BLACK))
    print('LONGHORN_26 = "%s"' % sprite(26, 13, ORANGE, BLACK))
    print('LONGHORN_26_WHITE = "%s"' % sprite(26, 13, WHITE, ORANGE))
