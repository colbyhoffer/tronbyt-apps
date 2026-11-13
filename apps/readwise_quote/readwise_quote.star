"""
Readwise Quote of the Day for Tronbyt/Tidbyt
============================================

Shows one of your Readwise highlights on the 64x32 display: the quote
text wrapped and scrolling vertically, followed by the book title and
author.

Sources:
  - "Daily Review": the highlights Readwise picked for today's review
    (https://readwise.io/api/v2/review/)
  - "Whole library": every highlight in your account via the export
    endpoint (https://readwise.io/api/v2/export/), cached for 6 h

Picking:
  - "Same quote all day": index seeded from today's date, so the quote
    only changes at midnight (in your device's timezone)
  - "Next quote each render": walks the list one highlight per render,
    like the TCEQ alerts app

Layouts:
  - "Header + scroll": READWISE header bar, quote scrolls underneath
  - "Full screen": no header, the whole 32px is quote

SETUP
-----
1. Get your access token at https://readwise.io/access_token
2. Paste it into the app settings
"""

load("cache.star", "cache")
load("hash.star", "hash")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

API_BASE = "https://readwise.io/api/v2"
REVIEW_TTL = 3600  # the daily review set is fixed for the day; 1 h is plenty
EXPORT_TTL = 21600  # 6 h cache for the full library export
MAX_EXPORT_PAGES = 10
ROTATE_KEY_TTL = 86400

DEFAULT_ACCENT = "#f4b942"  # Readwise yellow
DEFAULT_TZ = "America/Chicago"
TEXT_COLOR = "#ffffff"
TITLE_COLOR = "#f4b942"
AUTHOR_COLOR = "#999999"

DEMO = {
    "text": "Show up early. Work hard. Stay late. Have a plan. Deliver on your promises. Share the hardships with the employees. Show that you care. Admit your mistakes. And - did I mention? - work hard.",
    "title": "The Wisdom of the Bullfrog",
    "author": "William H. McRaven",
}

# ---------------------------------------------------------------------------
# Text helpers
# ---------------------------------------------------------------------------

REPLACEMENTS = [
    ("‘", "'"),
    ("’", "'"),
    ("‚", "'"),
    ("“", "\""),
    ("”", "\""),
    ("„", "\""),
    ("–", "-"),
    ("—", " - "),
    ("…", "..."),
    (" ", " "),
    ("«", "\""),
    ("»", "\""),
    ("•", "-"),
    ("é", "e"),
    ("è", "e"),
    ("ê", "e"),
    ("á", "a"),
    ("à", "a"),
    ("ä", "a"),
    ("ö", "o"),
    ("ó", "o"),
    ("ü", "u"),
    ("ú", "u"),
    ("í", "i"),
    ("ñ", "n"),
    ("ç", "c"),
    ("É", "E"),
    ("\r", " "),
    ("\n", " "),
    ("\t", " "),
]

def clean_text(s):
    """Fold common typographic characters into ASCII that the pixel
    fonts can draw, drop anything else non-ASCII, and collapse spaces."""
    if s == None:
        return ""
    for old, new in REPLACEMENTS:
        s = s.replace(old, new)
    out = []
    for cp in s.codepoints():
        if ord(cp) < 32 or ord(cp) > 126:
            continue
        out.append(cp)
    s = "".join(out)
    words = [w for w in s.split(" ") if w != ""]
    return " ".join(words)

def hex_to_int(h):
    return int(h, 16)

# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------

def api_get(path, token, ttl):
    res = http.get(
        API_BASE + path,
        headers = {
            "Authorization": "Token " + token,
            "Accept": "application/json",
        },
        ttl_seconds = ttl,
    )
    if res.status_code != 200:
        return None, res.status_code
    return res.json(), 200

def status_message(status):
    if status == 401 or status == 403:
        return "Bad access token"
    if status == 429:
        return "Rate limited, retrying later"
    return "Readwise error (%d)" % status

def make_quote(text, title, author):
    return {
        "text": clean_text(text),
        "title": clean_text(title or ""),
        "author": clean_text(author or ""),
    }

