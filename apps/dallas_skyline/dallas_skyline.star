"""
Dallas Skyline for Tronbyt/Tidbyt
=================================

Line-art skyline of downtown Dallas on the 64x32 display, as seen from
the southwest: one-pixel outlines on black, left to right

  Margaret Hunt Hill Bridge  arch, crossed cables, deck on piers
  Reunion Tower          geodesic ball on twin shafts, antenna on top
  Bank of America Plaza  the tallest, notched top corners, drawn in its
                         argon green by default
  Renaissance Tower      crown of spires and the two X-braces
  Comerica Bank Tower    two setbacks under a barrel-vault cap
  Chase Tower            vaulted top with the keyhole cut through it
  Fountain Place         the glass prism, slanted top and a fold line

Options
  Bridge                 on by default; off swaps it for the Hyatt Regency
                         (stepped slab beside Reunion) and widens Bank of
                         America and Chase by a column each
  Line color             any color; the default is a soft white
  Bank of America green  outline that tower in green instead
  Draw-in animation      the skyline sketches itself in from left to
                         right over ~3 s, then holds
  Window lights          dim warm windows that slowly twinkle
  Label                  up to 6 characters top right, e.g. DALLAS

Rendering: each building is a small builder that returns its strokes
(polylines) for a given left edge; layout() places them. Everything is
drawn into a 64x32 grid of color strings with Bresenham lines and
flushed as rows of render.Box runs. Strokes stay in drawing order so the
draw-in animation reveals the pixels the way a pen would lay them down.
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

# ---------------------------------------------------------------------------
# Buildings
#
# Each builder takes the x of its left edge and returns a dict with
#   strokes  list of (tag, polyline) in drawing order; tag "boa" is the
#            Bank of America Plaza, "ring" is Reunion's ball
#   windows  (x0, y0, x1, y1) interiors that get window lights
#   hole     interior of the Chase keyhole, kept dark
# The two layouts below place them.
# ---------------------------------------------------------------------------

def bridge(x):
    """Margaret Hunt Hill Bridge, 9 wide: deck, arch, crossed cables, piers."""
    return dict(
        strokes = [
            ("", [(x, 27), (x + 8, 27)]),
            ("", [(x, 27), (x, 24), (x + 1, 23), (x + 1, 21), (x + 2, 20), (x + 2, 19), (x + 3, 18), (x + 4, 17), (x + 5, 18), (x + 6, 19), (x + 6, 20), (x + 7, 21), (x + 7, 23), (x + 8, 24), (x + 8, 27)]),
            ("", [(x + 2, 20), (x + 6, 26)]),
            ("", [(x + 6, 20), (x + 2, 26)]),
            ("", [(x, 28), (x, 30)]),
            ("", [(x + 8, 28), (x + 8, 30)]),
        ],
        windows = [],
    )

def reunion(x):
    """Reunion Tower, 7 wide: twin shafts, ball, antenna."""
    c = x + 3
    return dict(
        strokes = [
            ("", [(c - 1, GROUND), (c - 1, 22)]),
            ("", [(c + 1, GROUND), (c + 1, 22)]),
            ("ring", [(c, 18)]),
            ("", [(c, 14), (c, 13)]),
        ],
        windows = [],
    )

def hyatt(x):
    """Hyatt Regency, 4 wide: stepped slab, taller half toward Reunion."""
    return dict(
        strokes = [("", [(x, GROUND), (x, 18), (x + 1, 18), (x + 1, 21), (x + 3, 21), (x + 3, GROUND)])],
        windows = [(x + 1, 22, x + 2, 29)],
    )

def boa(x, w):
    """Bank of America Plaza, w wide: the tallest, notched top corners."""
    r = x + w - 1
    return dict(
        strokes = [("boa", [(x, GROUND), (x, 6), (x + 1, 6), (x + 1, 4), (r - 1, 4), (r - 1, 6), (r, 6), (r, GROUND)])],
        windows = [(x + 1, 6, r - 1, 29)],
    )

def renaissance(x):
    """Renaissance Tower, 9 wide: body, crown of spires, two X-braces."""
    r = x + 8
    c = x + 4
    return dict(
        strokes = [
            ("", [(x, GROUND), (x, 5), (r, 5), (r, GROUND)]),
            ("", [(c - 2, 4), (c - 2, 3)]),
            ("", [(c, 4), (c, 1)]),
            ("", [(c + 2, 4), (c + 2, 3)]),
            ("", [(x, 7), (r, 15)]),
            ("", [(r, 7), (x, 15)]),
            ("", [(x, 15), (r, 23)]),
            ("", [(r, 15), (x, 23)]),
        ],
        windows = [(x + 1, 7, r - 1, 29)],
    )

def comerica(x):
    """Comerica Bank Tower, 8 wide: two setbacks under a barrel vault."""
    return dict(
        strokes = [("", [
            (x, GROUND),
            (x, 15),
            (x + 1, 15),
            (x + 1, 12),
            (x + 2, 12),
            (x + 2, 10),
            (x + 3, 9),
            (x + 3, 8),
            (x + 4, 8),
            (x + 4, 9),
            (x + 5, 10),
            (x + 5, 12),
            (x + 6, 12),
            (x + 6, 15),
            (x + 7, 15),
            (x + 7, GROUND),
        ])],
        windows = [(x + 1, 12, x + 6, 29)],
    )

def chase(x, w):
    """Chase Tower, 10 or 11 wide: vaulted top with the keyhole through it."""
    r = x + w - 1
    hx0 = x + 3
    hx1 = r - 3
    return dict(
        strokes = [
            ("", [(x, GROUND), (x, 12), (x + 1, 11), (x + 2, 10), (x + 3, 9), (r - 3, 9), (r - 2, 10), (r - 1, 11), (r, 12), (r, GROUND)]),
            ("", [(hx0, 12), (hx1, 12), (hx1, 17), (hx0, 17), (hx0, 12)]),
        ],
        windows = [(x + 1, 12, r - 1, 29)],
        hole = (hx0 + 1, 13, hx1 - 1, 16),
    )

def fountain(x):
    """Fountain Place, 7 wide: wedge prism with a fold line."""
    return dict(
        strokes = [
            ("", [(x, GROUND), (x, 16), (x + 6, 10), (x + 6, GROUND)]),
            ("", [(x + 3, 13), (x + 3, GROUND)]),
        ],
        windows = [(x + 1, 16, x + 5, 29)],
    )

def layout(with_bridge):
    """The skyline left to right. With the bridge, Bank of America and Chase
    give up a column each and the Hyatt steps aside to make room for it."""
    if with_bridge:
        parts = [bridge(0), reunion(10), boa(18, 8), renaissance(27), comerica(37), chase(46, 10), fountain(57)]
    else:
        parts = [reunion(2), hyatt(10), boa(15, 10), renaissance(26), comerica(36), chase(45, 11), fountain(57)]
    strokes = [("", [(0, GROUND), (63, GROUND)])]
    windows = []
    hole = None
    for part in parts:
        strokes.extend(part["strokes"])
        windows.extend(part["windows"])
        if "hole" in part:
            hole = part["hole"]
    return strokes, windows, hole

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

def skyline_pixels(strokes, line_color, boa_color):
    """All outline pixels as (x, y, color), in drawing order, no repeats."""
    out = []
    seen = {}
    for tag, pts in strokes:
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

def window_pixels(outline, areas, hole):
    """Candidate window pixels: every other cell inside each tower, off the lines."""
    on_line = {}
    for x, y, _ in outline:
        on_line[y * W + x] = True
    dark = {}
    if hole:
        for y in range(hole[1], hole[3] + 1):
            for x in range(hole[0], hole[2] + 1):
                dark[y * W + x] = True
    wins = []
    for x0, y0, x1, y1 in areas:
        for y in range(y0, y1 + 1):
            if (y - y0) % 2 != 0:
                continue
            for x in range(x0, x1 + 1):
                if (x - x0) % 2 != 0:
                    continue
                key = y * W + x
                if key in on_line or key in dark:
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

    strokes, areas, hole = layout(config.bool("bridge", True))
    outline = skyline_pixels(strokes, line_color, boa_color)
    total = len(outline)
    windows = window_pixels(outline, areas, hole) if lights else []

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
                id = "bridge",
                name = "Margaret Hunt Hill Bridge",
                desc = "Show the bridge left of Reunion Tower. Off puts the Hyatt Regency back in its place.",
                icon = "archway",
                default = True,
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
