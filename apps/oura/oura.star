"""
Oura for Tronbyt
================

Shows your Oura Ring data on the 64x32 display, signed in through the
Tronbyt server's OAuth client (no personal access token needed; Oura
retired those in late 2025).

Views (pick one, or rotate through them one per render):
  - "Dashboard": three score rings (Sleep / Ready / Move) with the
    number inside, last night's sleep length, today's steps, TODAY/YDAY
  - "Sleep": time asleep in big digits, overnight heart-rate sparkline,
    hypnogram from sleep_phase_5_min, HRV, bed window
  - "Readiness": score ring, temperature deviation, contributor bars
  - "Activity": score ring, steps, calorie-goal bar, distance, and a
    movement-through-the-day profile from class_5_min
  - "Trend": the last 7 days of one score as bars with a mean line

Rendering: everything is drawn into a 64x32 pixel buffer (own 3x5 and
5x9 fonts, ring/bar primitives) and flushed as rows of render.Box runs.

Scores use Oura's tiers: 85+ optimal (teal), 70-84 good (blue),
below 70 pay attention (orange).

Data: Oura API v2 usercollection endpoints daily_sleep, daily_readiness,
daily_activity and sleep, cached 15 minutes. The "day" of each record is
the Oura day (sleep is filed under the morning you woke up).

SETUP (Tronbyt server with OAuth clients, v2.7+ or the main build)
-------------------------------------------------------------------
1. Settings -> OAuth Clients -> New. Copy the redirect URI it shows.
2. At https://cloud.ouraring.com/oauth/applications create an app with
   that redirect URI and all scopes ticked. Copy the client ID + secret.
3. Back in Tronbyt enter name "Oura",
   authorization endpoint https://cloud.ouraring.com/oauth/authorize,
   token endpoint https://api.ouraring.com/oauth/token,
   and the client ID + secret. Save.
4. Install this app and press "Sign in" on its config page.

For `pixlet serve` without a server, paste an access token into the
"Access token (manual)" field instead.
"""

load("cache.star", "cache")
load("hash.star", "hash")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

API_BASE = "https://api.ouraring.com/v2/usercollection"
AUTH_ENDPOINT = "https://cloud.ouraring.com/oauth/authorize"
TOKEN_ENDPOINT = "https://api.ouraring.com/oauth/token"
SCOPES = ["daily", "personal", "heartrate"]

DATA_TTL = 900  # 15 min; Oura syncs from the phone a few times an hour at best
ROTATE_KEY_TTL = 86400
TREND_DAYS = 7
LOOKBACK_DAYS = 9  # a little more than the trend window so a missed sync still has data

DEFAULT_TZ = "America/Chicago"
DEFAULT_ACCENT = "#d9b36c"  # Oura gold

WHITE = "#ffffff"
BLACK = "#000000"
DIM = "#8a8a8a"
TRACK = "#242428"
RULE = "#232328"
CONNECTOR = "#2a2a33"
MEAN_LINE = "#34343e"
SPARK = "#3a6ff0"
SPARK_DIM = "#2a4c9e"

# Score tiers (Oura: Optimal / Good / Pay attention)
TIER_OPTIMAL = "#3fd1b9"
TIER_GOOD = "#5aa9f2"
TIER_LOW = "#f5a054"

# Sleep stages
STAGE_DEEP = "#3a6ff0"
STAGE_REM = "#9b6cf5"
STAGE_LIGHT = "#79b8ff"
STAGE_AWAKE = "#6a6a6a"

# daily_activity class_5_min: 0 non-wear, 1 rest, 2 inactive, 3 low, 4 medium, 5 high
CLASS_COLORS = ["#1a1a20", "#2a4c9e", "#3a6ff0", "#5aa9f2", "#3fd1b9", "#3fd1b9"]

VIEWS = ["dashboard", "sleep", "readiness", "activity", "trend"]

# 7x7 ring mark, "#" = on
RING7 = [
    ".#####.",
    "#.....#",
    "#.....#",
    "#.....#",
    "#.....#",
    "#.....#",
    ".#####.",
]

