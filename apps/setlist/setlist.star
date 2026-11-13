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
load("render.star", "render")
load("schema.star", "schema")

API_BASE = "https://api.setlist.fm/rest/1.0"
SETLIST_TTL = 1800  # 30 min cache for setlist data
ARTIST_TTL = 86400  # 24 h cache for artist mbid lookups

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

def render_classic(info, accent, show_songs):
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
        child = render.Column(
            expanded = True,
            main_align = "space_between",
            children = children,
        ),
    )

def render_ticket(info, accent, show_songs):
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
        child = render.Row(
            expanded = True,
            children = [left, perforation, right],
        ),
    )

def render_tracklist(info, accent):
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
                "- %d SONGS -" % len(info["songs"]),
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
        child = render.Column(
            children = [header, body],
        ),
    )

def render_layout(layout, info, accent, show_songs):
    if layout == "tracklist":
        return render_tracklist(info, accent)
    elif layout == "classic":
        return render_classic(info, accent, show_songs)
    return render_ticket(info, accent, show_songs)

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

    # Demo mode when unconfigured
    if api_key == "":
        info = {
            "artist": DEMO["artist"],
            "venue": DEMO["venue"],
            "month": DEMO["month"],
            "day": DEMO["day"],
            "year": DEMO["year"],
            "songs": DEMO["songs"],
        }
        return render_layout(layout, info, accent, show_songs)

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
    info = {
        "artist": artist,
        "venue": venue_city,
        "month": month,
        "day": day,
        "year": year,
        "songs": extract_songs(setlist),
    }
    return render_layout(layout, info, accent, show_songs)

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
                    schema.Option(display = "Artist's latest setlist", value = "artist"),
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
