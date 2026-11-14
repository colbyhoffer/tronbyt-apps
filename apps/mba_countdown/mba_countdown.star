"""
MBA Graduation Countdown for Tronbyt/Tidbyt
===========================================

Counts down the days to graduation on the 64x32 display in Texas
McCombs colors. The Longhorn is the official silhouette, rasterized
from the PMS 159 vector by sprite_gen.py with area-averaged edges, so
the LEDs along the outline fade instead of stair-stepping.

Layouts
  Hero (default)
    The Longhorn fills the whole panel, horn tips in the top corners.
    The count sits in the open space left of the face (6x13 digits over
    a tom-thumb unit), the date and MBA label to the right. If a
    program start is set, a 25px progress bar runs under the count.
  Lockup
    16-row header (Longhorn 32x16 + TEXAS / McCOMBS), 1px rule, 6x13
    count trimmed to 9 rows with its unit on the baseline, and a 5px
    footer alternating between UNTIL GRADUATION and the date every 2.5 s.
  Big Number
    Same header, then the count in 10x20 trimmed to its 13 glyph rows
    with a two-line label column: DAYS / MAY 7.

Header style (Lockup and Big Number)
  Band: white Longhorn and lockup on a burnt-orange band
  Line: burnt-orange Longhorn and TEXAS on black, white McCOMBS, with
        a burnt-orange rule under it
  With a program start the rule row becomes a progress bar.

States: on the day the count reads TODAY! / GRAD DAY!; afterwards
MBA DONE with the class year.

Days are counted as calendar days in the device's timezone, so the
number ticks over at midnight.

Text sizing note: render.Text(height = h, offset = o) puts the baseline
at row h - descent - o, so tom-thumb caps fit exactly in 5 rows with
height = 5, offset = -1, 6x13 digits in 9 rows with height = 9,
offset = -2, and 10x20 digits in 13 rows with height = 13, offset = -4.
"""

load("encoding/base64.star", "base64")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

DEFAULT_DATE = "2027-05-07"
DEFAULT_EVENT = "GRADUATION"
DEFAULT_LINE1 = "TEXAS"
DEFAULT_LINE2 = "McCOMBS"
DEFAULT_TZ = "America/Chicago"

ORANGE = "#bf5700"  # UT burnt orange (PMS 159); the sprites are baked in it
WHITE = "#ffffff"
DIM = "#9a9a9a"
TRACK = "#3a3a3a"  # unlit part of a progress bar
BLACK = "#000000"

FRAME_DELAY = 100  # ms per frame
HOLD = 25  # frames each footer line stays up (2.5 s)
SEP = " - "  # tom-thumb has no middle dot glyph

MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

