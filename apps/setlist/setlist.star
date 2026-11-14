"""
Setlist Tracker for Tronbyt/Tidbyt
==================================

Shows a concert setlist from setlist.fm on your 64x32 display.

Two modes:
  - "My last concert": the most recent show you marked as attended
    on your setlist.fm account
  - "Artist's latest setlist": the newest setlist for any artist

Three layouts:
  - "Ticket Stub": date block + perforation on the left, artist,
    venue and a song ticker on the right
  - "Tracklist": artist header bar over a vertically scrolling
    numbered song list
  - "Classic": stacked marquees

SETUP
-----
1. Get a free API key at https://www.setlist.fm/settings/apps
2. Upload this app to your Tronbyt as a custom app
3. In the app settings, paste your API key and either your
   setlist.fm username (for attended mode) or an artist name

Rate limits are respected via response caching (30 min for
setlists, 24 h for artist lookups).
"""

load("http.star", "http")
load("random.star", "random")
load("render.star", "render")
load("schema.star", "schema")

API_BASE = "https://api.setlist.fm/rest/1.0"
SETLIST_TTL = 1800  # 30 min cache for setlist data
ARTIST_TTL = 86400  # 24 h cache for artist mbid lookups
STATS_TTL = 21600  # 6 h cache for attended-history pages
MAX_STATS_PAGES = 10  # up to 200 concerts of history
STATS_TOP_N = 10

DEFAULT_ACCENT = "#d23b2e"  # setlist.fm red

MONTHS = {
    "01": "Jan",
    "02": "Feb",
    "03": "Mar",
    "04": "Apr",
    "05": "May",
    "06": "Jun",
    "07": "Jul",
    "08": "Aug",
    "09": "Sep",
    "10": "Oct",
    "11": "Nov",
    "12": "Dec",
}

DEMO = {
    "artist": "LCD Soundsystem",
    "venue": "Moody Center · Austin, TX",
    "month": "NOV",
    "day": "12",
    "year": "2026",
    "songs": [
        "Us v Them",
        "Tribulations",
        "I Can Change",
        "Someone Great",
        "Dance Yrself Clean",
        "All My Friends",
    ],
}

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------

def url_encode(s):
    """Minimal percent-encoding for query values (ASCII)."""
    replacements = [
        ("%", "%25"),
        ("&", "%26"),
        ("+", "%2B"),
        ("#", "%23"),
        ("?", "%3F"),
        ("/", "%2F"),
        ("=", "%3D"),
        (" ", "%20"),
    ]
    for old, new in replacements:
        s = s.replace(old, new)
    return s

def api_get(path, api_key, ttl):
    res = http.get(
        API_BASE + path,
        headers = {
            "x-api-key": api_key,
            "Accept": "application/json",
        },
        ttl_seconds = ttl,
    )
    if res.status_code != 200:
        return None, res.status_code
    return res.json(), 200

def extract_songs(setlist):
    """Flatten all sets (encores included) into one song-name list."""
    songs = []
    sets = setlist.get("sets", {}).get("set", [])
    for s in sets:
        for song in s.get("song", []):
            name = song.get("name", "")
            if name:
                songs.append(name)
    return songs

def parse_date(event_date):
    """setlist.fm dates are dd-MM-yyyy -> (month_abbr, day, year)."""
    parts = event_date.split("-")
    if len(parts) != 3:
        return ("", event_date, "")
    day, month, year = parts[0], parts[1], parts[2]
    return (
        MONTHS.get(month, month).upper(),
        day.lstrip("0") or "0",
        year,
    )

def pick_setlist(data):
    """First setlist that has songs; fall back to the newest one."""
    setlists = data.get("setlist", [])
    if len(setlists) == 0:
        return None
    for sl in setlists:
        if len(extract_songs(sl)) > 0:
            return sl
    return setlists[0]

def get_user_setlist(username, api_key):
    data, status = api_get(
        "/user/%s/attended?p=1" % url_encode(username),
        api_key,
        SETLIST_TTL,
    )
    if data == None:
        return None, "User fetch failed (%d)" % status
    sl = pick_setlist(data)
    if sl == None:
        return None, "No attended shows for %s" % username
    return sl, None

def get_artist_setlist(artist_name, api_key):
    search, status = api_get(
        "/search/artists?artistName=%s&sort=relevance" % url_encode(artist_name),
        api_key,
        ARTIST_TTL,
    )
    if search == None:
        return None, "Artist search failed (%d)" % status
    artists = search.get("artist", [])
    if len(artists) == 0:
        return None, "Artist not found"
    mbid = artists[0].get("mbid", "")
    if mbid == "":
        return None, "Artist has no MBID"
    data, status = api_get(
        "/artist/%s/setlists?p=1" % mbid,
        api_key,
        SETLIST_TTL,
    )
    if data == None:
        return None, "Setlist fetch failed (%d)" % status
    sl = pick_setlist(data)
    if sl == None:
        return None, "No setlists found"
    return sl, None

