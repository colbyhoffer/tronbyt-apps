"""
MBA Graduation Countdown for Tronbyt/Tidbyt
===========================================

Counts down the days to graduation on the 64x32 display, dressed up in
Texas McCombs colors. Two layouts:

Lockup (default)
  rows  0-12  pixel Longhorn silhouette (26x13) on the left, "TEXAS" /
              "McCOMBS" lockup on the right
  row   13    thin burnt-orange rule
  rows 14-26  the count, big: "174" in 6x13 with "DAYS" beside it
              (or "24W 6D" in weeks mode)
  rows 27-31  footer that alternates every few seconds between
              "UNTIL GRADUATION" and the date, "MAY 7, 2027"

Big Number
  rows  0-12  the same Longhorn + lockup header
  row   13    rule
  rows 14-31  the count in 10x20 with a three-line label column:
              DAYS / MAY 7 / 2027

If a program start date is set, the rule doubles as a progress bar:
the lit part is how far through the program you are.

On the day itself the count becomes TODAY! and the footer says
HOOK 'EM HORNS; afterwards it shows MBA / DONE with the class year.

The Longhorn is drawn from render.Box runs (like the Readwise mark), so
it follows the accent color. Days are counted as calendar days in the
device's timezone, so the number ticks over at midnight, not 24 h after
the first render.

Text sizing note: render.Text(height = h, offset = o) puts the baseline
at row h - descent - o, so e.g. tom-thumb caps fit exactly in 5 rows
with height = 5, offset = -1, and 6x13 digits in 9 rows with
height = 9, offset = -2.
"""

load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

DEFAULT_DATE = "2027-05-07"
DEFAULT_EVENT = "GRADUATION"
DEFAULT_LINE1 = "TEXAS"
DEFAULT_LINE2 = "McCOMBS"
DEFAULT_ACCENT = "#bf5700"  # UT burnt orange (PMS 159)
DEFAULT_TZ = "America/Chicago"

WHITE = "#ffffff"
DIM = "#9a9a9a"
TRACK = "#3a3a3a"  # unlit part of the progress rule
BLACK = "#000000"

FRAME_DELAY = 100  # ms per frame
HOLD = 25  # frames each footer line stays up (2.5 s)
SEP = " - "  # tom-thumb has no middle dot glyph

MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

# Pixel Longhorn silhouette, 26x13: "#" = accent, "." = off.
LONGHORN = [
    "#........................#",
    "##......................##",
    ".##....................##.",
    ".###.....########.....###.",
    "..####.############.####..",
    "...####################...",
    ".....################.....",
    "......##############......",
    "........##########........",
    "........##########........",
    ".........########.........",
    ".........########.........",
    "..........######..........",
]
LOGO_W = 26
LOGO_H = 13
HEADER_TEXT_W = 64 - LOGO_W - 2  # 1px gutter either side of the mark
RULE_W = 60

# ---------------------------------------------------------------------------
# Date math
# ---------------------------------------------------------------------------

def parse_date(s):
    """'YYYY-MM-DD' -> (y, m, d) or None."""
    parts = s.strip().split("-")
    if len(parts) != 3:
        return None
    for p in parts:
        if p == "" or not p.isdigit():
            return None
    y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
    if y < 2000 or m < 1 or m > 12 or d < 1 or d > 31:
        return None
    return (y, m, d)

def midnight(date, tz):
    return time.time(year = date[0], month = date[1], day = date[2], location = tz)

def days_between(a, b):
    """Whole calendar days from midnight a to midnight b. Rounds the hour
    difference so DST days (23/25 h) don't skew the count."""
    diff = b - a
    return int(math.floor((diff.hours + 12.0) / 24.0))

def date_label(target):
    return "%s %d, %d" % (MONTHS[target[1] - 1], target[2], target[0])

# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

def pixel_rows(grid, color):
    """Draw a '#'/'.' grid as rows of Box runs so it takes any color."""
    rows = []
    for line in grid:
        boxes = []
        run_char = ""
        run_len = 0
        for ch in line.elems():
            if ch == run_char:
                run_len += 1
                continue
            if run_len > 0:
                boxes.append(render.Box(width = run_len, height = 1, color = color if run_char == "#" else BLACK))
            run_char = ch
            run_len = 1
        if run_len > 0:
            boxes.append(render.Box(width = run_len, height = 1, color = color if run_char == "#" else BLACK))
        rows.append(render.Row(children = boxes))
    return render.Column(children = rows)