# Base64 PNG sprites from sprite_gen.py. Regenerate there, don't hand-edit.
LONGHORN_64 = "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAgCAIAAAAt/+nTAAADlUlEQVR42tWYX2xTdRTHP7/ert2Vjo216cZAJwSZOmRYh4jyosTE8KAh+ESI8UHFF18kvuir8cXgiy8uJsYYY6JEUROXJSiYaDKROVZhwujs6ICyP23XbaV/7u291wdu7Fxut/Z6t3Xn7ff7nXN6vuec37nf/sSJbg5spdELcEfl5jwjKQYnuTBBrkiNiOxmbyuhFjqa2drAhjqA2QK/3ER8eJBGL6qGz4NfRhKmTa7Ir7f4fpTLibUMfVeA53dwYAuy29zRDJI5Mgp1ErMFxELtejePBDjYztP34pHMzcFJPv6Tq6nVDv3BZl7dTajFXCoa527wU4xLCfILWkNYGvtlXt7FoW24BIBhcCZGT5hUfjVC98u8tptn2xECQDfoHePTyyRzFspiCUfbm3izm06/ubyj8sklvhtFM1YqdK/EkZ0cfcjscmA4yQcDRNNlTcTSHiXBS50ce9gsBTA+x0dh+uPOR7+/jTceZbPPXOoGn//FZ8PL5EtU4rq7lbf3sam+tHP+Nj1hxmYXa2700NGMXyaaxiOZJqk8qsb2JlJ5riaZUxZbbWvkeBf7Npd2ZvK8d56BieVjExWmJyDzzhPsCZZ2dIPwFH9MEc9QKOLz0Bngmfvw1S3lJ6NydpzhBBkFr5s2H48F6QqWKgwMTfHub9Ydbx/A3XY63sWLHdXYVCmDk1yc4osr6BVfM2FjML++p3SzHZThJG/9XPXX0042Bexv4/ADhFr+U3p7ohsMTnI6Qn8cG+PNZeMnDRiapj+OqjuQeFWnP87QNPaGs50EntjLc/fjdjnZP0WdvuucvLDyFZAEoaBF9EaVNVwkbhehoJ2GlGz0z48xigbtG6l3oxtE0nw5Qk+YF3ZU6uSVPm5laPKyqR4hSBc4dY33fyevrUoL/VuKZpmMYs4Nr0TvkYpSqBsc+pqCZvJkn4dUzj49sd/ImsF0tjT1Chp/pysyHE2b0d8l7dPZ/0WunLyJZ8edVFsDAD9EyarL6GRVeqO1CmBe4XRkGZ1vIswrtQoA+GqEbHkukC1yasRhAuIwgDmFvrGyp31RCy5dWwCAM9fLH8Wcp4DOA4jMWHdRtsi1mfUAQDPIWPVJRqmC5a8lgAYPAdn6raHBsx4APLXFmlBIgifb1gOAx1vLHi382167ABI5O0e1NEZj63yMRtPW7zkDE0s9sNln9Y57NODcDdwuWjdwTx1AIsu3o5wcWJE3yX8AfCM+Ep86GikAAAAASUVORK5CYII="
LONGHORN_32 = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAABtUlEQVR42q2UTUtbURCGn3OT1IARQzGFxC9U/FqkVKhZSKUI2QhCBXFhf4Cbbm3/RLssLgS3EaSLFgQLLQnSEsEsis0iGlFJr9cIio0m0iTm5nQRSjDmXm8lszvzvjPvzJk5RywG8bkQguQ53zW+pri65t7W7CDYzbN2Bh4iJcc5RAVwNzHRxdwQTjuhBB+SlMr/l9qhMDPAy2HyJVZ2iPwiUwD+CVTMaWf+MdP9qJe8/0HsxGr2MR+vRvC6+LjH0k/ypSokbrPHO3gTwOVgK82nfbQsrU0876TlAVICCEG2yIbKRYH2Fl70EfCSLfI2xrej2myibkXeZl4HGHlktYPPhyzHOftTBxImYZM9LIyimFEoS97FWD80JNiMgKk+Fp7ekb1yXWM+0lfsZwwIRpF2hYlOet3Ez3jiYXawlrC6y/Yp/jYOMkRUw62zGwmUynxJQQrAJuoIxE+JakS1O1pUrMwwqpHO3fCkc2weW5q/JQFdEkrc8IQS6LJxAkBYpSyrmxNWrW6wVYGiXi1ZlxT1Rgv4PTiU6rfj9zRaIFswO5qYzSLvdx63k95WdMnagdnTrbG/SLeK/CQrNvIAAAAASUVORK5CYII="
LONGHORN_32_WHITE = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAIAAAD4YuoOAAAB7klEQVR42mP8ePsEp7gyAwPjlwfn3pze8PLI0j/fPjKQC1i4+MVtokVMA3gUjBgY/n9/eZdxfzgDAwMDK5+omGW4nH85Mzv3ww3tT7dP/PfnF0lGM7GyS3vkyQdU/v359dHGzlfHV/7+9JqBgQFqAQQws3MrRXVIu2V/e37zzsKCdxd3Emm6sLGvSlw/p5jS011T7y2r+PvzK1wKxQIIEDULUk+fy8It8O7ijme7pn97cZuVV0TMIpSFW5CB4T9E15+v71+dWP378xsuCVUpt0whfY8/X9/fnJny+tQ6NNOwWMDAwMAhpqiRPldA25FIH7w4uOD+ypqf755iSmG3AAIkHBLV02YzMjHjMfr/v783Z6W+ODAfZ9zgkpByTlNPn4PfdAYGBkYmZvX0ORJ2cTjTFS6J5wfm//31jVtW99PNo/xa9rLeRWgKHm/p/Xj9EJ+69dfHl18dW0myBf///n55eAnMn8yYFny8eeTN2U1vzm4ikHyJicO35zZ/f3UPWeT7q3tvz20hKn8Qo+j/3z+PNnYgizza2PH/7x+qWcDAwPD62Mr///7CU85r3IFOpgV/f32HO/n/3z9/f32nsgUCGrZMrOzwYkdAw5bKFvz++g4PlwoWfHl48emuaf9+//j3+8fTXdO+PLxIpEYAttPTXedmbHUAAAAASUVORK5CYII="
LOGO_W = 32
LOGO_H = 16
HEADER_TEXT_W = 64 - LOGO_W - 2  # 1px gutter either side of the mark
RULE_W = 60