def fetch_review(token):
    """Today's Daily Review highlights (title/author come inline)."""
    data, status = api_get("/review/", token, REVIEW_TTL)
    if data == None:
        return None, status_message(status)
    quotes = []
    for h in data.get("highlights", []):
        text = h.get("text", "")
        if text:
            quotes.append(make_quote(text, h.get("title", ""), h.get("author", "")))
    if len(quotes) == 0:
        return None, "No highlights in today's review"
    return quotes, None

def fetch_library(token):
    """Every highlight in the account via the export endpoint."""
    quotes = []
    cursor = ""
    for _ in range(MAX_EXPORT_PAGES):
        path = "/export/"
        if cursor != "":
            path += "?pageCursor=" + cursor
        data, status = api_get(path, token, EXPORT_TTL)
        if data == None:
            if len(quotes) == 0:
                return None, status_message(status)
            break
        for book in data.get("results", []):
            if book.get("is_deleted", False):
                continue
            title = book.get("readable_title") or book.get("title") or ""
            author = book.get("author") or ""
            for h in book.get("highlights", []):
                if h.get("is_deleted", False) or h.get("is_discard", False):
                    continue
                text = h.get("text", "")
                if text:
                    quotes.append(make_quote(text, title, author))
        cursor = data.get("nextPageCursor") or ""
        if cursor == "":
            break
    if len(quotes) == 0:
        return None, "No highlights in your library"
    return quotes, None

# ---------------------------------------------------------------------------
# Picking
# ---------------------------------------------------------------------------

def filter_quotes(quotes, max_len):
    if max_len <= 0:
        return quotes
    kept = [q for q in quotes if len(q["text"]) <= max_len]
    # Never filter down to nothing; fall back to the shortest ones.
    if len(kept) == 0:
        kept = sorted(quotes, key = lambda q: len(q["text"]))[:1]
    return kept

def daily_index(n, tz, salt):
    """Same index for the whole calendar day in the given timezone."""
    if n <= 1:
        return 0
    today = time.now().in_location(tz).format("2006-01-02")
    digest = hash.sha256(today + "|" + salt)
    return hex_to_int(digest[:8]) % n

def rotate_index(key, n):
    """Advance one highlight per render (mirrors the TCEQ app)."""
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

def render_message(title, msg, accent):
    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "center",
            children = [
                render.Marquee(
                    width = 64,
                    child = render.Text(title, font = "tb-8", color = accent),
                ),
                render.Marquee(
                    width = 64,
                    child = render.Text(msg, font = "tom-thumb"),
                ),
            ],
        ),
    )

def header_bar(accent, right_text):
    return render.Box(
        width = 64,
        height = 7,
        color = accent,
        child = render.Padding(
            pad = (1, 1, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Text("READWISE", font = "tom-thumb", color = "#1a1a1a"),
                    render.Text(right_text, font = "tom-thumb", color = "#1a1a1a"),
                ],
            ),
        ),
    )

def attribution_rows(quote, accent):
    rows = []
    if quote["title"] != "":
        rows.append(render.WrappedText(quote["title"], font = "tom-thumb", color = accent, width = 62))
    if quote["author"] != "":
        rows.append(render.WrappedText(quote["author"], font = "tom-thumb", color = AUTHOR_COLOR, width = 62))
    return rows

def quote_body(quote, accent, height):
    rows = [
        render.WrappedText(
            "\"" + quote["text"] + "\"",
            font = "tom-thumb",
            color = TEXT_COLOR,
            width = 62,
        ),
    ]
    attribution = attribution_rows(quote, accent)
    if len(attribution) > 0:
        rows.append(render.Box(width = 62, height = 3))
        rows.extend(attribution)

    # A marquee only scrolls when the child is taller than the viewport,
    # so short quotes sit still and long ones roll through.
    return render.Marquee(
        height = height,
        scroll_direction = "vertical",
        child = render.Padding(
            pad = (1, 0, 1, 0),
            child = render.Column(children = rows),
        ),
    )