def tiny(text, color):
    """tom-thumb caps/digits in exactly 5 rows (descender row dropped)."""
    return render.Text(content = text, font = "tom-thumb", height = 5, offset = -1, color = color)

def small(text, color):
    """tb-8 caps in exactly 6 rows."""
    return render.Text(content = text, font = "tb-8", height = 6, offset = -1, color = color)

def header(accent, line1, line2):
    """Longhorn on the left, two-line school lockup centered on the right:
    5x8 (8 rows) over tom-thumb (5 rows) = the mark's 13 rows."""
    lockup = render.Column(
        cross_align = "center",
        children = [
            render.Text(content = line1, font = "5x8", color = accent),
            tiny(line2, WHITE),
        ],
    )
    return render.Row(
        children = [
            render.Box(width = 1, height = LOGO_H),
            pixel_rows(LONGHORN, accent),
            render.Box(width = 1, height = LOGO_H),
            render.Box(width = HEADER_TEXT_W, height = LOGO_H, child = lockup),
        ],
    )

def rule(accent, progress):
    """1px rule under the header. With a progress fraction it becomes a
    bar: lit from the left for the part of the program already done."""
    if progress == None:
        bar = [render.Box(width = RULE_W, height = 1, color = accent)]
    else:
        lit = int(math.round(RULE_W * progress))
        lit = max(0, min(RULE_W, lit))
        bar = []
        if lit > 0:
            bar.append(render.Box(width = lit, height = 1, color = accent))
        if lit < RULE_W:
            bar.append(render.Box(width = RULE_W - lit, height = 1, color = TRACK))
    return render.Row(children = [render.Box(width = 2, height = 1)] + bar + [render.Box(width = 2, height = 1)])

def count_lockup(big, unit, big_color):
    """13px count band: 6x13 number with a tb-8 unit on the same baseline."""
    kids = [render.Text(content = big, font = "6x13", color = big_color)]
    if unit != "":
        kids.append(render.Box(width = 2, height = 1))
        kids.append(render.Padding(pad = (0, 0, 0, 1), child = render.Text(content = unit, font = "tb-8", color = DIM)))
    return render.Box(
        width = 64,
        height = 13,
        child = render.Row(main_align = "center", cross_align = "end", children = kids),
    )

def footer(text, color):
    return render.Box(width = 64, height = 5, child = tiny(text, color))

def footer_marquee(text, color):
    return render.Box(
        width = 64,
        height = 5,
        child = render.Marquee(width = 64, child = tiny(text, color), offset_start = 64, offset_end = 64),
    )