# ---------------------------------------------------------------------------
# Stats: attended history + aggregation
# ---------------------------------------------------------------------------

def get_attended_history(username, api_key):
    """All attended setlists, newest first, up to MAX_STATS_PAGES pages."""
    all_setlists = []
    for p in range(1, MAX_STATS_PAGES + 1):
        data, status = api_get(
            "/user/%s/attended?p=%d" % (url_encode(username), p),
            api_key,
            STATS_TTL,
        )
        if data == None:
            if p == 1:
                return None, "History fetch failed (%d)" % status
            break
        page = data.get("setlist", [])
        all_setlists.extend(page)
        total = data.get("total", 0)
        per_page = data.get("itemsPerPage", 20)
        if len(page) == 0 or p * per_page >= total:
            break
    if len(all_setlists) == 0:
        return None, "No attended shows for %s" % username
    return all_setlists, None

def top_counts(pairs):
    """pairs: list of names (may repeat) -> [(name, count)] sorted desc."""
    counts = {}
    for name in pairs:
        if name:
            counts[name] = counts.get(name, 0) + 1
    items = sorted(counts.items(), key = lambda kv: -kv[1])
    return items[:STATS_TOP_N]

def stats_top_artists(setlists):
    return top_counts([sl.get("artist", {}).get("name", "") for sl in setlists])

def stats_top_venues(setlists):
    return top_counts([sl.get("venue", {}).get("name", "") for sl in setlists])

def stats_top_songs(setlists):
    names = []
    for sl in setlists:
        names.extend(extract_songs(sl))
    return top_counts(names)

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

def render_classic(info, accent, show_songs, delay):
    date_line = "%s %s %s" % (info["month"], info["day"], info["year"])
    if len(info["songs"]) > 0:
        date_line += " · %d songs" % len(info["songs"])
    children = [
        render.Marquee(
            width = 64,
            child = render.Text(info["artist"], font = "tb-8", color = accent),
        ),
        render.Marquee(
            width = 64,
            child = render.Text(info["venue"], font = "tom-thumb", color = "#ffffff"),
        ),
        render.Marquee(
            width = 64,
            child = render.Text(date_line, font = "tom-thumb", color = "#999999"),
        ),
    ]
    if show_songs:
        song_text = " • ".join(info["songs"]) if len(info["songs"]) > 0 else "No setlist posted yet"
        children.append(
            render.Marquee(
                width = 64,
                child = render.Text(song_text, font = "tom-thumb", color = "#cccccc"),
            ),
        )
    return render.Root(
        max_age = 3600,
        delay = delay,
        child = render.Column(
            expanded = True,
            main_align = "space_between",
            children = children,
        ),
    )

def render_ticket(info, accent, show_songs, delay):
    """Date block left, perforation, artist/venue/songs right."""
    left = render.Box(
        width = 17,
        height = 32,
        color = accent,
        child = render.Column(
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(info["month"], font = "tom-thumb", color = "#ffe1dc"),
                render.Text(info["day"], font = "6x13", color = "#ffffff"),
                render.Text(info["year"], font = "tom-thumb", color = "#ffe1dc"),
            ],
        ),
    )
    perforation = render.Column(
        children = [
            render.Box(
                width = 1,
                height = 2,
                color = "#555555" if i % 2 == 0 else "#000000",
            )
            for i in range(16)
        ],
    )
    right_rows = [
        render.Marquee(
            width = 44,
            child = render.Text(info["artist"], font = "tb-8", color = "#ffffff"),
        ),
        render.Marquee(
            width = 44,
            child = render.Text(info["venue"], font = "tom-thumb", color = "#999999"),
        ),
    ]
    if show_songs:
        song_text = " • ".join(info["songs"]) if len(info["songs"]) > 0 else "No setlist posted yet"
        right_rows.append(
            render.Marquee(
                width = 44,
                child = render.Text(song_text, font = "tom-thumb", color = "#ffb300"),
            ),
        )
    right = render.Padding(
        pad = (2, 0, 0, 0),
        child = render.Column(
            expanded = True,
            main_align = "space_around",
            children = right_rows,
        ),
    )
    return render.Root(
        max_age = 3600,
        delay = delay,
        child = render.Row(
            expanded = True,
            children = [left, perforation, right],
        ),
    )

