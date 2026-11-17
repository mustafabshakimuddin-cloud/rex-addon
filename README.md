# rex-addon

Modules for the [Rex](https://rexnow.tv) media player.

## Torrentio — `rex.torrentio.js`

Lists torrent streams from [Torrentio](https://torrentio.strem.fun) when you start playing a
movie or episode, and plays them through a debrid service (Real-Debrid, AllDebrid, Premiumize,
TorBox, Debrid-Link, EasyDebrid, Offcloud, Put.io).

### Install

Add this repository as a **module collection** in Rex (Settings → Modules → Add via Link):

```
https://raw.githubusercontent.com/mustafabshakimuddin-cloud/rex-addon/main/manifest.json
```

It appears on the Modules screen as its own collection, beside "Rex official modules", and
Rex offers updates when the version in `manifest.json` goes up. To install the module on its
own instead, use the module link:

```
https://raw.githubusercontent.com/mustafabshakimuddin-cloud/rex-addon/main/rex.torrentio.js
```

Then open the module's settings, choose your debrid service and paste its API key.

When you change `rex.torrentio.js`, bump `version` in its `WidgetMetadata` **and** in
`manifest.json` together, or Rex will not see the update.

### Settings

| Setting | Torrentio option | Notes |
|---|---|---|
| Server | — | Defaults to `https://torrentio.strem.fun`; change it for a self-hosted instance. |
| Debrid Service / API Key | `realdebrid=…`, `torbox=…`, … | Needed to play anything (see below). |
| Cached Only | `debridoptions=nodownloadlinks` | Hides torrents the debrid service would have to download first. |
| Magnet Links | — | Without debrid, show results as `magnet:` links instead of hiding them. |
| Providers | `providers=` | Comma list, e.g. `yts,eztv,1337x`. Empty searches all of them. |
| Exclude Qualities | `qualityfilter=` | e.g. `scr,cam,unknown`, `480p`, `4k`, `dolbyvision`. |
| Sort | `sort=` | `quality` (default), `qualitysize`, `seeders`, `size`. |
| Results per Quality | `limit=` | |
| Priority Language | `language=` | e.g. `english`, `french`. |
| Max Size | `sizefilter=` | e.g. `10GB`. |
| Minimum Seeders | `minseeders=` | |
| TMDB API Key | — | Only used when Rex supplies a TMDB ID but no IMDb ID. |

### Things to know

- **A debrid service is what makes streams playable.** Without one, Torrentio returns only
  torrent hashes, which a regular video player cannot open. The module then reports how many
  torrents it found instead of listing sources that will not play.
- **Torrentio looks titles up by IMDb ID.** If Rex passes only a TMDB ID, the module converts
  it through Rex's built-in TMDB access when available, then through the optional TMDB API key.
- **Your debrid key is part of every playback link** (`/resolve/<service>/<key>/…`), exactly as
  in Stremio. It is stored in Rex's settings on your device, never in this repository.