def count_big(big, labels, big_color, accent):
    """18px band: 10x20 digits trimmed to their 13 rows, with a three-line
    label column (tb-8 + two tom-thumb lines) hung off the same baseline."""
    number = render.Text(content = big, font = "10x20", height = 13, offset = -4, color = big_color)
    kids = [number]
    if len(labels) > 0:
        lines = [small(labels[0], accent)]
        for s in labels[1:]:
            lines.append(render.Box(width = 1, height = 1))
            lines.append(tiny(s, DIM))
        kids.append(render.Box(width = 3, height = 1))
        kids.append(render.Column(children = lines))
    return render.Box(
        width = 64,
        height = 18,
        child = render.Row(main_align = "center", cross_align = "end", children = kids),
    )

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    accent = config.str("accent", DEFAULT_ACCENT)
    layout = config.str("layout", "lockup")
    line1 = config.str("line1", DEFAULT_LINE1).strip() or DEFAULT_LINE1
    line2 = config.str("line2", DEFAULT_LINE2).strip() or DEFAULT_LINE2
    event = (config.str("event", DEFAULT_EVENT).strip() or DEFAULT_EVENT).upper()
    unit = config.str("unit", "days")
    tz = config.get("$tz") or DEFAULT_TZ

    target = parse_date(config.str("date", DEFAULT_DATE))
    if target == None:
        target = parse_date(DEFAULT_DATE)
    start = parse_date(config.str("start", ""))

    now = time.now().in_location(tz)
    today = midnight((now.year, now.month, now.day), tz)
    goal = midnight(target, tz)
    days = days_between(today, goal)
    when = date_label(target)
    month_day = "%s %d" % (MONTHS[target[1] - 1], target[2])
    year = str(target[0])

    progress = None
    if start != None:
        total = days_between(midnight(start, tz), goal)
        if total > 0:
            progress = max(0.0, min(1.0, float(total - days) / float(total)))

    # What the count band says, per state. "labels" is the big layout's
    # three-line column; "lines" is the lockup footer's alternation.
    if days > 0:
        big_color = WHITE
        lines = ["UNTIL " + event, when]
        if unit == "weeks" and days >= 7:
            big = "%dW %dD" % (days // 7, days % 7)
            unit_text = ""
            big_num = str(days // 7)
            labels = ["WEEKS", "%d DAYS" % (days % 7), "TO GO"]
        else:
            big = str(days)
            unit_text = "DAY" if days == 1 else "DAYS"
            big_num = big
            labels = [unit_text, month_day, year]
    elif days == 0:
        big_color = accent
        big, unit_text = "TODAY!", ""
        big_num, labels = "TODAY", []
        lines = ["HOOK 'EM HORNS", event + " DAY"]
    else:
        big_color = accent
        big, unit_text = "MBA", "DONE"
        big_num, labels = "DONE", ["MBA", month_day, year]
        lines = ["CLASS OF " + year, "HOOK 'EM HORNS"]

    top = [header(accent, line1, line2), rule(accent, progress)]

    if layout == "big":
        return render.Root(
            child = render.Column(children = top + [count_big(big_num, labels, big_color, accent)]),
        )

    footer_color = accent if days <= 0 else DIM
    fits = True
    for s in lines:
        if len(s) * 4 - 1 > 64:
            fits = False
    if not fits:
        body = top + [count_lockup(big, unit_text, big_color), footer_marquee(SEP.join(lines), footer_color)]
        return render.Root(delay = FRAME_DELAY, child = render.Column(children = body))

    frames = []
    for s in lines:
        screen = render.Column(children = top + [count_lockup(big, unit_text, big_color), footer(s, footer_color)])
        for _ in range(HOLD):
            frames.append(screen)
    return render.Root(delay = FRAME_DELAY, child = render.Animation(children = frames))

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "date",
                name = "Graduation Date",
                desc = "YYYY-MM-DD",
                icon = "calendarDay",
                default = DEFAULT_DATE,
            ),
            schema.Dropdown(
                id = "layout",
                name = "Layout",
                desc = "How to arrange the screen",
                icon = "tableColumns",
                default = "lockup",
                options = [
                    schema.Option(display = "Lockup (count + footer)", value = "lockup"),
                    schema.Option(display = "Big Number", value = "big"),
                ],
            ),
            schema.Text(
                id = "event",
                name = "Event",
                desc = "Shown as UNTIL <event> in the Lockup footer",
                icon = "graduationCap",
                default = DEFAULT_EVENT,
            ),
            schema.Dropdown(
                id = "unit",
                name = "Count In",
                desc = "How to show the time left",
                icon = "stopwatch",
                default = "days",
                options = [
                    schema.Option(display = "Days", value = "days"),
                    schema.Option(display = "Weeks and days", value = "weeks"),
                ],
            ),
            schema.Text(
                id = "start",
                name = "Program Start",
                desc = "YYYY-MM-DD; when set, the rule under the header fills up as a progress bar",
                icon = "flagCheckered",
                default = "",
            ),
            schema.Text(
                id = "line1",
                name = "Header Line 1",
                desc = "Big line next to the Longhorn",
                icon = "font",
                default = DEFAULT_LINE1,
            ),
            schema.Text(
                id = "line2",
                name = "Header Line 2",
                desc = "Small line under it",
                icon = "font",
                default = DEFAULT_LINE2,
            ),
            schema.Color(
                id = "accent",
                name = "Accent Color",
                desc = "Longhorn, header and rule color",
                icon = "brush",
                default = DEFAULT_ACCENT,
            ),
        ],
    )
