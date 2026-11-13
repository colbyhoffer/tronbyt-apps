"""
TCEQ Refinery Alerts for Tronbyt/Tidbyt
=======================================

Watches the TCEQ Air Emission Event Report RSS feed
(https://www2.tceq.texas.gov/oce/eer/RSSDataFeed.xml) and shows the
events whose feed title contains a keyword (default "REFINERY").

The feed covers roughly the last seven days of events. Each render
shows one matching event and rotates to the next one on the following
render, so a Tronbyt cycling through its apps walks the whole list.

Per event the display shows:
  - header bar: keyword + position in the list (e.g. 2/5)
  - facility name (from the feed title)
  - county + event start date/time (county from the detail page)
  - status + cause text (from the detail page)

Detail pages are fetched one per render and cached, so the extra
load on TCEQ is minimal. Turn "Fetch details" off to use the feed only.
"""

load("cache.star", "cache")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

FEED_URL = "https://www2.tceq.texas.gov/oce/eer/RSSDataFeed.xml"
FEED_TTL = 900  # 15 min cache for the feed
DETAIL_TTL = 21600  # 6 h cache for event detail pages
ROTATE_KEY_TTL = 86400

DEFAULT_KEYWORD = "REFINERY"
DEFAULT_ACCENT = "#d9480f"  # flare orange
TZ = "America/Chicago"  # TCEQ timestamps are Central time
SEP = " - "  # tom-thumb has no middle dot glyph

MONTHS = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

DEMO_EVENTS = [
    {
        "id": "468365",
        "rn": "RN100214386",
        "name": "VALERO CORPUS CHRISTI REFINERY WEST PLANT",
        "link": "",
        "when": "NOV 11 11:45A",
        "ts": 0,
        "county": "NUECES",
        "status": "OPEN",
        "type": "EMISSIONS EVENT",
        "cause": "Upset conditions in Complex 1 required venting to a facility flare.",
    },
]

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

def unescape(s):
    for a, b in [
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'"),
        ("&#x27;", "'"),
        ("&nbsp;", " "),
    ]:
        s = s.replace(a, b)
    return s

def strip_tags(s):
    out = ""
    rest = s
    for _ in range(200):
        i = rest.find("<")
        if i < 0:
            out += rest
            break
        out += rest[:i]
        j = rest.find(">", i)
        if j < 0:
            break
        rest = rest[j + 1:]
    return out

def squash(s):
    """Collapse all whitespace runs to single spaces."""
    return " ".join([w for w in s.replace("\n", " ").replace("\r", " ").replace("\t", " ").split(" ") if w])

def between(s, start, end, from_idx = 0):
    """Return (text between start and end after from_idx, index after end) or (None, -1)."""
    i = s.find(start, from_idx)
    if i < 0:
        return None, -1
    i += len(start)
    j = s.find(end, i)
    if j < 0:
        return None, -1
    return s[i:j], j + len(end)

def is_rn(tok):
    if len(tok) < 3 or not tok.startswith("RN"):
        return False
    return tok[2:].isdigit()

# ---------------------------------------------------------------------------
# Feed parsing
# ---------------------------------------------------------------------------

def parse_pubdate(s):
    """'Wed, 11 Nov 2026 15:55' -> (display string, unix seconds)."""
    s = squash(s)
    t = None
    for fmt in ["Mon, 02 Jan 2006 15:04", "Mon, 02 Jan 2006 15:04:05", "Mon, 02 Jan 2006"]:
        t = time.parse_time(s, format = fmt, location = TZ)
        if t != None:
            break
    if t == None:
        return s, 0
    label = "%s %d" % (MONTHS[t.month - 1], t.day)
    if t.hour != 0 or t.minute != 0:
        h = t.hour % 12
        if h == 0:
            h = 12
        mm = str(t.minute)
        if len(mm) < 2:
            mm = "0" + mm
        label += " %d:%s%s" % (h, mm, "P" if t.hour >= 12 else "A")
    return label, int(t.unix)

