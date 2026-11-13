"""
Generates the 20x32 refinery sprite frames embedded in tceq_alerts.star.

    python3 sprite_gen.py

Prints three base64 PNG strings, one per flame frame, to paste into
SPRITE_FRAMES. Edit the BODY / FLAMES grids below to change the art.
Legend: . transparent, B blue outline, W white, G shade, Y yellow,
R red, O orange, L flame core, N navy windows.
"""
import base64
import io

from PIL import Image

PAL = {
    ".": None,
    "B": (30, 55, 210),     # outline blue
    "W": (244, 246, 255),   # white
    "G": (200, 206, 232),   # shade
    "Y": (255, 212, 0),     # yellow
    "R": (232, 32, 42),     # red
    "O": (255, 122, 0),     # orange
    "L": (255, 230, 90),    # flame core
    "N": (27, 58, 107),     # navy windows
}

BODY = [
"......BBB...........",  # r4
".....BWWGB..........",  # r5
".....BWWGB.....RLR..",  # r6  (flame base, overwritten per frame)
".....BWWGB.....BYB..",  # r7
".....BWWGB.....BYB..",  # r8
".....BYYYB....BBBBB.",  # r9
".....BYYYB.....B.B..",  # r10
".....BWWGB.....BBB..",  # r11
".BBB.BWWGB.....B.B..",  # r12
"BWWGBBWWGB.....BBB..",  # r13
"BWWGBBWWGB.....B.B..",  # r14
"BYYYBBWWGB.....BBB..",  # r15
"BWWGBBYYYB.....B.B..",  # r16
"BWWGBBYYYB.....BBB..",  # r17
"BWWGBBWWGB.....B.B..",  # r18
"BWWGBBWWGB....BBBBB.",  # r19
"BWWGBBWWGB...BBBBBBB",  # r20
"BWWGBBWWGB..BYYYYYYB",  # r21
"BWWGBBWWGB..BWWWWWGB",  # r22
"BWWGBBWWGB..BWWWWWGB",  # r23
"BWWGBBWWGB..BRRRRRRB",  # r24
"BWWGBBWWGB..BWWWWWGB",  # r25
"BBBBBBBBBBB.BWWWWWGB",  # r26
"BWNWNWNWNWB.BWWWWWGB",  # r27
"BWNWNWNWNWB.BWWWWWGB",  # r28
"BWWWWWWWWWB.BGGGGGGB",  # r29
"BBBBBBBBBBBBBBBBBBBB",  # r30
"....................",  # r31
]

FLAMES = [
 [  # frame 0: tall
"....................",  # r0
"................R...",  # r1
"...............RR...",  # r2
"...............ROR..",  # r3
"..............ROOOR.",  # r4 (cols 14-18 only; merged over BODY r4)
"..............ROLOR.",  # r5
"...............RLR..",  # r6
 ],
 [  # frame 1: leaning right
"....................",
"................RR..",
".................R..",
"...............ROR..",
"..............ROOR..",
"..............ROLOR.",
"...............RLR..",
 ],
 [  # frame 2: short, hot
"....................",
"....................",
"................R...",
"...............ROR..",
"..............ROLOR.",
"..............ROLOR.",
"...............RLR..",
 ],
]

W, H = 20, 32

def frame(i):
    grid = [["."]*W for _ in range(H)]
    for r, row in enumerate(BODY):
        for c, ch in enumerate(row):
            if ch != ".": grid[r+4][c] = ch
    for r, row in enumerate(FLAMES[i]):
        for c, ch in enumerate(row):
            if ch != ".": grid[r][c] = ch
    im = Image.new("RGBA", (W, H), (0,0,0,0))
    px = im.load()
    for r in range(H):
        for c in range(W):
            col = PAL[grid[r][c]]
            if col: px[c, r] = col + (255,)
    return im


if __name__ == "__main__":
    for i in range(3):
        buf = io.BytesIO()
        frame(i).save(buf, "PNG")
        print(base64.b64encode(buf.getvalue()).decode())
