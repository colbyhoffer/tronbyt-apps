"""
Setlist Tracker for Tronbyt/Tidbyt
==================================

Shows a concert setlist from setlist.fm on your 64x32 display.

Two modes:
  - "My last concert": the most recent show you marked as attended
    on your setlist.fm account
  - "Artist's latest setlist": the newest setlist for any artist

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
    "date": "Nov 12 2026",
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

def format_date(event_date):
    """setlist.fm dates are dd-MM-yyyy."""
    parts = event_date.split("-")
    if len(parts) != 3:
        return event_date
    day, month, year = parts[0], parts[1], parts[2]
    return "%s %s %s" % (MONTHS.get(month, month), day.lstrip("0") or "0", year)

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

def render_setlist(artist, venue_city, date_line, songs, accent, show_songs):
    children = [
        render.Marquee(
            width = 64,
            child = render.Text(artist, font = "tb-8", color = accent),
        ),
        render.Marquee(
            width = 64,
            child = render.Text(venue_city, font = "tom-thumb", color = "#ffffff"),
        ),
        render.Marquee(
            width = 64,
            child = render.Text(date_line, font = "tom-thumb", color = "#999999"),
        ),
    ]
    if show_songs:
        song_text = " • ".join(songs) if len(songs) > 0 else "No setlist posted yet"
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main(config):
    api_key = config.str("api_key", "").strip()
    mode = config.str("mode", "user")
    username = config.str("username", "").strip()
    artist_name = config.str("artist", "").strip()
    accent = config.str("accent", DEFAULT_ACCENT)
    show_songs = config.bool("show_songs", True)

    # Demo mode when unconfigured
    if api_key == "":
        date_line = DEMO["date"] + " · demo"
        return render_setlist(
            DEMO["artist"],
            DEMO["venue"],
            date_line,
            DEMO["songs"],
            accent,
            show_songs,
        )

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

    songs = extract_songs(setlist)
    date_line = format_date(setlist.get("eventDate", ""))
    if len(songs) > 0:
        date_line += " · %d songs" % len(songs)

    return render_setlist(artist, venue_city, date_line, songs, accent, show_songs)

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
                desc = "Artist name color",
                icon = "brush",
                default = DEFAULT_ACCENT,
            ),
            schema.Toggle(
                id = "show_songs",
                name = "Show Songs",
                desc = "Scroll the full setlist",
                icon = "listOl",
                default = True,
            ),
        ],
    )