# Open space around the 64x32 Longhorn: the face spans cols 25-38 from
# row 15 down, so text lives in cols 0-24 and 40-63 below the horns.
HERO_TEXT_Y = 15
HERO_LEFT_W = 25
HERO_RIGHT_X = 40
HERO_RIGHT_W = 24

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

def img(b64):
    return render.Image(src = base64.decode(b64))

def tiny(text, color):
    """tom-thumb caps/digits in exactly 5 rows (descender row dropped)."""
    return render.Text(content = text, font = "tom-thumb", height = 5, offset = -1, color = color)

def small(text, color):
    """tb-8 caps in exactly 6 rows."""
    return render.Text(content = text, font = "tb-8", height = 6, offset = -1, color = color)

def digits9(text, color):
    """6x13 digits/caps in exactly 9 rows."""
    return render.Text(content = text, font = "6x13", height = 9, offset = -2, color = color)

def at(x, y, child):
    return render.Padding(pad = (x, y, 0, 0), child = child)

def progress_bar(width, progress, lit_color):
    lit = max(0, min(width, int(math.round(width * progress))))
    kids = []
    if lit > 0:
        kids.append(render.Box(width = lit, height = 1, color = lit_color))
    if lit < width:
        kids.append(render.Box(width = width - lit, height = 1, color = TRACK))
    return render.Row(children = kids)

def header(style, line1, line2, progress):
    """16-row header plus the 1-row rule under it (17 rows total). The
    13-row lockup (5x8 over tom-thumb) is centered in the mark's height."""
    if style == "band":
        mark, c1, c2, bg = LONGHORN_32_WHITE, WHITE, WHITE, ORANGE
    else:
        mark, c1, c2, bg = LONGHORN_32, ORANGE, WHITE, BLACK
    lockup = render.Column(
        cross_align = "center",
        children = [
            render.Text(content = line1, font = "5x8", color = c1),
            tiny(line2, c2),
        ],
    )
    top = render.Box(
        width = 64,
        height = LOGO_H,
        color = bg,
        child = render.Row(
            children = [
                render.Box(width = 1, height = LOGO_H),
                img(mark),
                render.Box(width = 1, height = LOGO_H),
                render.Box(width = HEADER_TEXT_W, height = LOGO_H, child = lockup),
            ],
        ),
    )
    if progress != None:
        bar = progress_bar(RULE_W, progress, ORANGE)
    elif style == "band":
        bar = render.Box(width = RULE_W, height = 1)
    else:
        bar = render.Box(width = RULE_W, height = 1, color = ORANGE)
    rule = render.Row(children = [render.Box(width = 2, height = 1), bar, render.Box(width = 2, height = 1)])
    return render.Column(children = [top, rule])

