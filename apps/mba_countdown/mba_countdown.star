"""
MBA Graduation Countdown for Tronbyt/Tidbyt
===========================================

Counts down the days to graduation on the 64x32 display, dressed up in
Texas McCombs colors:

  rows  0-12  header: pixel Longhorn silhouette (26x13) on the left,
              "TEXAS" / "McCOMBS" lockup on the right
  row   13    thin burnt-orange rule
  rows 14-26  the count, big: "174" in 6x13 with "DAYS" beside it
              (or "24W 6D" in weeks mode)
  rows 27-31  footer that alternates every few seconds between
              "UNTIL GRADUATION" and the date, "MAY 7, 2027"

On the day itself the count becomes "TODAY!" and the footer says
HOOK 'EM HORNS; afterwards it shows MBA / DONE with the class year.

The Longhorn is drawn from render.Box runs (like the Readwise mark), so
it follows the accent color. Days are counted as calendar days in the
device's timezone, so the number ticks over at midnight, not 24 h after
the first render.
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

def days_until(target, tz):
    """Whole calendar days from today (in tz) to the target date. Rounds
    the hour difference so DST days (23/25 h) don't skew the count."""
    now = time.now().in_location(tz)
    today = time.time(year = now.year, month = now.month, day = now.day, location = tz)
    goal = time.time(year = target[0], month = target[1], day = target[2], location = tz)
    diff = goal - today
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

def header(accent, line1, line2):
    """Longhorn on the left, two-line school lockup centered on the right.
    The Box clips tom-thumb's descender row so the block stays 13px."""
    lockup = render.Column(
        cross_align = "center",
        children = [
            render.Text(content = line1, font = "5x8", color = accent),
            render.Text(content = line2, font = "tom-thumb", color = WHITE),
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

def rule(accent):
    return render.Row(
        children = [
            render.Box(width = 2, height = 1),
            render.Box(width = 60, height = 1, color = accent),
            render.Box(width = 2, height = 1),
        ],
    )

def count_line(big, small, big_color):
    """The 13px count band: a 6x13 number with a tb-8 unit hung off its
    baseline (6x13 has a 2px descent, tb-8 1px, hence the 1px pad)."""
    kids = [render.Text(content = big, font = "6x13", color = big_color)]
    if small != "":
        kids.append(render.Box(width = 2, height = 1))
        kids.append(render.Padding(
            pad = (0, 0, 0, 1),
            child = render.Text(content = small, font = "tb-8", color = DIM),
        ))
    return render.Box(
        width = 64,
        height = 13,
        child = render.Row(main_align = "center", cross_align = "end", children = kids),
    )

def footer_text(text, color):
    return render.Text(content = text, font = "tom-thumb", color = color)

def footer_frames(lines, color):
    """One footer per frame. Two short lines alternate with a hold;
    anything too wide for 64px (tom-thumb is 4px/char) scrolls instead.
    The footer is 6px (tom-thumb's descender row) and the Root clips
    that last row, so caps and digits sit flush with the bottom edge."""
    fits = True
    for s in lines:
        if len(s) * 4 - 1 > 64:
            fits = False
    if not fits:
        marquee = render.Marquee(
            width = 64,
            child = footer_text(SEP.join(lines), color),
            offset_start = 64,
            offset_end = 64,
        )
        return [marquee]
    frames = []
    for s in lines:
        box = render.Box(width = 64, height = 6, child = footer_text(s, color))
        for _ in range(HOLD):
            frames.append(box)
    return frames

def screen(accent, line1, line2, big, small, big_color, footer):
    return render.Column(
        children = [
            header(accent, line1, line2),
            rule(accent),
            count_line(big, small, big_color),
            footer,
        ],
    )

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    accent = config.str("accent", DEFAULT_ACCENT)
    line1 = config.str("line1", DEFAULT_LINE1).strip() or DEFAULT_LINE1
    line2 = config.str("line2", DEFAULT_LINE2).strip() or DEFAULT_LINE2
    event = (config.str("event", DEFAULT_EVENT).strip() or DEFAULT_EVENT).upper()
    unit = config.str("unit", "days")
    tz = config.get("$tz") or DEFAULT_TZ

    target = parse_date(config.str("date", DEFAULT_DATE))
    if target == None:
        target = parse_date(DEFAULT_DATE)
    days = days_until(target, tz)
    when = date_label(target)

    if days > 0:
        if unit == "weeks" and days >= 7:
            big = "%dW %dD" % (days // 7, days % 7)
            small = ""
        else:
            big = str(days)
            small = "DAY" if days == 1 else "DAYS"
        big_color = WHITE
        lines = ["UNTIL " + event, when]
    elif days == 0:
        big, small, big_color = "TODAY!", "", accent
        lines = ["HOOK 'EM HORNS", event + " DAY"]
    else:
        big, small, big_color = "MBA", "DONE", accent
        lines = ["CLASS OF %d" % target[0], "HOOK 'EM HORNS"]

    frames = footer_frames(lines, accent if days <= 0 else DIM)
    if len(frames) == 1:
        footer = frames[0]
    else:
        footer = render.Animation(children = frames)

    return render.Root(
        delay = FRAME_DELAY,
        child = screen(accent, line1, line2, big, small, big_color, footer),
    )

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
            schema.Text(
                id = "event",
                name = "Event",
                desc = "Shown as UNTIL <event> in the footer",
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
