# Reel

An iOS app for browsing films and series and streaming them through Torrentio and your own debrid
service. "Reel" is a working name: change `AppConfig.name` and `CFBundleDisplayName` in
`project.yml`.

- **Catalogue**: [Cinemeta](https://v3-cinemeta.strem.io): popular and top-rated lists, genres,
  search, title details and episode lists. No account needed.
- **Sources**: [Torrentio](https://torrentio.strem.fun), using your debrid service (Real-Debrid,
  AllDebrid, Premiumize, TorBox, Debrid-Link, EasyDebrid, Offcloud, Put.io). Without one there is
  nothing playable: torrents themselves are never downloaded on the device.
- **Player**: AetherEngine (FFmpeg demuxing, Apple's hardware decoders), so MKV, HEVC, AV1, Dolby Vision, HDR10+, Atmos and embedded subtitles play.

## Install

**SideStore, AltStore or Feather (recommended).** Add this source, then install Reel from it:

```
https://github.com/mustafabshakimuddin-cloud/rex-addon/releases/download/latest/source.json
```

The store shows each new build as an update. Every push to `main` publishes one: a release
`v0.1.N` holding that build's `.ipa`, which replaces the previous one, and the rolling `latest`
release holding only `source.json`. Only the newest build is ever listed. `tools/make_source.py` writes the source and keeps the last few versions.

**By hand.** Download the newest build,
<https://github.com/mustafabshakimuddin-cloud/rex-addon/releases/latest/download/Reel.ipa>, and
install it with Sideloadly.

With a free Apple ID a signature lasts 7 days; SideStore and AltStore refresh it in the background.

## First run

Setup opens on first launch: pick a debrid service and test its key, add Stremio addons, choose how
Play behaves, connect Trakt. Every step but the first can be skipped; the last page lists what is
set and what isn't. Run it again from Settings → Run Setup Again. "Working" means the same path
playback uses succeeded (search, then resolve an instant source).

## Screens

- **Home**: the featured carousel, then *Waiting on You* (setup that stops anything streaming, a
  stopped Trakt sync, a debrid plan about to end, new episodes, episodes airing today), Continue
  Watching (with the next episode once you finish one), New Episodes, My List, catalogue rows and,
  with Trakt connected, trending and recommended rows. A red badge on the tab counts what needs you; a red dot on the gear
  means Settings has something to fix. Choose and reorder sections under Settings → Home Screen.
- **Explore**: movies and series in one place. *Rows* shows a shelf per list and genre, each with
  See All; *Grid* shows one list (Popular, New by year, Top Rated) with its filters.
- **Calendar**: new and upcoming episodes of the series in My List and those you've watched lately,
  by day, as *Cards* or a *List*; *Recent* looks back a month.
- **Library**: History and Calendar at the top, Continue Watching, then My List as *Posters*,
  *Rows*, *Banners* or an *Overview* of counts, hours watched and your genres. Filter and sort it.
- **Offline copies**: streaming is the point; a download is an occasional extra for a flight. Once
  one exists, Library links to a live list with progress, speed, time left and storage, where
  everything can be paused, resumed, or deleted once watched.
- **History**: what you've played, grouped by day, with watched marks and resume points.
- **Search**: recent searches, a top result, and a *People* scope that finds titles by cast or
  director. Cast and directors on title pages open the same person page.
- **Title pages**: where the title stands in your library (listed, watched, downloaded, next
  episode date), mark films, episodes or whole seasons watched, share or open in IMDb, and More
  Like This.
- **Sources**: the pick rules in force, with a link to change them, and how many releases are
  instant and which addons they came from.
- **Settings → Status**: every link in the streaming chain is checked (debrid key, Torrentio,
  Cinemeta, each addon, pick rules, Trakt; offline copies and storage only when there are some) and
  marked OK, WARN, FAIL or Not set, each with what to do and a button to go there. Recent alerts are listed below; the report can be shared.
- **Settings → Appearance**: accent colour, poster size, ratings on posters and whether the featured
  row moves by itself.
- **Alerts**: a pop-up when Trakt stops syncing or an offline copy finishes or fails, with a button
  to the right place.
- **Keyboard** (iPad): ⌘1–4 switch tabs, ⌘F searches, ⌘Y opens History, ⇧⌘S Status, ⌘, Settings.
  Tapping the current tab again goes back to its first screen, then to the top.
- **Outside the app**: notifications for new episodes and finished downloads; My List in Spotlight;
  Handoff of the title on screen; Shortcuts for *Resume Watching* and *Search*; links of the form
  `reel://title/tt0111161?type=movie`, and IMDb links pasted into Search; upcoming episodes
  exported to Calendar.

## How playing works

**Play** asks Torrentio for releases, takes the first *instant* (already cached) one, asks the
debrid service to prepare it through Torrentio's resolve link, and hands the player (AetherEngine)
the final direct HTTPS address. If a release fails it tries the next, up to three; being offline
doesn't count against a release. If a link expires mid-film, the same release is resolved again
and playback carries on where it stopped. **Sources** lists everything with quality, HDR/Dolby
Vision tags, size, seeders and provider, with a search field and tag filters, to pick one yourself.

Within a quality, **source preferences** decide (Settings → Pick Rules): HDR, Dolby Vision, Atmos
and remuxes can be preferred or avoided, release groups favoured, releases in your audio language
put first, and formats this device can't show or decode in hardware passed over.

The debrid key is checked against the service's own account page (Real-Debrid, AllDebrid,
Premiumize, TorBox, Debrid-Link, Put.io), which adds nothing to the account and tells the app when
the plan ends; Home warns a week before.

Torrentio's resolve links redirect to short explanatory videos when something is wrong (key
refused, not cached yet, file too big). The app reads the redirect itself and shows the reason as a
message instead of playing that clip.

## iPhone Duo and iOS 27

- Built with Xcode 27.1 (the `xcode-27` GitHub-hosted runner), which is what lets the unfolded
  iPhone Duo resize the app instead of letterboxing it.
- Navigation is a system `TabView` with `.sidebarAdaptable` (Home, Explore, Calendar, Library, Search): a Liquid Glass tab bar on narrow
  windows, a sidebar or the system's vertical rail on wide ones. A hand-drawn tab bar would get
  neither.
- No `UIRequiresFullScreen`, every orientation, and layouts that follow size classes and measured
  widths; nothing checks the device model, orientation or `UIScreen.main`.
- The player letterboxes 16:9 on the near-square inner display by default; double-tap or the fill
  button crops to fill.

## Building

```sh
cd app
xcodegen generate
open Reel.xcodeproj
```

The icon is drawn by `tools/make_icon.py`.

## Licences

AetherEngine is LGPL 3 with an App Store exception and bundles FFmpeg (LGPL). Cinemeta, Torrentio,
OpenSubtitles and Trakt are third-party services; the app hosts and stores no media.

## Player

Double-tap the left or right of the picture to skip 10 seconds, the middle to fill; pinch to fill
or fit; hold for double speed. On a keyboard: space, ←/→ (⇧ for a minute), F, C, Esc. A sleep
timer is under Speed. Each series remembers its audio and subtitle language, subtitle timing,
fill and speed, and an intro you scrub past is offered as Skip Intro in the next episodes.

## Saved data

The library, source memory, downloads index and pending Trakt changes are JSON files in
Application Support. A file that can't be read is renamed `*.unreadable-<date>.json` and kept,
never overwritten. Settings → Back Up and Restore writes everything but credentials to one file.

## Tests

`ReelTests` covers release parsing, ranking, Torrentio options, redaction and the library's rules
(unaired episodes, Up Next, Trakt merges). CI runs it on a simulator.
