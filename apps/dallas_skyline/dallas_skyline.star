"""
Dallas Skyline for Tronbyt/Tidbyt
=================================

Line-art skyline of downtown Dallas on the 64x32 display, as seen from
the southwest: one-pixel outlines on black, left to right

  Reunion Tower          geodesic ball on twin shafts, antenna on top
  Hyatt Regency          the low block beside it
  Bank of America Plaza  the tallest, notched top corners, drawn in its
                         argon green by default
  Renaissance Tower      crown of spires and the two X-braces
  Comerica Bank Tower    setback and barrel-vault cap
  Chase Tower            vaulted top with the keyhole cut through it
  Fountain Place         the glass prism, slanted top and a fold line

Options
  Line color             any color; the default is a soft white
  Bank of America green  outline that tower in green instead
  Draw-in animation      the skyline sketches itself in from left to
                         right over ~3 s, then holds
  Window lights          dim warm windows that slowly twinkle
  Label                  up to 6 characters top right, e.g. DALLAS

Rendering: everything is drawn into a 64x32 grid of color strings with
Bresenham lines and flushed as rows of render.Box runs. Each stroke is
a polyline, kept in drawing order so the draw-in animation reveals the
pixels the way a pen would lay them down.
"""

load("render.star", "render")
load("schema.star", "schema")

W = 64
H = 32
GROUND = 31

BLACK = "#000000"
DEFAULT_COLOR = "#e0e0e0"
ARGON_GREEN = "#2ee68a"  # Bank of America Plaza's argon outline
WINDOW = "#8a6f2a"  # dim warm window light

FRAME_MS = 80
DRAW_PX_PER_FRAME = 12  # draw-in speed (~3 s for the whole skyline)
HOLD_FRAMES = 120  # ~10 s hold after the draw-in / per loop of lights
LIGHT_STEP = 30  # frames between a window changing state (~2.4 s)

# Reunion Tower ball: 16 points of a radius-3 circle, clockwise from the top.
RING = [
    (0, -3),
    (1, -3),
    (2, -2),
    (3, -1),
    (3, 0),
    (3, 1),
    (2, 2),
    (1, 3),
    (0, 3),
    (-1, 3),
    (-2, 2),
    (-3, 1),
    (-3, 0),
    (-3, -1),
    (-2, -2),
    (-1, -3),
]

# The skyline as strokes: (tag, polyline points). Tag "boa" is the Bank of
# America Plaza; everything else is tag "". Order is drawing order.
STROKES = [
    # ground line
    ("", [(0, GROUND), (63, GROUND)]),

    # Reunion Tower: shafts, ball (filled in below), antenna
    ("", [(4, GROUND), (4, 22)]),
    ("", [(6, GROUND), (6, 22)]),
    ("ring", [(5, 18)]),
    ("", [(5, 14), (5, 13)]),

    # Hyatt Regency
    ("", [(10, GROUND), (10, 20), (13, 20), (13, GROUND)]),

    # Bank of America Plaza: notched top corners
    ("boa", [(15, GROUND), (15, 6), (16, 6), (16, 4), (23, 4), (23, 6), (24, 6), (24, GROUND)]),

    # Renaissance Tower: body, crown of spires, two X-braces
    ("", [(26, GROUND), (26, 5), (34, 5), (34, GROUND)]),
    ("", [(28, 4), (28, 3)]),
    ("", [(30, 4), (30, 1)]),
    ("", [(32, 4), (32, 3)]),
    ("", [(26, 7), (34, 15)]),
    ("", [(34, 7), (26, 15)]),
    ("", [(26, 15), (34, 23)]),
    ("", [(34, 15), (26, 23)]),

    # Comerica Bank Tower: setback and barrel vault
    ("", [(36, GROUND), (36, 13), (37, 13), (37, 10), (38, 9), (39, 8), (40, 8), (41, 9), (42, 10), (42, 13), (43, 13), (43, GROUND)]),

    # Chase Tower: vaulted top, keyhole
    ("", [(45, GROUND), (45, 12), (46, 11), (47, 10), (48, 9), (52, 9), (53, 10), (54, 11), (55, 12), (55, GROUND)]),
    ("", [(48, 12), (52, 12), (52, 17), (48, 17), (48, 12)]),

    # Fountain Place: wedge prism with a fold line
    ("", [(57, GROUND), (57, 16), (63, 10), (63, GROUND)]),
    ("", [(60, 13), (60, GROUND)]),
]

# Interiors that get window lights: (x0, y0, x1, y1) inclusive, inset from
# the outlines. Windows sit on every other row and column.
WINDOW_AREAS = [
    (11, 22, 12, 29),  # Hyatt
    (16, 6, 23, 29),  # Bank of America
    (27, 7, 33, 29),  # Renaissance
    (37, 12, 42, 29),  # Comerica
    (46, 12, 54, 29),  # Chase
    (58, 16, 62, 29),  # Fountain Place
]

# ---------------------------------------------------------------------------
# Geometry -> ordered pixel list
# ---------------------------------------------------------------------------

def line_points(x0, y0, x1, y1):
    """Bresenham line, points in order from (x0, y0) to (x1, y1)."""
    pts = []
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = 1 if x1 > x0 else -1
    sy = 1 if y1 > y0 else -1
    err = dx - dy
    x = x0
    y = y0
    for _ in range(dx + dy + 1):
        pts.append((x, y))
        if x == x1 and y == y1:
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            x += sx
        if e2 < dx:
            err += dx
            y += sy
    return pts