# Demo payloads mirror the API shapes so the real code paths render them.
DEMO_DAILY_SLEEP = [
    {"day": "D-6", "score": 71},
    {"day": "D-5", "score": 80},
    {"day": "D-4", "score": 88},
    {"day": "D-3", "score": 64},
    {"day": "D-2", "score": 77},
    {"day": "D-1", "score": 90},
    {"day": "D-0", "score": 86},
]
DEMO_DAILY_READINESS = [
    {"day": "D-6", "score": 68},
    {"day": "D-5", "score": 75},
    {"day": "D-4", "score": 83},
    {"day": "D-3", "score": 61},
    {"day": "D-2", "score": 79},
    {"day": "D-1", "score": 85},
    {
        "day": "D-0",
        "score": 78,
        "temperature_deviation": 0.3,
        "contributors": {
            "previous_night": 86,
            "hrv_balance": 72,
            "resting_heart_rate": 90,
            "body_temperature": 65,
            "sleep_balance": 80,
            "recovery_index": 74,
            "activity_balance": 88,
            "previous_day_activity": 70,
        },
    },
]
DEMO_DAILY_ACTIVITY = [
    {"day": "D-6", "score": 80},
    {"day": "D-5", "score": 91},
    {"day": "D-4", "score": 73},
    {"day": "D-3", "score": 95},
    {"day": "D-2", "score": 84},
    {"day": "D-1", "score": 69},
    {
        "day": "D-0",
        "score": 92,
        "steps": 8412,
        "active_calories": 412,
        "target_calories": 500,
        "total_calories": 2310,
        "equivalent_walking_distance": 6120,
        "high_activity_time": 600,
        "medium_activity_time": 1500,
        "low_activity_time": 4200,
        # 0 non-wear, 1 rest, 2 inactive, 3 low, 4 medium, 5 high (5-minute bins from 4am)
        "class_5_min": "1" * 60 + "2" * 12 + "3" * 10 + "4" * 8 + "3" * 10 + "2" * 12 + "4" * 6 + "5" * 8 + "3" * 10 + "2" * 20 + "3" * 10 + "2" * 10 + "4" * 10 + "3" * 8 + "2" * 10 + "0" * 84,
    },
]
DEMO_SLEEP = [
    {
        "day": "D-0",
        "type": "long_sleep",
        "total_sleep_duration": 27120,
        "time_in_bed": 29400,
        "deep_sleep_duration": 5400,
        "rem_sleep_duration": 6300,
        "light_sleep_duration": 15420,
        "awake_time": 2280,
        "efficiency": 92,
        "average_hrv": 48,
        "lowest_heart_rate": 52,
        "average_heart_rate": 58,
        "bedtime_start": "2026-11-14T23:42:11-06:00",
        "bedtime_end": "2026-11-15T07:52:11-06:00",
        "heart_rate": {
            "interval": 300,
            "items": [66, 63, 60, 58, 57, 55, 54, 53, 52, 53, 55, 58, 56, 54, 53, 54, 57, 60, 58, 56, 58, 61, 64, 66, 69, 72],
        },
        # 1 deep, 2 light, 3 REM, 4 awake (5-minute bins)
        "sleep_phase_5_min": "44" + "2222" + "11111111" + "22222" + "3333" + "222222" + "1111111" + "2222" + "333333" + "4" + "22222222" + "1111" + "222222" + "33333333" + "22222" + "4" + "333333" + "2222222" + "44",
    },
]

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

def api_get(collection, token, start_day, end_day):
    """Fetch one usercollection for a date window. Returns (list, status)."""
    res = http.get(
        API_BASE + "/" + collection + "?start_date=" + start_day + "&end_date=" + end_day,
        headers = {
            "Authorization": "Bearer " + token,
            "Accept": "application/json",
        },
        ttl_seconds = DATA_TTL,
    )
    if res.status_code != 200:
        return None, res.status_code
    body = res.json()
    data = body.get("data")
    if type(data) != "list":
        return [], 200
    return data, 200

def fetch_all(token, now):
    """Pull the four collections we use. Returns (dict, error_message)."""
    start_day = (now - time.parse_duration("%dh" % (24 * LOOKBACK_DAYS))).format("2006-01-02")
    end_day = (now + time.parse_duration("24h")).format("2006-01-02")

    out = {}
    for name in ["daily_sleep", "daily_readiness", "daily_activity", "sleep"]:
        data, status = api_get(name, token, start_day, end_day)
        if status == 401:
            return None, "Sign in with Oura in the app settings"
        if status == 403:
            return None, "Oura app is missing the '%s' scope" % ("daily" if name != "sleep" else "daily")
        if status == 429:
            return None, "Oura rate limit hit, try again soon"
        if status != 200:
            return None, "Oura API error %d" % status
        out[name] = data
    return out, None