def render_tracklist(info, accent, delay):
    """Artist header bar over a vertically scrolling numbered song list."""
    header = render.Box(
        width = 64,
        height = 7,
        color = accent,
        child = render.Padding(
            pad = (1, 1, 1, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Marquee(
                        width = 35,
                        child = render.Text(info["artist"], font = "tom-thumb", color = "#ffffff"),
                    ),
                    render.Text(
                        "%s %s" % (info["month"], info["day"]),
                        font = "tom-thumb",
                        color = "#ffd9d4",
                    ),
                ],
            ),
        ),
    )
    rows = []
    for i, name in enumerate(info["songs"]):
        num = str(i + 1)
        if len(num) < 2:
            num = "0" + num
        if len(name) > 14:
            name = name[:13] + "."
        rows.append(
            render.Row(
                children = [
                    render.Text(num + " ", font = "tom-thumb", color = "#ffb300"),
                    render.Text(name, font = "tom-thumb", color = "#ffffff"),
                ],
            ),
        )
    if len(rows) == 0:
        rows.append(render.Text("No setlist yet", font = "tom-thumb", color = "#999999"))
    else:
        rows.append(
            render.Text(
                "- %d SONGS · %s -" % (len(info["songs"]), info["year"]),
                font = "tom-thumb",
                color = "#5a5a5a",
            ),
        )
    body = render.Marquee(
        height = 25,
        scroll_direction = "vertical",
        child = render.Column(children = rows),
    )
    return render.Root(
        max_age = 3600,
        delay = delay,
        child = render.Column(
            children = [header, body],
        ),
    )

def stats_header(title, right_text, accent):
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
                    render.Text(title, font = "tom-thumb", color = "#ffffff"),
                    render.Text(right_text, font = "tom-thumb", color = "#ffd9d4"),
                ],
            ),
        ),
    )

def render_stats_list(title, right_text, rows, accent, delay):
    if len(rows) == 0:
        rows = [render.Text("No data yet", font = "tom-thumb", color = "#999999")]
    return render.Root(
        max_age = 3600,
        delay = delay,
        child = render.Column(
            children = [
                stats_header(title, right_text, accent),
                render.Marquee(
                    height = 25,
                    scroll_direction = "vertical",
                    child = render.Padding(
                        pad = (1, 0, 1, 0),
                        child = render.Column(children = rows),
                    ),
                ),
            ],
        ),
    )

def ranked_rows(entries):
    """entries: [(name, count)] -> numbered rows with counts."""
    rows = []
    for i, entry in enumerate(entries):
        name, count = entry
        if len(name) > 9:
            name = name[:8] + "."
        num = ("0" + str(i + 1))[-2:]
        rows.append(
            render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Row(
                        children = [
                            render.Text(num + " ", font = "tom-thumb", color = "#ffb300"),
                            render.Text(name.upper(), font = "tom-thumb", color = "#ffffff"),
                        ],
                    ),
                    render.Text("x" + str(count), font = "tom-thumb", color = "#999999"),
                ],
            ),
        )
    return rows

def recent_rows(setlists):
    rows = []
    for sl in setlists[:STATS_TOP_N]:
        _, _, year = parse_date(sl.get("eventDate", ""))
        yy = "'" + year[2:] if len(year) == 4 else year
        name = sl.get("artist", {}).get("name", "")
        if len(name) > 11:
            name = name[:10] + "."
        rows.append(
            render.Row(
                children = [
                    render.Text(yy + " ", font = "tom-thumb", color = "#ffb300"),
                    render.Text(name.upper(), font = "tom-thumb", color = "#ffffff"),
                ],
            ),
        )
    return rows

def render_stats_view(mode, setlists, accent, delay):
    n_shows = str(len(setlists))
    if mode == "top_artists":
        return render_stats_list("TOP ARTISTS", n_shows, ranked_rows(stats_top_artists(setlists)), accent, delay)
    elif mode == "top_venues":
        return render_stats_list("TOP VENUES", n_shows, ranked_rows(stats_top_venues(setlists)), accent, delay)
    elif mode == "top_songs":
        return render_stats_list("TOP SONGS", n_shows, ranked_rows(stats_top_songs(setlists)), accent, delay)
    return render_stats_list("RECENT CONCERTS", "", recent_rows(setlists), accent, delay)