def skyline_pixels(line_color, boa_color):
    """All outline pixels as (x, y, color), in drawing order, no repeats."""
    out = []
    seen = {}
    for tag, pts in STROKES:
        color = boa_color if tag == "boa" else line_color
        if tag == "ring":
            cx, cy = pts[0]
            run = [(cx + dx, cy + dy) for dx, dy in RING]
        else:
            run = []
            for i in range(len(pts) - 1):
                seg = line_points(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1])
                if i > 0:
                    seg = seg[1:]  # corner pixel is already in the previous segment
                run.extend(seg)
        for x, y in run:
            key = y * W + x
            if key in seen:
                continue
            seen[key] = True
            out.append((x, y, color))
    return out

def window_pixels(outline):
    """Candidate window pixels: every other cell inside each tower, off the lines."""
    on_line = {}
    for x, y, _ in outline:
        on_line[y * W + x] = True
    hole = {}
    for y in range(13, 17):  # inside the Chase keyhole
        for x in range(49, 52):
            hole[y * W + x] = True
    wins = []
    for x0, y0, x1, y1 in WINDOW_AREAS:
        for y in range(y0, y1 + 1):
            if (y - y0) % 2 != 0:
                continue
            for x in range(x0, x1 + 1):
                if (x - x0) % 2 != 0:
                    continue
                key = y * W + x
                if key in on_line or key in hole:
                    continue
                wins.append((x, y))
    return wins

def window_lit(x, y, frame):
    """Deterministic twinkle: each window flips state every LIGHT_STEP frames
    on its own schedule; about three in four are lit at any moment."""
    phase = (x * 7 + y * 13) % LIGHT_STEP
    t = (frame + phase) // LIGHT_STEP
    h = (x * 73856093) ^ (y * 19349663) ^ (t * 83492791)
    return (h // 7) % 4 != 0

# ---------------------------------------------------------------------------
# Grid + flush
# ---------------------------------------------------------------------------

def new_grid():
    return [[""] * W for _ in range(H)]

def flush(g):
    """Grid -> Column of 32 single-pixel-high rows of Box runs."""
    rows = []
    for y in range(H):
        boxes = []
        run_c = g[y][0]
        run_n = 0
        for x in range(W):
            c = g[y][x]
            if c == run_c:
                run_n += 1
                continue
            boxes.append(render.Box(width = run_n, height = 1, color = run_c or BLACK))
            run_c = c
            run_n = 1
        boxes.append(render.Box(width = run_n, height = 1, color = run_c or BLACK))
        rows.append(render.Row(children = boxes))
    return render.Column(children = rows)

def frame_widget(outline, n_outline, windows, frame):
    """One frame: the first n_outline outline pixels plus the lit windows
    for this frame (windows is empty when lights are off)."""
    g = new_grid()
    for x, y in windows:
        if window_lit(x, y, frame):
            g[y][x] = WINDOW
    for i in range(n_outline):
        x, y, c = outline[i]
        g[y][x] = c
    return flush(g)

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

def main(config):
    line_color = config.str("color", DEFAULT_COLOR)
    boa_color = ARGON_GREEN if config.bool("boa_green", True) else line_color
    draw_in = config.bool("draw_in", True)
    lights = config.bool("lights", False)
    label = config.str("label", "").strip().upper()[:6]

    outline = skyline_pixels(line_color, boa_color)
    total = len(outline)
    windows = window_pixels(outline) if lights else []

    frames = []
    if draw_in:
        n = 0
        for _ in range(total // DRAW_PX_PER_FRAME + 2):
            if n >= total:
                break
            n = min(n + DRAW_PX_PER_FRAME, total)
            frames.append(frame_widget(outline, n, windows, len(frames)))
    if lights:
        start = len(frames)
        for i in range(HOLD_FRAMES):
            frames.append(frame_widget(outline, total, windows, start + i))
    elif draw_in:
        final = frame_widget(outline, total, windows, 0)
        for _ in range(HOLD_FRAMES):
            frames.append(final)
    else:
        frames.append(frame_widget(outline, total, windows, 0))

    if len(frames) == 1:
        art = frames[0]
    else:
        art = render.Animation(children = frames)

    layers = [art]
    if label:
        # tom-thumb is 4px per glyph; right-align in the clear sky top right
        layers.append(
            render.Padding(
                pad = (W - 4 * len(label), 1, 0, 0),
                child = render.Text(label, font = "tom-thumb", color = line_color, height = 5, offset = -1),
            ),
        )

    return render.Root(
        delay = FRAME_MS,
        child = render.Stack(children = layers),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Color(
                id = "color",
                name = "Line color",
                desc = "Color of the outlines.",
                icon = "palette",
                default = DEFAULT_COLOR,
            ),
            schema.Toggle(
                id = "boa_green",
                name = "Bank of America green",
                desc = "Outline Bank of America Plaza in its argon green.",
                icon = "building",
                default = True,
            ),
            schema.Toggle(
                id = "draw_in",
                name = "Draw-in animation",
                desc = "Sketch the skyline in from left to right, then hold.",
                icon = "pencil",
                default = True,
            ),
            schema.Toggle(
                id = "lights",
                name = "Window lights",
                desc = "Dim, slowly twinkling windows in the towers.",
                icon = "lightbulb",
                default = False,
            ),
            schema.Text(
                id = "label",
                name = "Label",
                desc = "Up to 6 characters shown top right, e.g. DALLAS. Leave blank for none.",
                icon = "font",
                default = "",
            ),
        ],
    )