def count_lockup(big, unit, big_color):
    """10px count band: 6x13 digits trimmed to their 9 rows with a tb-8
    unit (6 rows) on the same baseline, one blank row above."""
    kids = [digits9(big, big_color)]
    if unit != "":
        kids.append(render.Box(width = 2, height = 1))
        kids.append(small(unit, DIM))
    return render.Box(
        width = 64,
        height = 10,
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

def count_big(big, labels, big_color):
    """15px band: 10x20 digits trimmed to their 13 rows, with a two-line
    label column (tb-8 over tom-thumb) hung off the same baseline."""
    number = render.Text(content = big, font = "10x20", height = 13, offset = -4, color = big_color)
    kids = [number]
    if len(labels) > 0:
        lines = [small(labels[0], ORANGE)]
        for s in labels[1:]:
            lines.append(render.Box(width = 1, height = 1))
            lines.append(tiny(s, DIM))
        kids.append(render.Box(width = 3, height = 1))
        kids.append(render.Column(children = lines))
    return render.Box(
        width = 64,
        height = 15,
        child = render.Row(main_align = "center", cross_align = "end", children = kids),
    )

def hero(big, sub, big_color, right, progress):
    """Full-bleed Longhorn with the count left of the face and three small
    lines right of it. Both blocks start at row 15, under the horns."""
    left = render.Column(
        cross_align = "center",
        children = [digits9(big, big_color), render.Box(width = 1, height = 2), tiny(sub, DIM)],
    )
    right_lines = []
    for i in range(len(right)):
        if i > 0:
            right_lines.append(render.Box(width = 1, height = 1))
        right_lines.append(tiny(right[i], WHITE if i < 2 else DIM))
    layers = [
        img(LONGHORN_64),
        at(0, HERO_TEXT_Y, render.Box(width = HERO_LEFT_W, height = 16, child = left)),
        at(HERO_RIGHT_X, HERO_TEXT_Y, render.Box(width = HERO_RIGHT_W, height = 17, child = render.Column(cross_align = "center", children = right_lines))),
    ]
    if progress != None:
        layers.append(at(0, 31, progress_bar(HERO_LEFT_W, progress, ORANGE)))
    return render.Stack(children = layers)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    layout = config.str("layout", "hero")
    style = config.str("header", "band")
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

    # Copy per state. big/unit_text: lockup band. big_num/labels: big
    # layout. hero_big/hero_sub/hero_right: hero blocks. lines: footer.
    if days > 0:
        big_color = WHITE
        lines = ["UNTIL " + event, when]
        hero_right = [month_day, year, "MBA"]
        if unit == "weeks" and days >= 7:
            big, unit_text = "%dW %dD" % (days // 7, days % 7), ""
            big_num, labels = str(days // 7), ["WEEKS", "%d DAYS" % (days % 7)]
            hero_big, hero_sub = "%dW" % (days // 7), "%d DAYS" % (days % 7)
        else:
            big, unit_text = str(days), ("DAY" if days == 1 else "DAYS")
            big_num, labels = big, [unit_text, month_day]
            hero_big, hero_sub = big, unit_text
    elif days == 0:
        big_color = ORANGE
        big, unit_text = "TODAY!", ""
        big_num, labels = "TODAY", []
        hero_big, hero_sub, hero_right = "GRAD", "DAY!", [month_day, year, "MBA"]
        lines = ["HOOK 'EM HORNS", event + " DAY"]
    else:
        big_color = ORANGE
        big, unit_text = "MBA", "DONE"
        big_num, labels = "DONE", ["MBA", year]
        hero_big, hero_sub, hero_right = "MBA", "DONE", ["CLASS", "OF", year]
        lines = ["CLASS OF " + year, "HOOK 'EM HORNS"]

    if layout == "hero":
        return render.Root(child = hero(hero_big, hero_sub, big_color, hero_right, progress))

    top = [header(style, line1, line2, progress)]

    if layout == "big":
        return render.Root(child = render.Column(children = top + [count_big(big_num, labels, big_color)]))

    footer_color = ORANGE if days <= 0 else DIM
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
                default = "hero",
                options = [
                    schema.Option(display = "Hero (full-panel Longhorn)", value = "hero"),
                    schema.Option(display = "Lockup (count + footer)", value = "lockup"),
                    schema.Option(display = "Big Number", value = "big"),
                ],
            ),
            schema.Dropdown(
                id = "header",
                name = "Header Style",
                desc = "Lockup and Big Number layouts",
                icon = "palette",
                default = "band",
                options = [
                    schema.Option(display = "Burnt orange band", value = "band"),
                    schema.Option(display = "Line on black", value = "line"),
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
                desc = "YYYY-MM-DD; when set, a progress bar shows how far through the program you are",
                icon = "flagCheckered",
                default = "",
            ),
            schema.Text(
                id = "line1",
                name = "Header Line 1",
                desc = "Big line next to the Longhorn (Lockup and Big Number)",
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
        ],
    )
