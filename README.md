# tronbyt-apps

Personal custom apps for my [Tronbyt](https://github.com/tronbyt/server) server.
Set as the Custom Apps Repository under Settings → Content.

## Apps

### Setlist Tracker (`apps/setlist`)

Shows a concert setlist from [setlist.fm](https://www.setlist.fm) on the 64x32 display:
artist, venue, date + song count, and a scrolling marquee of the songs.

Modes:

- **My last concert** — most recent show marked attended on your setlist.fm account
- **Artist's latest setlist** — newest setlist for any artist

Setup: get a free API key at [setlist.fm/settings/apps](https://www.setlist.fm/settings/apps),
then enter it with your setlist.fm username (or an artist name) in the app settings.

## Development

```
pixlet serve apps/setlist/setlist.star
```

Renders live at http://localhost:8080 with a config form.
