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
https://github.com/mustafabshakimuddin-cloud/Reel-Media-Center/releases/download/latest/source.json
```

The store shows each new build as an update. Every push to `main` publishes one: a release
`v0.1.N` holding that build's `.ipa`, which replaces the previous one, and the rolling `latest`
release holding only `source.json`. Only the newest build is ever listed. `tools/make_source.py` writes the source, listing just that version.

**By hand.** Download the newest build,
<https://github.com/mustafabshakimuddin-cloud/Reel-Media-Center/releases/latest/download/Reel.ipa>, and
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

## Apple TV

`ReelTV` is the same app for tvOS 26: the stores, services and screens in `Reel/` are shared, with
tvOS branches where the platform differs (`Views/PlatformSupport.swift`), and `ReelTV/` holds what
only Apple TV has. Every release carries `ReelTV.ipa`
(<https://github.com/mustafabshakimuddin-cloud/Reel-Media-Center/releases/latest/download/ReelTV.ipa>);
install it with Sideloadly, which signs it with your Apple ID (a free one lasts 7 days).

- **Remote**: in the player, Select shows the controls, and held it plays at double speed. With
  Skip Intro or Up Next on screen, Select takes it. Left and right skip 10 seconds; on the timeline
  they scrub with a preview (steps grow while you keep going), Select jumps and Back cancels. Swipe
  down for audio, subtitles, speed and playback info. Play/Pause plays and pauses; Back closes what
  is open, then the player.
- **Everywhere else**: hold Select on a poster, episode or source for its menu (the iPhone's
  long-press and swipe actions). Buttons that sit in the iPhone's navigation bar are a row at the
  top of the screen. Sliders are − and + buttons.
- **Nearest equivalents**: the widgets become a **Top Shelf** (Continue Watching and Next
  Episodes) and new episodes a **badge** on the icon, since tvOS shows no notification banners.
  Links, Share and Open in IMDb show a **QR code** for your phone; Trakt's sign-in code comes with
  one too. **Back Up and Restore** serves a small page on your home network: scan the code and
  your phone saves the backup or sends one back.
- **Not on Apple TV**: Live Activities, Spotlight, Shortcuts, Handoff search, Add to Calendar and
  AirPlay (Apple TV is the receiver). Apple TV keeps app data only in a cache it may clear when
  storage runs short, so keep a backup, or connect Trakt.

## Mac

`ReelMac` is the same app for macOS 26 on Apple silicon: the screens in `Reel/` with macOS
branches, plus `ReelMac/`. Every release carries `Reel-macOS.zip`
(<https://github.com/mustafabshakimuddin-cloud/Reel-Media-Center/releases/latest/download/Reel-macOS.zip>).
Unzip it and move Reel to Applications. It is signed ad hoc rather than by a developer ID, so the
first time, right-click it and choose Open (or allow it under System Settings → Privacy &
Security).

- **Window and menus**: a sidebar for Home, Explore, Calendar, Library and Search; the Go menu and
  shortcuts of the iPad app (⌘1–4, ⌘F, ⌘Y, ⇧⌘S, ⌘, for Settings); the attention count on the Dock
  icon. Closing the window keeps Reel running, as Mac apps do.
- **Player**: a window of its own, which can be resized, moved to another display or made full
  screen while the library stays open. Moving the pointer shows the controls; double-click the
  middle for full screen, the sides to skip 10 seconds; pinch to fill. Keys: space, ←/→ (⇧ for a
  minute), F to fill, C for subtitles, Esc to close. AirPlay and Picture in Picture are in the
  controls.
- **HDR on This Display** (Settings → Player): Dolby Vision and HDR10+ go through Apple's own
  mapping, which fits them to any HDR display, HDR10 monitors without Dolby Vision included. With
  *Map Dolby Vision to this display* on, the app tells the engine the display can take Dolby
  Vision, so Profile 7 and AV1 Dolby Vision reach that mapping instead of playing as their HDR10
  base layer; if macOS refuses, the engine falls back to the base layer in place. *Tone map HDR10
  to this display* maps HDR10 graded brighter than the monitor down to its peak (the engine's
  BT.2390 tone map), so highlights roll off instead of clipping. The peak is estimated from the
  display's HDR headroom, or set it from the monitor's specifications. While a title is tone
  mapped it plays on the engine's own renderer, without Picture in Picture or AirPlay of the
  picture. Playback info shows whether the tone map runs, from which peak and to which.
- **Not on the Mac**: Live Activities and the iPhone widgets (no Mac widget extension yet), the
  background refresh (episode notifications scheduled earlier still arrive).

## Building

```sh
cd app
xcodegen generate
open Reel.xcodeproj      # schemes: Reel (iPhone and iPad), ReelTV (Apple TV), ReelMac (Mac)
```

The icon is drawn by `tools/make_icon.py`, and the layered Apple TV icon and Top Shelf images by `tools/make_tv_icon.py`, the Mac icon set by `tools/make_mac_icon.py`.

## Licences

AetherEngine is LGPL 3 with an App Store exception and bundles FFmpeg (LGPL). Cinemeta, Torrentio,
OpenSubtitles and Trakt are third-party services; the app hosts and stores no media.

## Player

Double-tap the left or right of the picture to skip 10 seconds, the middle to fill; pinch to fill
or fit; hold for double speed. On a keyboard: space, ←/→ (⇧ for a minute), F, C, Esc. A sleep
timer is under Speed. Each series remembers its audio and subtitle language, subtitle timing,
fill and speed, and an intro you scrub past is offered as Skip Intro in the next episodes.

## More in this version

- **Audio**: night mode, a dialogue boost and a lift for quietly mixed films (Audio tab in the
  player, or Settings → Player). Playback info shows bitrate, audio sync and cache.
- **Two debrid services**: a second one is searched alongside the first and fills in what it
  hasn't cached. **Library → Files** lists what's already in a Real-Debrid, AllDebrid, Premiumize
  or TorBox account and plays it.
- **Addon catalogues** appear as rows in Explore. **TMDB** (optional key) adds cast photos and
  biographies. **More Like This** uses Trakt's related titles when a Trakt app is set.
- **Lists** of your own next to My List, plus your Trakt lists, in Library; *Add to List* is in
  every title's menu.
- **Profiles**: each person has their own My List, history, lists, player choices and Trakt
  account; a kids profile shows family and animation titles only.
- **Widgets**: Continue Watching and Next Episodes, and downloads as a Live Activity. They need
  the app group `group.community.reel.app`, which CI signs into the app; with a free Apple ID
  the widget extension uses one more of the week's App IDs.
- **Languages**: English, Simplified Chinese, Spanish, French and German.

## Saved data

The library, source memory, downloads index and pending Trakt changes are JSON files in
Application Support. A file that can't be read is renamed `*.unreadable-<date>.json` and kept,
never overwritten. Settings → Back Up and Restore writes everything but credentials to one file.

## Tests and checks

`ReelTests` covers release parsing, ranking, Torrentio options, redaction, the library's rules
(unaired episodes, Up Next, Trakt merges), lists, profiles and the mock server. CI runs it on a
simulator, lints with SwiftLint (reporting only), and takes screenshots with `-ReelMock`, which
answers every request from fixed data. Screens that differ from `ReelTests/Screenshots` are
reported as warnings; to refresh a reference, copy the run's `*-small.jpg` into that folder.