def render_header_layout(quote, accent, delay, right_text):
    return render.Root(
        delay = delay,
        max_age = 300,
        child = render.Column(
            children = [
                header_bar(accent, right_text),
                quote_body(quote, accent, 25),
            ],
        ),
    )

def render_full_layout(quote, accent, delay):
    return render.Root(
        delay = delay,
        max_age = 300,
        child = quote_body(quote, accent, 32),
    )

def render_quote(layout, quote, accent, delay, right_text):
    if layout == "full":
        return render_full_layout(quote, accent, delay)
    return render_header_layout(quote, accent, delay, right_text)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    token = config.str("token", "").strip()
    source = config.str("source", "review")
    pick = config.str("pick", "daily")
    layout = config.str("layout", "header")
    accent = config.str("accent", DEFAULT_ACCENT)
    max_len = int(config.str("max_len", "500"))
    delay = int(config.str("speed", "100"))
    tz = config.get("$tz") or DEFAULT_TZ

    if token == "":
        return render_quote(layout, make_quote(DEMO["text"], DEMO["title"], DEMO["author"]), accent, delay, "DEMO")

    if source == "library":
        quotes, err = fetch_library(token)
        right_text = "LIBRARY"
    else:
        quotes, err = fetch_review(token)
        right_text = "DAILY"
    if err != None:
        return render_message("Readwise", err, accent)

    quotes = filter_quotes(quotes, max_len)
    n = len(quotes)

    # Key the rotation state on a token fingerprint, never the token itself.
    fp = hash.sha256(token)[:12]
    if pick == "rotate":
        idx = rotate_index("readwise_idx_" + source + "_" + fp, n)
    else:
        idx = daily_index(n, tz, source + "|" + fp)

    return render_quote(layout, quotes[idx], accent, delay, right_text)

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "token",
                name = "Readwise Access Token",
                desc = "From readwise.io/access_token",
                icon = "key",
            ),
            schema.Dropdown(
                id = "source",
                name = "Source",
                desc = "Where to pull highlights from",
                icon = "book",
                default = "review",
                options = [
                    schema.Option(display = "Today's Daily Review", value = "review"),
                    schema.Option(display = "Whole library", value = "library"),
                ],
            ),
            schema.Dropdown(
                id = "pick",
                name = "Pick",
                desc = "How often the quote changes",
                icon = "shuffle",
                default = "daily",
                options = [
                    schema.Option(display = "Same quote all day", value = "daily"),
                    schema.Option(display = "Next quote each render", value = "rotate"),
                ],
            ),
            schema.Dropdown(
                id = "layout",
                name = "Layout",
                desc = "How to display it",
                icon = "tableColumns",
                default = "header",
                options = [
                    schema.Option(display = "Header + scroll", value = "header"),
                    schema.Option(display = "Full screen", value = "full"),
                ],
            ),
            schema.Dropdown(
                id = "max_len",
                name = "Max Quote Length",
                desc = "Skip highlights longer than this (characters)",
                icon = "textWidth",
                default = "500",
                options = [
                    schema.Option(display = "Short (up to 200)", value = "200"),
                    schema.Option(display = "Medium (up to 350)", value = "350"),
                    schema.Option(display = "Long (up to 500)", value = "500"),
                    schema.Option(display = "Any length", value = "0"),
                ],
            ),
            schema.Dropdown(
                id = "speed",
                name = "Scroll Speed",
                desc = "Vertical scroll speed",
                icon = "gauge",
                default = "100",
                options = [
                    schema.Option(display = "Relaxed", value = "140"),
                    schema.Option(display = "Slow", value = "100"),
                    schema.Option(display = "Normal", value = "70"),
                    schema.Option(display = "Fast", value = "45"),
                ],
            ),
            schema.Color(
                id = "accent",
                name = "Accent Color",
                desc = "Header bar and book title color",
                icon = "brush",
                default = DEFAULT_ACCENT,
            ),
        ],
    )
