"""
Oura for Tronbyt
================

Shows your Oura Ring data on the 64x32 display, signed in through the
Tronbyt server's OAuth client (no personal access token needed; Oura
retired those in late 2025).

Views (pick one, or rotate through them one per render):
  - "Dashboard": Sleep / Readiness / Activity ("MOVE") scores side by
    side with tier-colored bars, last night's sleep length, today's steps
  - "Sleep": time asleep, efficiency, HRV, bedtime window, a
    deep/REM/light/awake stage bar and lowest heart rate
  - "Readiness": score, temperature deviation, resting HR and the four
    contributors that move the score most
  - "Activity": steps, progress toward the daily calorie goal, active
    calories, distance and active minutes
  - "Trend": the last 7 days of one score as bars

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
DIM = "#8a8a8a"
DIMMER = "#3a3a3a"
TRACK = "#262626"
RULE = "#303030"

# Score tiers (Oura: Optimal / Good / Pay attention)
TIER_OPTIMAL = "#3fd1b9"
TIER_GOOD = "#5aa9f2"
TIER_LOW = "#f5a054"

# Sleep stages
STAGE_DEEP = "#3a6ff0"
STAGE_REM = "#9b6cf5"
STAGE_LIGHT = "#79b8ff"
STAGE_AWAKE = "#6a6a6a"

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
    """RFC3339 -> 11:42p"""
    if iso == None:
        return "--"
    t = time.parse_time(iso).in_location(tz)
    s = t.format("3:04pm")
    return s[:len(s) - 1]

def fmt_temp(dev):
    if dev == None:
        return "--"
    sign = "+" if dev >= 0 else "-"
    v = dev if dev >= 0 else -dev
    whole = int(v)
    tenth = int(v * 10 + 0.5) % 10
    return "%s%d.%d" % (sign, whole, tenth)

def fmt_distance(meters, units):
    if meters == None:
        return "--"
    if units == "mi":
        v = meters / 1609.344
        return "%d.%dmi" % (int(v), int(v * 10 + 0.5) % 10)
    v = meters / 1000.0
    return "%d.%dkm" % (int(v), int(v * 10 + 0.5) % 10)

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
# Drawing primitives
# ---------------------------------------------------------------------------

def tiny(text, color = WHITE):
    return render.Text(content = text, font = "tom-thumb", height = 5, offset = -1, color = color)

def big(text, color = WHITE):
    return render.Text(content = text, font = "6x13", height = 9, offset = -2, color = color)

def hgap(w):
    return render.Box(width = w, height = 1)

def vgap(h):
    return render.Box(width = 1, height = h)

def pixel_rows(grid, color):
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
                boxes.append(render.Box(width = run_len, height = 1, color = color if run_char == "#" else "#000000"))
            run_char = ch
            run_len = 1
        if run_len > 0:
            boxes.append(render.Box(width = run_len, height = 1, color = color if run_char == "#" else "#000000"))
        rows.append(render.Row(children = boxes))
    return render.Column(children = rows)

def bar(width, frac, color, height = 2, track = TRACK):
    """Horizontal progress bar; always shows at least 1px when frac > 0."""
    fill = int(frac * width + 0.5)
    if frac > 0 and fill == 0:
        fill = 1
    if fill > width:
        fill = width
    children = []
    if fill > 0:
        children.append(render.Box(width = fill, height = height, color = color))
    if width - fill > 0:
        children.append(render.Box(width = width - fill, height = height, color = track))
    return render.Row(children = children)

def segment_bar(width, parts, height = 3):
    """parts: list of (value, color); widths proportional, leftovers to the largest."""
    total = 0
    for v, _ in parts:
        total += (v or 0)
    if total <= 0:
        return render.Box(width = width, height = height, color = TRACK)
    widths = []
    used = 0
    for v, _ in parts:
        w = int((v or 0) * width / total)
        widths.append(w)
        used += w

    # hand remaining pixels to the widest segment
    if used < width:
        bi = 0
        for i in range(len(widths)):
            if widths[i] > widths[bi]:
                bi = i
        widths[bi] += width - used
    children = []
    for i in range(len(parts)):
        if widths[i] > 0:
            children.append(render.Box(width = widths[i], height = height, color = parts[i][1]))
    return render.Row(children = children)

def header(title, accent, right_text, right_color):
    """5px title line + 1px rule under it (6 rows total, plus 1 gap = 7)."""
    return render.Column(
        children = [
            render.Box(
                width = 64,
                height = 5,
                child = render.Row(
                    expanded = True,
                    main_align = "space_between",
                    cross_align = "center",
                    children = [
                        padded(tiny(title, accent), left = 1),
                        padded(tiny(right_text, right_color), right = 1),
                    ],
                ),
            ),
            vgap(1),
            render.Box(width = 64, height = 1, color = RULE),
        ],
    )

def padded(child, left = 0, top = 0, right = 0, bottom = 0):
    return render.Padding(pad = (left, top, right, bottom), child = child)

def render_message(title, msg, accent):
    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "center",
            children = [
                render.Row(
                    cross_align = "center",
                    children = [
                        padded(pixel_rows(RING7, accent), left = 1),
                        hgap(3),
                        tiny(title, accent),
                    ],
                ),
                vgap(3),
                render.Marquee(width = 64, child = tiny(msg, WHITE)),
            ],
        ),
    )

# ---------------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------------

def score_column(label, score, width):
    color = tier_color(score)
    text = "--" if score == None else str(int(score))
    return render.Box(
        width = width,
        height = 18,
        child = render.Column(
            cross_align = "center",
            children = [
                tiny(label, color + "88"),
                vgap(1),
                big(text, color),
                vgap(1),
                bar(16, pct(score, 100), color),
            ],
        ),
    )

def view_dashboard(d, accent, now, demo):
    sleep = latest(d["daily_sleep"])
    ready = latest(d["daily_readiness"])
    act = latest(d["daily_activity"])
    session = latest_sleep_session(d["sleep"])

    s_score = sleep.get("score") if sleep else None
    r_score = ready.get("score") if ready else None
    a_score = act.get("score") if act else None

    asleep = fmt_hm(session.get("total_sleep_duration")) if session else "--"
    steps = fmt_int(act.get("steps")) if act and act.get("steps") != None else "--"

    if demo:
        stamp = "DEMO"
    else:
        stamp = day_label(latest_day(sleep, ready, act), now)

    return render.Root(
        child = render.Column(
            children = [
                render.Row(
                    children = [
                        score_column("SLEEP", s_score, 21),
                        score_column("READY", r_score, 21),
                        score_column("MOVE", a_score, 22),
                    ],
                ),
                vgap(1),
                render.Box(
                    width = 64,
                    height = 5,
                    child = render.Row(
                        expanded = True,
                        main_align = "space_between",
                        children = [
                            padded(tiny(asleep, WHITE), left = 2),
                            padded(tiny(steps + " ST", WHITE), right = 2),
                        ],
                    ),
                ),
                vgap(1),
                render.Box(
                    width = 64,
                    height = 7,
                    child = render.Row(
                        expanded = True,
                        main_align = "space_between",
                        cross_align = "center",
                        children = [
                            render.Row(
                                cross_align = "center",
                                children = [
                                    hgap(2),
                                    pixel_rows(RING7, accent),
                                    hgap(2),
                                    tiny("OURA", accent),
                                ],
                            ),
                            padded(tiny(stamp, DIM), right = 2),
                        ],
                    ),
                ),
            ],
        ),
    )

def view_sleep(d, accent, tz):
    sleep = latest(d["daily_sleep"])
    session = latest_sleep_session(d["sleep"])
    score = sleep.get("score") if sleep else None
    if session == None:
        return render_message("SLEEP", "No sleep data yet. Open the Oura app to sync.", accent)

    asleep = fmt_hm(session.get("total_sleep_duration"))
    eff = session.get("efficiency")
    hrv = session.get("average_hrv")
    low_hr = session.get("lowest_heart_rate")
    window = fmt_clock(session.get("bedtime_start"), tz) + "-" + fmt_clock(session.get("bedtime_end"), tz)

    right_col = render.Column(
        children = [
            render.Row(children = [tiny("EF ", DIM), tiny("--" if eff == None else "%d%%" % int(eff), WHITE)]),
            render.Row(children = [tiny("HRV ", DIM), tiny("--" if hrv == None else "%d" % int(hrv), WHITE)]),
        ],
    )
    left_col = render.Column(
        children = [
            big(asleep, WHITE),
            vgap(1),
            tiny(window, DIM),
        ],
    )

    stages = segment_bar(62, [
        (session.get("deep_sleep_duration"), STAGE_DEEP),
        (session.get("rem_sleep_duration"), STAGE_REM),
        (session.get("light_sleep_duration"), STAGE_LIGHT),
        (session.get("awake_time"), STAGE_AWAKE),
    ])

    return render.Root(
        child = render.Column(
            children = [
                header("SLEEP", accent, "--" if score == None else str(int(score)), tier_color(score)),
                render.Stack(
                    children = [
                        padded(left_col, left = 1),
                        padded(right_col, left = 38),
                    ],
                ),
                vgap(1),
                padded(stages, left = 1),
                vgap(1),
                render.Row(
                    children = [
                        hgap(1),
                        tiny("LOW HR ", DIM),
                        tiny("--" if low_hr == None else "%d" % int(low_hr), WHITE),
                        tiny(" BPM", DIM),
                    ],
                ),
            ],
        ),
    )

def contributor_row(label, value, width):
    color = tier_color(value)
    return render.Row(
        cross_align = "center",
        children = [
            render.Box(width = 16, height = 5, child = render.Row(children = [tiny(label, DIM)])),
            bar(width - 16, pct(value, 100), color, height = 3),
        ],
    )

def view_readiness(d, accent, now, demo):
    ready = latest(d["daily_readiness"])
    session = latest_sleep_session(d["sleep"])
    if ready == None:
        return render_message("READINESS", "No readiness data yet. Open the Oura app to sync.", accent)
    score = ready.get("score")
    contrib = ready.get("contributors") or {}
    temp = fmt_temp(ready.get("temperature_deviation"))
    rhr = session.get("lowest_heart_rate") if session else None

    rows = [
        contributor_row("SLP", contrib.get("previous_night"), 30),
        vgap(1),
        contributor_row("HRV", contrib.get("hrv_balance"), 30),
        vgap(1),
        contributor_row("RHR", contrib.get("resting_heart_rate"), 30),
        vgap(1),
        contributor_row("TMP", contrib.get("body_temperature"), 30),
    ]

    return render.Root(
        child = render.Column(
            children = [
                vgap(1),
                header("READINESS", accent, day_label(ready.get("day"), now) if not demo else "DEMO", DIM),
                vgap(1),
                render.Row(
                    children = [
                        hgap(1),
                        render.Column(
                            children = [
                                big("--" if score == None else str(int(score)), tier_color(score)),
                                vgap(2),
                                render.Row(children = [tiny(temp, WHITE), tiny("C", DIM)]),
                                vgap(1),
                                render.Row(children = [tiny("--" if rhr == None else "%d" % int(rhr), WHITE), tiny(" RHR", DIM)]),
                            ],
                        ),
                        hgap(5),
                        render.Column(children = rows),
                    ],
                ),
            ],
        ),
    )

def view_activity(d, accent, units):
    act = latest(d["daily_activity"])
    if act == None:
        return render_message("ACTIVITY", "No activity data yet. Open the Oura app to sync.", accent)
    score = act.get("score")
    steps = act.get("steps")
    active_cal = act.get("active_calories")
    target_cal = act.get("target_calories")
    frac = pct(active_cal, target_cal)
    dist = fmt_distance(act.get("equivalent_walking_distance"), units)
    active_s = (act.get("high_activity_time") or 0) + (act.get("medium_activity_time") or 0)

    return render.Root(
        child = render.Column(
            children = [
                header("ACTIVITY", accent, "--" if score == None else str(int(score)), tier_color(score)),
                render.Row(
                    cross_align = "end",
                    children = [
                        hgap(1),
                        big("--" if steps == None else fmt_int(steps), WHITE),
                        hgap(3),
                        padded(tiny("STEPS", DIM), bottom = 1),
                    ],
                ),
                vgap(1),
                padded(bar(62, frac, tier_color(int(frac * 100)), height = 2), left = 1),
                vgap(1),
                render.Row(
                    children = [
                        hgap(1),
                        tiny("--" if active_cal == None else "%d" % int(active_cal), WHITE),
                        tiny("/" + ("--" if target_cal == None else "%d" % int(target_cal)) + " CAL", DIM),
                    ],
                ),
                vgap(1),
                render.Row(
                    children = [
                        hgap(1),
                        tiny(dist, WHITE),
                        tiny("  " + fmt_minutes(active_s) + " MIN", DIM),
                    ],
                ),
            ],
        ),
    )

def view_trend(d, accent, now, demo, metric):
    name = {"sleep": "SLEEP", "readiness": "READINESS", "activity": "ACTIVITY"}[metric]
    records = d["daily_" + metric]
    series = trend_series(records, now, demo)
    today = series[len(series) - 1]["score"] if len(series) > 0 else 0
    latest_rec = latest(records)
    shown = today if today > 0 else (latest_rec.get("score") if latest_rec else None)

    max_h = 17
    bars = []
    labels = []
    for i in range(len(series)):
        s = series[i]["score"]
        h = int(s * max_h / 100 + 0.5) if s > 0 else 0
        is_last = i == len(series) - 1
        color = tier_color(s) if s > 0 else TRACK
        if not is_last and s > 0:
            color = color + "99"
        col = render.Column(
            main_align = "end",
            children = [
                render.Box(width = 7, height = max_h - h),
                render.Box(width = 7, height = h if h > 0 else 1, color = color if h > 0 else TRACK),
            ],
        )
        bars.append(col)
        labels.append(render.Box(width = 7, height = 5, child = tiny(series[i]["label"], WHITE if is_last else DIM)))
        if i < len(series) - 1:
            bars.append(hgap(1))
            labels.append(hgap(1))

    return render.Root(
        child = render.Column(
            children = [
                vgap(1),
                header(name + " 7D", accent, "--" if shown == None else str(int(shown)), tier_color(shown)),
                vgap(1),
                padded(render.Row(cross_align = "end", children = bars), left = 4),
                vgap(1),
                padded(render.Row(children = labels), left = 5),
            ],
        ),
    )

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