def demo_data():
    return {
        "daily_sleep": DEMO_DAILY_SLEEP,
        "daily_readiness": DEMO_DAILY_READINESS,
        "daily_activity": DEMO_DAILY_ACTIVITY,
        "sleep": DEMO_SLEEP,
    }

# ---------------------------------------------------------------------------
# Data shaping
# ---------------------------------------------------------------------------

def latest(records):
    """Last record with a non-null score (the API returns ascending by day)."""
    for i in range(len(records)):
        rec = records[len(records) - 1 - i]
        if rec.get("score") != None:
            return rec
    return None

def latest_sleep_session(records):
    """Prefer the newest long_sleep; fall back to any session with a duration."""
    best = None
    for rec in records:
        if rec.get("total_sleep_duration") == None:
            continue
        if rec.get("type") == "long_sleep":
            best = rec
        elif best == None or best.get("type") != "long_sleep":
            best = rec
    return best

def scores_by_day(records):
    out = {}
    for rec in records:
        if rec.get("score") != None and rec.get("day") != None:
            out[rec["day"]] = int(rec["score"])
    return out

def trend_series(records, now, demo):
    """Scores for the last TREND_DAYS calendar days ending today, 0 = no data."""
    by_day = scores_by_day(records)
    days = []
    for i in range(TREND_DAYS):
        back = TREND_DAYS - 1 - i
        if demo:
            key = "D-%d" % back
            d = now - time.parse_duration("%dh" % (24 * back))
            label = d.format("Mon")[0]
        else:
            d = now - time.parse_duration("%dh" % (24 * back))
            key = d.format("2006-01-02")
            label = d.format("Mon")[0]
        days.append({"label": label, "score": by_day.get(key, 0)})
    return days

def tier_color(score):
    if score == None:
        return DIM
    if score >= 85:
        return TIER_OPTIMAL
    if score >= 70:
        return TIER_GOOD
    return TIER_LOW

def fmt_int(n):
    """8412 -> 8,412"""
    s = str(int(n))
    if len(s) <= 3:
        return s
    out = ""
    for i in range(len(s)):
        if i > 0 and (len(s) - i) % 3 == 0:
            out += ","
        out += s[i]
    return out

