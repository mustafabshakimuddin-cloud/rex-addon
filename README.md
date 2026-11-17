# rex-addon

- **[`app/`](app/README.md): Reel**, an iOS app (iPhone, iPad, iPhone Duo) for browsing films and
  series and streaming them through Torrentio and your debrid service, with a VLC-based player.
- **`rex.torrentio.js`**: a module for the Rex player (below). Rex 1.1 does not play streams from
  imported modules, which is why the app exists.

Modules for the [Rex](https://rexnow.tv) media player.

## Torrentio — `rex.torrentio.js`

Browse popular movies and series (from [Cinemeta](https://v3-cinemeta.strem.io), Stremio's
catalogue), see how many [Torrentio](https://torrentio.strem.fun) sources each title has, and send
the best cached torrent to your debrid account (Real-Debrid, AllDebrid, Premiumize, TorBox,
Debrid-Link, EasyDebrid, Offcloud, Put.io).

### Why it works this way

Rex 1.1 on iPhone does not play anything an **imported** module provides. Tested on a device:

- a `type: "stream"` / `loadResource` module is dropped from the module and never called, whether
  it sits beside a list or in a widget of its own (a stream-only widget is hidden entirely);
- a `videoUrl` is ignored, on a list item and on a `loadDetail` page alike, even for a public
  sample `.mp4`.

Rex's own film pages do play files from its **libraries**, and Rex can add a WebDAV drive as one.
Debrid services expose your account's files over WebDAV, so the working setup is:

1. **Add your debrid service's WebDAV as a Rex library** (Library → add → Network Drive →
   WebDAV). For Real-Debrid the server is `dav.real-debrid.com`, the user is your Real-Debrid
   username, and the password is the separate **WebDAV password** shown on your Real-Debrid
   account page, not your login password. Choose the torrents folder to scan; Rex organizes the
   files into movies and shows.
2. **Turn on "Add to Debrid When Opened"** in this module's settings. Opening a title from the
   Popular list then sends its best cached torrent to your debrid account (for a series, the
   source for season 1, episode 1, often a season pack). The first line of the description says
   what happened.
3. **Refresh the library in Rex.** The title appears on Rex's normal page with a playable source.

The `loadResource` stream module is kept so the module starts working by itself if Rex enables
resource modules for imported modules.

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
| Add to Debrid When Opened | — | Off by default. When on, opening a title's page sends its best cached torrent to your debrid account. |

### Things to know

- **A debrid service is what makes streams playable.** Without one, Torrentio returns only
  torrent hashes, which a regular video player cannot open. The module then reports how many
  torrents it found instead of listing sources that will not play.
- **Torrentio looks titles up by IMDb ID.** If Rex passes only a TMDB ID, the module converts
  it through Rex's built-in TMDB access (`Widget.tmdb`), and only needs the optional TMDB API
  key if that is unavailable.
- **Your debrid key is part of every Torrentio link** (`/resolve/<service>/<key>/…`), exactly as
  in Stremio. It is stored in Rex's settings and in the module's own storage on your device
  (detail pages run separately from the list and cannot see the settings otherwise), never in
  this repository.