def parse_title(title):
    """'468365 - RN100214386 VALERO ... PLANT' -> (id, rn, name)."""
    title = squash(unescape(title))
    ev_id = ""
    rest = title
    sep = title.find(" - ")
    if sep >= 0 and title[:sep].isdigit():
        ev_id = title[:sep]
        rest = title[sep + 3:]
    rn = ""
    toks = rest.split(" ")
    if len(toks) > 1 and is_rn(toks[0]):
        rn = toks[0]
        rest = " ".join(toks[1:])
    return ev_id, rn, rest

def parse_feed(body):
    events = []
    pos = 0
    for _ in range(500):
        item, pos = between(body, "<item>", "</item>", pos)
        if item == None:
            break
        title, _ = between(item, "<title>", "</title>")
        link, _ = between(item, "<link>", "</link>")
        pub, _ = between(item, "<pubDate>", "</pubDate>")
        if title == None:
            continue
        ev_id, rn, name = parse_title(title)
        when, ts = parse_pubdate(pub or "")
        events.append({
            "id": ev_id,
            "rn": rn,
            "name": name,
            "title": squash(unescape(title)),
            "link": unescape(link or ""),
            "when": when,
            "ts": ts,
        })
    return events

def fetch_feed():
    res = http.get(FEED_URL, ttl_seconds = FEED_TTL, headers = {"User-Agent": "tronbyt-tceq-alerts"})
    if res.status_code != 200:
        return None, "HTTP %d" % res.status_code
    return parse_feed(res.body()), None

# ---------------------------------------------------------------------------
# Detail page (county, status, cause)
# ---------------------------------------------------------------------------

def field_after(html, label):
    """Text of the first <td> following a <th> containing `label`."""
    i = html.find(label)
    if i < 0:
        return ""
    cell, _ = between(html, "<td", "</td>", i)
    if cell == None:
        return ""
    gt = cell.find(">")
    if gt >= 0:
        cell = cell[gt + 1:]
    return squash(unescape(strip_tags(cell)))

def fetch_details(ev):
    if not ev.get("link"):
        return ev
    res = http.get(ev["link"], ttl_seconds = DETAIL_TTL, headers = {"User-Agent": "tronbyt-tceq-alerts"})
    if res.status_code != 200:
        return ev
    html = res.body()
    out = dict(ev)
    out["county"] = field_after(html, "County:")
    out["status"] = field_after(html, "Incident Status:")
    out["type"] = field_after(html, "Event/Activity Type:")
    out["cause"] = field_after(html, "Cause of Emission Event")
    return out

# ---------------------------------------------------------------------------
# Rotation: show the next matching event on each render
# ---------------------------------------------------------------------------

def pick_index(key, n):
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
# Rendering
# ---------------------------------------------------------------------------

def header(left, right, accent):
    return render.Box(
        width = 64,
        height = 7,
        color = accent,
        child = render.Padding(
            pad = (1, 0, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                cross_align = "center",
                children = [
                    render.Box(
                        width = 44,
                        height = 7,
                        child = render.Row(
                            expanded = True,
                            main_align = "start",
                            cross_align = "center",
                            children = [render.Text(left, font = "tom-thumb", color = "#000")],
                        ),
                    ),
                    render.Text(right, font = "tom-thumb", color = "#000"),
                ],
            ),
        ),
    )

def marquee(text, font, color, delay, height):
    return render.Marquee(
        width = 64,
        height = height,
        scroll_direction = "horizontal",
        offset_start = 64,
        offset_end = 64,
        delay = delay,
        child = render.Text(text, font = font, color = color),
    )

def render_message(keyword, lines, accent):
    kids = [header(keyword, "", accent)]
    for ln in lines:
        kids.append(
            render.Padding(
                pad = (1, 2, 0, 0),
                child = render.Text(ln, font = "tom-thumb", color = "#bbb"),
            ),
        )
    return render.Root(child = render.Column(children = kids))