def fmt_hm(seconds):
    """27120 -> 7h32m"""
    if seconds == None:
        return "--"
    m = int(seconds) // 60
    mm = m % 60
    return "%dh%s%dm" % (m // 60, "0" if mm < 10 else "", mm)

def fmt_minutes(seconds):
    if seconds == None:
        return "--"
    return "%d" % (int(seconds) // 60)

def fmt_clock(iso, tz):
    """RFC3339 -> 11:42 (bed times read fine without am/pm)"""
    if iso == None:
        return "--"
    return time.parse_time(iso).in_location(tz).format("3:04")

def fmt_temp(dev):
    if dev == None:
        return "--"
    sign = "+" if dev >= 0 else "-"
    v = dev if dev >= 0 else -dev
    whole = int(v)
    tenth = int(v * 10 + 0.5) % 10
    return "%s%d.%d" % (sign, whole, tenth)

def fmt_distance(meters, units):
    """Returns (value, unit) e.g. ("3.8", "MI")."""
    if meters == None:
        return "--", ""
    if units == "mi":
        v = meters / 1609.344
        return "%d.%d" % (int(v), int(v * 10 + 0.5) % 10), "MI"
    v = meters / 1000.0
    return "%d.%d" % (int(v), int(v * 10 + 0.5) % 10), "KM"

def pct(num, den):
    if num == None or den == None or den <= 0:
        return 0.0
    f = float(num) / float(den)
    if f < 0:
        return 0.0
    if f > 1:
        return 1.0
    return f

# ---------------------------------------------------------------------------
# Pixel buffer + fonts
#
# Everything is drawn into a 64x32 grid of color strings and flushed as rows
# of render.Box runs, so layouts land exactly where the design puts them.
# ---------------------------------------------------------------------------

W = 64
H = 32

# 3x5 glyphs, 15 chars per glyph, rows top to bottom.
F3 = {
    "A": "010101111101101",
    "B": "110101110101110",
    "C": "011100100100011",
    "D": "110101101101110",
    "E": "111100110100111",
    "F": "111100110100100",
    "G": "011100101101011",
    "H": "101101111101101",
    "I": "111010010010111",
    "J": "001001001101010",
    "K": "101101110101101",
    "L": "100100100100111",
    "M": "101111111101101",
    "N": "110101101101101",
    "O": "010101101101010",
    "P": "110101110100100",
    "Q": "010101101110011",
    "R": "110101110101101",
    "S": "011100010001110",
    "T": "111010010010010",
    "U": "101101101101111",
    "V": "101101101101010",
    "W": "101101111111101",
    "X": "101101010101101",
    "Y": "101101010010010",
    "Z": "111001010100111",
    "0": "111101101101111",
    "1": "010110010010111",
    "2": "110001010100111",
    "3": "110001010001110",
    "4": "101101111001001",
    "5": "111100110001110",
    "6": "011100110101010",
    "7": "111001010010010",
    "8": "010101010101010",
    "9": "010101011001110",
    "%": "101001010100101",
    ":": "000010000010000",
    "-": "000000111000000",
    "+": "000010111010000",
    ".": "000000000000010",
    ",": "000000000010100",
    "/": "001001010100100",
    "°": "010101010000000",
    "h": "100100110101101",
    "m": "000000101111101",
    "p": "000110101110100",
    "a": "000011101101011",
    " ": "000000000000000",
}

# 5x9 digits, 45 chars per glyph.
F5 = {
    "0": "011101000110001100011000110001100011000101110",
    "1": "001000110000100001000010000100001000010001110",
    "2": "011101000100001000010001000100010001000011111",
    "3": "011101000100001000010011000001000011000101110",
    "4": "000100011001010100101001011111000100001000010",
    "5": "111111000010000111100000100001000011000101110",
    "6": "001100100010000111101000110001100011000101110",
    "7": "111110000100010000100010000100010000100001000",
    "8": "011101000110001100010111010001100011000101110",
    "9": "011101000110001100010111100001000010001001100",
}

HEXDIGITS = "0123456789abcdef"

def hex2(v):
    v = max(0, min(255, int(v)))
    return HEXDIGITS[v // 16] + HEXDIGITS[v % 16]

def dim_color(hex, f):
    """Scale an #rrggbb color toward black."""
    r = int(hex[1:3], 16)
    g = int(hex[3:5], 16)
    b = int(hex[5:7], 16)
    return "#" + hex2(r * f) + hex2(g * f) + hex2(b * f)

def text_w(s):
    n = len([c for c in s.codepoints()])
    return 4 * n - 1 if n > 0 else 0

def new_grid():
    return [[None for _ in range(W)] for _ in range(H)]

def px(g, x, y, c):
    if x >= 0 and x < W and y >= 0 and y < H:
        g[y][x] = c

def rect(g, x, y, w, h, c):
    for j in range(h):
        for i in range(w):
            px(g, x + i, y + j, c)

def text(g, x, y, s, c):
    """3x5 text; returns the x just past the last glyph's gap."""
    cx = x
    for ch in s.codepoints():
        glyph = F3.get(ch) or F3.get(ch.upper()) or F3[" "]
        for j in range(5):
            for i in range(3):
                if glyph[j * 3 + i] == "1":
                    px(g, cx + i, y + j, c)
        cx += 4
    return cx

def text_r(g, right, y, s, c):
    """Right-align 3x5 text so its last column is at right - 1."""
    return text(g, right - text_w(s), y, s, c)

def big(g, x, y, s, c):
    """5x9 digits; other characters fall back to 3x5 on the baseline."""
    cx = x
    for ch in s.codepoints():
        glyph = F5.get(ch)
        if glyph != None:
            for j in range(9):
                for i in range(5):
                    if glyph[j * 5 + i] == "1":
                        px(g, cx + i, y + j, c)
            cx += 6
        else:
            text(g, cx, y + 4, ch, c)
            cx += 4
    return cx

def ring(g, x0, y0, d, t, frac, c, track):
    """Progress ring of diameter d, stroke t, clockwise from 12 o'clock."""
    cx = x0 + d / 2.0
    cy = y0 + d / 2.0
    r = d / 2.0
    for y in range(y0, y0 + d):
        for x in range(x0, x0 + d):
            dx = x + 0.5 - cx
            dy = y + 0.5 - cy
            dist = math.sqrt(dx * dx + dy * dy)
            if dist <= r and dist > r - t:
                a = math.atan2(dx, -dy)
                if a < 0:
                    a += 2 * math.pi
                a = a / (2 * math.pi)
                px(g, x, y, c if a <= frac else track)

def hbar(g, x, y, w, h, frac, c, track):
    fill = int(frac * w + 0.5)
    if frac > 0 and fill < 1:
        fill = 1
    if fill > w:
        fill = w
    rect(g, x, y, w, h, track)
    if fill > 0:
        rect(g, x, y, fill, h, c)

def flush(g):
    """Grid -> Root of 32 single-pixel-high rows of Box runs."""
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
    return render.Root(child = render.Column(children = rows))

def render_message(title, msg, accent):
    g = new_grid()
    ring(g, 1, 1, 9, 2, 1.0, accent, accent)
    text(g, 13, 3, title, accent)
    return render.Root(
        child = render.Column(
            children = [
                flush_rows(g, 0, 11),
                render.Padding(
                    pad = (1, 2, 0, 0),
                    child = render.Marquee(width = 62, child = render.Text(msg, font = "tom-thumb", color = WHITE)),
                ),
            ],
        ),
    )

def flush_rows(g, y0, y1):
    """Like flush but returns a Column for rows y0..y1-1 only."""
    rows = []
    for y in range(y0, y1):
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

# ---------------------------------------------------------------------------
# Series helpers
# ---------------------------------------------------------------------------

def downsample(values, n):
    """Average a list of numbers into n bins (None entries skipped)."""
    clean = [v for v in values if v != None]
    if len(clean) == 0:
        return []
    out = []
    for i in range(n):
        lo = int(i * len(clean) / n)
        hi = int((i + 1) * len(clean) / n)
        if hi <= lo:
            hi = lo + 1
        chunk = clean[lo:min(hi, len(clean))]
        if len(chunk) == 0:
            continue
        total = 0.0
        for v in chunk:
            total += v
        out.append(total / len(chunk))
    return out

def phase_segments(phases):
    """'4422211133' -> [(stage, count), ...] with stages A/L/D/R."""
    names = {"1": "D", "2": "L", "3": "R", "4": "A"}
    segs = []
    for ch in phases.elems():
        st = names.get(ch)
        if st == None:
            continue
        if len(segs) > 0 and segs[-1][0] == st:
            segs[-1] = (st, segs[-1][1] + 1)
        else:
            segs.append((st, 1))
    return segs

def class_bins(classes, n):
    """class_5_min string -> n columns of max class; -1 past the last data."""
    chars = [c for c in classes.elems()]
    last = -1
    for i in range(len(chars)):
        if chars[i] != "0":
            last = i
    out = []
    for i in range(n):
        lo = int(i * len(chars) / n)
        hi = int((i + 1) * len(chars) / n)
        if lo > last:
            out.append(-1)
            continue
        best = 0
        for k in range(lo, max(lo + 1, hi)):
            if k < len(chars) and chars[k].isdigit():
                best = max(best, int(chars[k]))
        out.append(best)
    return out

# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

def view_dashboard(d, accent, now, demo):
    sleep = latest(d["daily_sleep"])
    ready = latest(d["daily_readiness"])
    act = latest(d["daily_activity"])
    session = latest_sleep_session(d["sleep"])

    g = new_grid()
    cols = [
        ("SLEEP", sleep.get("score") if sleep else None, 4, 1),
        ("READY", ready.get("score") if ready else None, 25, 22),
        ("MOVE", act.get("score") if act else None, 46, 45),
    ]
    for label, score, rx, lx in cols:
        c = tier_color(score)
        frac = pct(score, 100)
        ring(g, rx, 1, 13, 2, frac, c, TRACK)
        s = "--" if score == None else str(int(score))
        text(g, rx + 7 - (text_w(s) + 1) // 2, 5, s, WHITE)
        text(g, lx, 15, label, dim_color(c, 0.8))

    asleep = fmt_hm(session.get("total_sleep_duration")) if session else "--"
    text(g, 2, 21, asleep, WHITE)
    steps = fmt_int(act.get("steps")) if act and act.get("steps") != None else "--"
    text_r(g, 64, 21, "ST", DIM)
    text_r(g, 55, 21, steps, WHITE)

    text(g, 2, 27, "OURA", accent)
    stamp = "DEMO" if demo else day_label(latest_day(sleep, ready, act), now)
    text_r(g, 64, 27, stamp, DIM)
    return flush(g)

def view_sleep(d, accent, tz):
    sleep = latest(d["daily_sleep"])
    session = latest_sleep_session(d["sleep"])
    if session == None:
        return render_message("SLEEP", "No sleep data yet. Open the Oura app to sync.", accent)
    score = sleep.get("score") if sleep else None
    tc = tier_color(score)

    g = new_grid()
    text(g, 1, 0, "SLEEP", accent)
    rect(g, 52, 1, 3, 3, tc)
    text_r(g, 64, 0, "--" if score == None else str(int(score)), tc)
    rect(g, 0, 6, W, 1, RULE)

    big(g, 1, 8, fmt_hm(session.get("total_sleep_duration")), WHITE)

    # overnight heart rate, x 38..63 rows 8..16, lowest point white
    hr = session.get("heart_rate") or {}
    pts = downsample(hr.get("items") or [], 26)
    if len(pts) >= 2:
        mn = min(pts)
        mx = max(pts)
        span = mx - mn if mx > mn else 1.0
        prev_y = None
        for i in range(len(pts)):
            x = 38 + i
            y = 16 - int((pts[i] - mn) / span * 8 + 0.5)
            if prev_y != None and abs(prev_y - y) > 1:
                lo = min(prev_y, y)
                hi = max(prev_y, y)
                for yy in range(lo + 1, hi):
                    px(g, x, yy, SPARK_DIM)
            px(g, x, y, WHITE if pts[i] == mn else SPARK)
            prev_y = y

    # hypnogram rows 18..25 from sleep_phase_5_min; fallback: duration bar
    segs = phase_segments(session.get("sleep_phase_5_min") or "")
    level = {"A": 18, "R": 20, "L": 22, "D": 24}
    color = {"A": STAGE_AWAKE, "R": STAGE_REM, "L": STAGE_LIGHT, "D": STAGE_DEEP}
    if len(segs) > 0:
        total = 0
        for _, n in segs:
            total += n
        x = 1
        acc = 0
        prev = None
        for st, n in segs:
            acc += n
            x_end = 1 + int(acc * 62 / total + 0.5)
            w = max(1, x_end - x)
            if prev != None:
                lo = min(prev, level[st])
                hi = max(prev, level[st])
                for yy in range(lo, hi + 2):
                    px(g, x, yy, CONNECTOR)
            rect(g, x, level[st], w, 2, color[st])
            prev = level[st]
            x = x_end
    else:
        parts = [
            (session.get("deep_sleep_duration"), STAGE_DEEP),
            (session.get("rem_sleep_duration"), STAGE_REM),
            (session.get("light_sleep_duration"), STAGE_LIGHT),
            (session.get("awake_time"), STAGE_AWAKE),
        ]
        total = 0
        for v, _ in parts:
            total += (v or 0)
        x = 1
        if total > 0:
            for v, c in parts:
                w = int((v or 0) * 62 / total + 0.5)
                rect(g, x, 21, w, 3, c)
                x += w

    start = fmt_clock(session.get("bedtime_start"), tz)
    end = fmt_clock(session.get("bedtime_end"), tz)
    text(g, 1, 27, start, DIM)
    text_r(g, 64, 27, end, DIM)
    hrv = session.get("average_hrv")
    hrv_s = "--" if hrv == None else str(int(hrv))
    left = 1 + text_w(start) + 3
    right = 64 - text_w(end) - 3
    block = text_w("HRV ") + text_w(hrv_s)
    x0 = left + (right - left - block) // 2
    nx = text(g, x0, 27, "HRV ", DIM)
    text(g, nx, 27, hrv_s, WHITE)
    return flush(g)

def view_readiness(d, accent, now, demo):
    ready = latest(d["daily_readiness"])
    if ready == None:
        return render_message("READINESS", "No readiness data yet. Open the Oura app to sync.", accent)
    score = ready.get("score")
    contrib = ready.get("contributors") or {}

    g = new_grid()
    ring(g, 1, 1, 17, 2, pct(score, 100), tier_color(score), TRACK)
    s = "--" if score == None else str(int(score))
    big(g, 4, 5, s, WHITE)
    text(g, 0, 19, "READY", accent)
    temp = ready.get("temperature_deviation")
    if temp != None:
        nx = text(g, 1, 25, fmt_temp(temp), WHITE)
        text(g, nx, 25, "°", DIM)

    rows = [
        ("SLP", contrib.get("previous_night")),
        ("HRV", contrib.get("hrv_balance")),
        ("RHR", contrib.get("resting_heart_rate")),
        ("TMP", contrib.get("body_temperature")),
    ]
    for i in range(len(rows)):
        label, v = rows[i]
        y = 2 + i * 7
        text(g, 22, y, label, DIM)
        hbar(g, 35, y + 1, 28, 3, pct(v, 100), tier_color(v), TRACK)

    stamp = "DEMO" if demo else day_label(ready.get("day"), now)
    text_r(g, 64, 27, stamp, DIM)
    return flush(g)

def view_activity(d, accent, units):
    act = latest(d["daily_activity"])
    if act == None:
        return render_message("ACTIVITY", "No activity data yet. Open the Oura app to sync.", accent)
    score = act.get("score")

    g = new_grid()
    ring(g, 1, 1, 17, 2, pct(score, 100), tier_color(score), TRACK)
    big(g, 4, 5, "--" if score == None else str(int(score)), WHITE)
    text(g, 2, 19, "MOVE", accent)
    dist, unit = fmt_distance(act.get("equivalent_walking_distance"), units)
    nx = text(g, 0, 25, dist, WHITE)
    text(g, nx, 25, unit, DIM)

    steps = act.get("steps")
    nx = text(g, 21, 1, "--" if steps == None else fmt_int(steps), WHITE)
    text(g, nx + 1, 1, "STEPS", DIM)

    cal = act.get("active_calories")
    goal = act.get("target_calories")
    frac = pct(cal, goal)
    hbar(g, 21, 8, 42, 2, frac, tier_color(int(frac * 100)), TRACK)
    nx = text(g, 21, 12, "--" if cal == None else str(int(cal)), WHITE)
    text(g, nx, 12, "/" + ("--" if goal == None else str(int(goal))) + " CAL", DIM)

    # movement through the day: 42 columns, rows 17..28
    bins = class_bins(act.get("class_5_min") or "", 42)
    last_col = -1
    for i in range(len(bins)):
        v = bins[i]
        if v < 0:
            continue
        last_col = i
        h = 1 if v == 0 else 2 + v * 2
        rect(g, 21 + i, 29 - h, 1, h, CLASS_COLORS[min(v, 5)])
    if last_col >= 0:
        v = bins[last_col]
        h = 1 if v == 0 else 2 + v * 2
        rect(g, 21 + last_col, 29 - h, 1, h, WHITE)
    return flush(g)

def view_trend(d, accent, now, demo, metric):
    name = {"sleep": "SLEEP", "readiness": "READY", "activity": "MOVE"}[metric]
    records = d["daily_" + metric]
    series = trend_series(records, now, demo)
    scored = [s["score"] for s in series if s["score"] > 0]
    today = series[-1]["score"] if len(series) > 0 else 0
    latest_rec = latest(records)
    shown = today if today > 0 else (latest_rec.get("score") if latest_rec else None)
    avg = None
    if len(scored) > 0:
        total = 0
        for v in scored:
            total += v
        avg = int(total / len(scored) + 0.5)

    g = new_grid()
    text(g, 1, 0, name, accent)
    if avg != None:
        text(g, 28, 0, "AVG " + str(avg), DIM)
    text_r(g, 64, 0, "--" if shown == None else str(int(shown)), tier_color(shown))
    rect(g, 0, 6, W, 1, RULE)

    max_h = 18
    if avg != None:
        mean_y = 26 - int(avg * max_h / 100.0 + 0.5)
        for x in range(2, 62, 2):
            px(g, x, mean_y, MEAN_LINE)

    for i in range(len(series)):
        v = series[i]["score"]
        is_today = i == len(series) - 1
        if v > 0:
            h = max(1, int(v * max_h / 100.0 + 0.5))
            c = tier_color(v) if is_today else dim_color(tier_color(v), 0.55)
            rect(g, 4 + i * 8, 26 - h, 7, h, c)
        else:
            rect(g, 4 + i * 8, 25, 7, 1, TRACK)
        text(g, 4 + i * 8 + 2, 27, series[i]["label"], WHITE if is_today else DIM)
    return flush(g)

# ---------------------------------------------------------------------------
# Helpers for dates
# ---------------------------------------------------------------------------

def latest_day(*recs):
    best = None
    for r in recs:
        if r == None or r.get("day") == None:
            continue
        if best == None or r["day"] > best:
            best = r["day"]
    return best

def day_label(day, now):
    """'2026-11-15' -> 'TODAY' / 'YDAY' / 'NOV 13'."""
    if day == None:
        return ""
    today = now.format("2006-01-02")
    if day == today:
        return "TODAY"
    yday = (now - time.parse_duration("24h")).format("2006-01-02")
    if day == yday:
        return "YDAY"
    t = time.parse_time(day, format = "2006-01-02")
    return t.format("Jan 2").upper()

def rotate_index(key, n):
    if n <= 1:
        return 0
    last = cache.get(key)
    if last == None or not last.isdigit():
        idx = int(time.now().unix / 20) % n
    else:
        idx = (int(last) + 1) % n
    cache.set(key, str(idx), ttl_seconds = ROTATE_KEY_TTL)
    return idx

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    tz = config.get("$tz") or DEFAULT_TZ
    now = time.now().in_location(tz)
    accent = config.get("accent") or DEFAULT_ACCENT
    view = config.get("view") or "dashboard"
    metric = config.get("trend_metric") or "sleep"
    units = config.get("units") or "mi"

    token = config.get("oura_auth") or config.get("manual_token") or ""
    token = token.strip()
    demo = token == ""

    if demo:
        data = demo_data()
    else:
        data, err = fetch_all(token, now)
        if err != None:
            return render_message("OURA", err, accent)

    if view == "rotate":
        fp = hash.sha256(token)[:12] if token else "demo"
        view = VIEWS[rotate_index("oura_view_" + fp, len(VIEWS))]

    if view == "sleep":
        return view_sleep(data, accent, tz)
    if view == "readiness":
        return view_readiness(data, accent, now, demo)
    if view == "activity":
        return view_activity(data, accent, units)
    if view == "trend":
        return view_trend(data, accent, now, demo, metric)
    return view_dashboard(data, accent, now, demo)

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.OAuth2(
                id = "oura_auth",
                name = "Oura",
                desc = "Sign in with your Oura account through this server's OAuth client.",
                icon = "ring",
                authorization_endpoint = AUTH_ENDPOINT,
                token_endpoint = TOKEN_ENDPOINT,
                scopes = SCOPES,
            ),
            schema.Dropdown(
                id = "view",
                name = "View",
                desc = "Which screen to show",
                icon = "tableColumns",
                default = "dashboard",
                options = [
                    schema.Option(display = "Dashboard (all three scores)", value = "dashboard"),
                    schema.Option(display = "Sleep", value = "sleep"),
                    schema.Option(display = "Readiness", value = "readiness"),
                    schema.Option(display = "Activity", value = "activity"),
                    schema.Option(display = "7-day trend", value = "trend"),
                    schema.Option(display = "Rotate through all", value = "rotate"),
                ],
            ),
            schema.Dropdown(
                id = "trend_metric",
                name = "Trend Metric",
                desc = "Score shown in the 7-day trend view",
                icon = "chartSimple",
                default = "sleep",
                options = [
                    schema.Option(display = "Sleep", value = "sleep"),
                    schema.Option(display = "Readiness", value = "readiness"),
                    schema.Option(display = "Activity", value = "activity"),
                ],
            ),
            schema.Dropdown(
                id = "units",
                name = "Distance Units",
                desc = "For the activity view",
                icon = "ruler",
                default = "mi",
                options = [
                    schema.Option(display = "Miles", value = "mi"),
                    schema.Option(display = "Kilometers", value = "km"),
                ],
            ),
            schema.Color(
                id = "accent",
                name = "Accent Color",
                desc = "Labels and the ring mark",
                icon = "brush",
                default = DEFAULT_ACCENT,
                palette = [DEFAULT_ACCENT, "#ffffff", "#3fd1b9", "#5aa9f2", "#f5a054"],
            ),
            schema.Text(
                id = "manual_token",
                name = "Access token (manual)",
                desc = "Only for pixlet serve / testing. Leave empty when signed in above.",
                icon = "key",
            ),
        ],
    )