def render_layout(layout, info, accent, show_songs, delay):
    if layout == "tracklist":
        return render_tracklist(info, accent, delay)
    elif layout == "classic":
        return render_classic(info, accent, show_songs, delay)
    return render_ticket(info, accent, show_songs, delay)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    api_key = config.str("api_key", "").strip()
    mode = config.str("mode", "user")
    layout = config.str("layout", "ticket")
    username = config.str("username", "").strip()
    artist_name = config.str("artist", "").strip()
    accent = config.str("accent", DEFAULT_ACCENT)
    show_songs = config.bool("show_songs", True)
    delay = int(config.str("speed", "120"))

    stats_modes = ["top_artists", "top_venues", "top_songs", "recent"]

    # Demo mode when unconfigured
    if api_key == "":
        if mode in stats_modes:
            demo_entries = [("Wilco", 12), ("LCD Soundsystem", 9), ("Mitski", 7), ("Spoon", 6), ("Khruangbin", 4)]
            if mode == "recent":
                return render_stats_list("RECENT CONCERTS", "", ranked_rows(demo_entries), accent, delay)
            return render_stats_list("TOP ARTISTS", "87", ranked_rows(demo_entries), accent, delay)
        info = {
            "artist": DEMO["artist"],
            "venue": DEMO["venue"],
            "month": DEMO["month"],
            "day": DEMO["day"],
            "year": DEMO["year"],
            "songs": DEMO["songs"],
        }
        return render_layout(layout, info, accent, show_songs, delay)

    if mode in stats_modes or mode == "random":
        if username == "":
            return render_message("Setup needed", "Enter your setlist.fm username", accent)
        setlists, err = get_attended_history(username, api_key)
        if err != None:
            return render_message("Stats error", err, accent)
        if mode == "random":
            with_songs = [sl for sl in setlists if len(extract_songs(sl)) > 0]
            pool = with_songs if len(with_songs) > 0 else setlists
            pick = pool[random.number(0, len(pool) - 1)]
            return render_layout(layout, setlist_to_info(pick), accent, show_songs, delay)
        return render_stats_view(mode, setlists, accent, delay)

    if mode == "user":
        if username == "":
            return render_message("Setup needed", "Enter your setlist.fm username", accent)
        setlist, err = get_user_setlist(username, api_key)
    else:
        if artist_name == "":
            return render_message("Setup needed", "Enter an artist name", accent)
        setlist, err = get_artist_setlist(artist_name, api_key)

    if err != None:
        return render_message("Setlist error", err, accent)

    return render_layout(layout, setlist_to_info(setlist), accent, show_songs, delay)

def setlist_to_info(setlist):
    artist = setlist.get("artist", {}).get("name", "Unknown artist")
    venue = setlist.get("venue", {})
    venue_name = venue.get("name", "")
    city = venue.get("city", {})
    city_name = city.get("name", "")
    state_code = city.get("stateCode", "")
    country = city.get("country", {}).get("code", "")
    region = state_code if country == "US" else country
    place_parts = [p for p in [venue_name, city_name] if p != ""]
    venue_city = " · ".join(place_parts)
    if region:
        venue_city += ", " + region

    month, day, year = parse_date(setlist.get("eventDate", ""))
    return {
        "artist": artist,
        "venue": venue_city,
        "month": month,
        "day": day,
        "year": year,
        "songs": extract_songs(setlist),
    }

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "api_key",
                name = "setlist.fm API Key",
                desc = "Get one free at setlist.fm/settings/apps",
                icon = "key",
            ),
            schema.Dropdown(
                id = "mode",
                name = "Mode",
                desc = "What to display",
                icon = "music",
                default = "user",
                options = [
                    schema.Option(display = "My last concert", value = "user"),
                    schema.Option(display = "Random concert I attended", value = "random"),
                    schema.Option(display = "Artist's latest setlist", value = "artist"),
                    schema.Option(display = "Stats: Top artists seen", value = "top_artists"),
                    schema.Option(display = "Stats: Top venues", value = "top_venues"),
                    schema.Option(display = "Stats: Top songs heard", value = "top_songs"),
                    schema.Option(display = "Stats: Recent concerts", value = "recent"),
                ],
            ),
            schema.Dropdown(
                id = "layout",
                name = "Layout",
                desc = "How to display it",
                icon = "tableColumns",
                default = "ticket",
                options = [
                    schema.Option(display = "Ticket Stub", value = "ticket"),
                    schema.Option(display = "Tracklist", value = "tracklist"),
                    schema.Option(display = "Classic", value = "classic"),
                ],
            ),
            schema.Text(
                id = "username",
                name = "setlist.fm Username",
                desc = "For 'My last concert' mode",
                icon = "user",
            ),
            schema.Text(
                id = "artist",
                name = "Artist Name",
                desc = "For 'Artist's latest setlist' mode",
                icon = "guitar",
            ),
            schema.Dropdown(
                id = "speed",
                name = "Scroll Speed",
                desc = "Marquee and list scroll speed",
                icon = "gauge",
                default = "120",
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
                desc = "Date block / header color",
                icon = "brush",
                default = DEFAULT_ACCENT,
            ),
            schema.Toggle(
                id = "show_songs",
                name = "Show Songs",
                desc = "Scroll the full setlist (Ticket/Classic layouts)",
                icon = "listOl",
                default = True,
            ),
        ],
    )