def render_event(ev, keyword, pos, total, accent, delay, show_details):
    name = ev["name"] or ev.get("title", "?")

    meta_parts = []
    if show_details and ev.get("county"):
        meta_parts.append(ev["county"])
    if ev.get("when"):
        meta_parts.append(ev["when"])
    meta = SEP.join(meta_parts)

    detail_parts = []
    if show_details:
        if ev.get("status"):
            detail_parts.append(ev["status"])
        if ev.get("cause"):
            detail_parts.append(ev["cause"])
        elif ev.get("type"):
            detail_parts.append(ev["type"])
    if not detail_parts:
        detail_parts.append(ev.get("rn") or ("Event " + ev.get("id", "")))
    detail = SEP.join(detail_parts)

    status = ev.get("status", "")
    status_color = "#ff6b6b" if status == "OPEN" else "#9bd" if status else "#999"

    return render.Root(
        delay = delay,
        max_age = 120,
        child = render.Column(
            children = [
                header(keyword, "%d/%d" % (pos, total), accent),
                render.Box(
                    width = 64,
                    height = 9,
                    child = marquee(name, "tb-8", "#fff", delay, 8),
                ),
                render.Box(
                    width = 64,
                    height = 8,
                    child = marquee(meta, "tom-thumb", "#ffd166", delay, 6),
                ),
                render.Box(
                    width = 64,
                    height = 8,
                    child = marquee(detail, "tom-thumb", status_color, delay, 6),
                ),
            ],
        ),
    )

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    keyword = squash(config.str("keyword", DEFAULT_KEYWORD)).upper() or DEFAULT_KEYWORD
    accent = config.str("accent", DEFAULT_ACCENT)
    delay = int(config.str("speed", "80"))
    max_days = int(config.str("max_days", "0"))
    show_details = config.bool("show_details", True)
    hide_empty = config.bool("hide_empty", True)
    demo = config.bool("demo", False)

    if demo:
        return render_event(DEMO_EVENTS[0], keyword, 1, 1, accent, delay, show_details)

    events, err = fetch_feed()
    if err != None:
        return render_message(keyword, ["TCEQ feed error", err], accent)

    cutoff = int(time.now().unix) - max_days * 86400 if max_days > 0 else 0
    matches = [
        ev
        for ev in events
        if keyword in ev["title"].upper() and (cutoff == 0 or ev["ts"] == 0 or ev["ts"] >= cutoff)
    ]

    if not matches:
        if hide_empty:
            return []
        age = "past %d day%s" % (max_days, "" if max_days == 1 else "s") if max_days > 0 else "in feed"
        return render_message(keyword, ["No events", age], accent)

    idx = pick_index("tceq_alerts_idx_" + keyword + "_" + str(max_days), len(matches))
    ev = matches[idx]
    if show_details:
        ev = fetch_details(ev)

    return render_event(ev, keyword, idx + 1, len(matches), accent, delay, show_details)

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "keyword",
                name = "Keyword",
                desc = "Only show events whose feed title contains this (case-insensitive)",
                icon = "filter",
                default = DEFAULT_KEYWORD,
            ),
            schema.Dropdown(
                id = "max_days",
                name = "Max Age",
                desc = "Ignore events that started more than this long ago",
                icon = "calendar",
                default = "0",
                options = [
                    schema.Option(display = "1 day", value = "1"),
                    schema.Option(display = "2 days", value = "2"),
                    schema.Option(display = "3 days", value = "3"),
                    schema.Option(display = "Whole feed (about 7 days)", value = "0"),
                ],
            ),
            schema.Toggle(
                id = "show_details",
                name = "Fetch Details",
                desc = "Load county, status and cause from the event page",
                icon = "circleInfo",
                default = True,
            ),
            schema.Toggle(
                id = "hide_empty",
                name = "Hide When Empty",
                desc = "Skip the app when there are no matching events",
                icon = "eyeSlash",
                default = True,
            ),
            schema.Dropdown(
                id = "speed",
                name = "Scroll Speed",
                desc = "Marquee scroll speed",
                icon = "gauge",
                default = "80",
                options = [
                    schema.Option(display = "Relaxed", value = "160"),
                    schema.Option(display = "Slow", value = "120"),
                    schema.Option(display = "Normal", value = "80"),
                    schema.Option(display = "Fast", value = "50"),
                ],
            ),
            schema.Color(
                id = "accent",
                name = "Accent Color",
                desc = "Header bar color",
                icon = "brush",
                default = DEFAULT_ACCENT,
            ),
            schema.Toggle(
                id = "demo",
                name = "Demo Mode",
                desc = "Show a sample event instead of live data",
                icon = "flask",
                default = False,
            ),
        ],
    )
