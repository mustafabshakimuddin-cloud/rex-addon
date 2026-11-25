# Reel: improvement plan

A review of the whole app (`app/Reel`, about 10,000 lines of Swift), its CI and release tooling, and a
lighter pass over the Rex module. Every item names where the problem is and what to change. Nothing
here has been built or run yet: this container has no Xcode, so items marked *(verify)* need
reproducing on a device first.

Effort: **S** is under half a day, **M** is one to two days, **L** is three days or more.

---

## Start here: the ten highest-value changes

1. **B1**: the library is wiped if its file ever fails to decode (data loss).
2. **B9**: Play offers an episode that hasn't aired once you've caught up on a series.
3. **B18**: every Status check and every setup Test adds a torrent to your debrid account.
4. **B2/B3**: Trakt token refreshes race, and being offline is reported as "sign-in expired".
5. **B10**: playing while offline marks good sources as "Failed to play before".
6. **B14**: Retry on a failed download reuses the expired link, although Status says it fetches a fresh one.
7. **P1**: the whole tab view redraws every 10 seconds while something plays.
8. **F1**: Continue Watching drops a series as soon as you finish an episode; it should show the next one.
9. **B4–B7**: changes made here (unwatched, watched, removed from My List) don't reach Trakt or get undone by it.
10. **T1**: there are no tests; the parsing and ranking logic is pure and easy to cover.

---

## 1. Bugs

### Data and sync

- **B1. Unreadable save files are silently replaced with empty ones. [S]**
  `Library.swift:41`, `SourceMemory.swift:54` and `DownloadStore.init` decode with `try?`. If decoding
  fails (a field added to `MediaItem` without a default, a half-written file), the store starts
  empty and the next `scheduleSave` overwrites the file: the whole watchlist and history are gone.
  *Fix:* when decoding fails, move the file aside (`library.unreadable-<date>.json`) and post an
  alert. Add a `version` field, and decode entries leniently (the `Lossy<T>` wrapper already used in
  `Cinemeta.swift` would work) so one bad entry costs only that entry.

- **B2. Concurrent Trakt token refreshes. [S]**
  `TraktStore.swift:148`. `sync()`, `scrobble()` and `pushWatchlist()` each call `validToken()`. In
  the last 24 hours before expiry, a foreground sync plus a scrobble refresh at the same moment with
  the same refresh token. Trakt rotates refresh tokens, so the second refresh is refused and the user
  sees "sign-in expired". *Fix:* keep a single in-flight `Task<Trakt.Token?, Never>` and have every
  caller await it.

- **B3. Being offline is reported as an expired sign-in. [S]**
  `TraktStore.swift:148–158` turns any refresh error into "Trakt sign-in expired. Connect again".
  *Fix:* only a 400 or 401 from `/oauth/token` means signed out. A `URLError` means try later.

- **B4. Marking something unwatched is undone by the next sync. [M]**
  `Library.swift:145` removes the id from `externalWatched`, but `setExternalWatched` (`:83`) replaces
  the whole set on every sync, and nothing is sent to Trakt. *Fix:* send `/sync/history/remove`, and
  keep a local override set (id and date) until Trakt confirms the change.

- **B5. Mark as Watched never reaches Trakt. [S]**
  `Library.swift:138` (the comment says so). Films and episodes marked by hand, including "Mark
  Season as Watched", stay on this device only. *Fix:* send `/sync/history` with `watched_at`.

- **B6. Watchlist removals are never pulled down, and failed pushes come back. [M]**
  `mergeWatchlist` (`Library.swift:64`) only adds. A title removed on Trakt or on another device stays
  here for good, and a title removed here while offline is added back by the next sync, because the
  push in `TraktStore.swift:128` is `try?` and fire-and-forget. *Fix:* keep the last synced snapshot,
  so a difference can be read as a remote removal, plus a persisted queue of pending changes (F29).

- **B7. Scrobbles are dropped on any failure. [S]**
  `TraktStore.swift:137` uses `try?`. A stop scrobble sent from a train tunnel is lost, and so is
  Trakt's watched mark. *Fix:* queue `stop` scrobbles and history writes, and retry them when the
  network returns.

- **B8. Trakt's watched marks aren't saved to disk. [S]**
  `externalWatched` lives only in memory. At an offline launch, or before the first sync finishes,
  watched ticks, next-episode picks and New Episodes are all wrong. *Fix:* save it with the library.

### Playback

- **B9. Play offers an episode that hasn't aired. [S]**
  `Library.nextEpisode` (`Library.swift:190`) returns `regular[latest + 1]` without checking
  `hasAired`. Once you've watched the newest episode, the title page (`DetailView.swift:143`) shows
  "Play S03E05" for an episode that airs on Friday, which ends in "No releases were found".
  *Fix:* skip episodes that haven't aired, and show a "Caught up · S03E05 airs Fri" state with a
  rewatch option instead of Play.

- **B10. Network errors count against sources. [S]**
  `PlaybackCenter.swift:212` calls `noteFailure` for any resolve error, `URLError.notConnectedToInternet`
  and timeouts included, and the failure is also charged to the release group and the addon. Pressing
  Play in airplane mode marks up to three good sources as "Failed to play before" and sinks them in
  every future ranking. *Fix:* record only `ResolveError`s and HTTP-level failures; skip
  `URLError`s caused by the network.

- **B11. A link that expires mid-film leaves you on an error card. [M]**
  `PlayerView.swift:227` deliberately doesn't fall back after the first frame, so a long pause or a
  debrid link that expires ends playback. *Fix:* on a load error after the first frame, drop
  `resolvedCache[fileKey]`, resolve the same source again and reload at the last position once,
  silently, before showing the card. Add a **Retry** button to the card.

- **B12. Resolved links outlive a change of debrid account. [S]**
  `resolvedCache` (`PlaybackCenter.swift:80`) is keyed by file only. After switching service or key,
  links from the old account are reused for up to 30 minutes. *Fix:* include the service and a hash
  of the key in the cache key, or clear the cache when either changes.

- **B13. Screen changes are timed with fixed sleeps. [M]**
  Switching source, Up Next and falling back all wait 650 ms "to let the cover close"
  (`PlaybackCenter.swift:245, 269, 278`); `AppRouter` waits 450 and 500 ms. On a slow device, or with
  Reduce Motion, these can fire too early or late. *Fix:* chain on the `onDismiss` of the
  `fullScreenCover` and the sheet instead.

### Offline copies

- **B14. Retry reuses the expired link. [S]**
  `DownloadStore.resume` (`DownloadStore.swift:113`) starts from `item.remoteURL`, the debrid link
  resolved when the download began. Status tells the user "a fresh link is fetched if the old one
  expired" (`Health.swift:251`), but none is. *Fix:* when there is no resume data, or the server
  answers 403, 404 or 410, retry through `PlaybackCenter` and resolve the same source again.

- **B15. Pause can flip back to Downloading. [S]**
  `progressed` (`DownloadStore.swift:166`) sets the state to `.downloading` on every progress report.
  Reports already queued when Pause cancels the task arrive afterwards, so the item shows as
  downloading with no task running until the next launch. *Fix:* ignore progress for items that are
  paused or not in the session's task list.

- **B16. Downloading again leaves the old files behind. [S]**
  `start` (`:88`) replaces a paused or failed item but keeps its `.resume` file and any partly
  downloaded file. *Fix:* clean both up first.

- **B17. No free-space check and no Wi-Fi-only option. [S]**
  A 60 GB remux starts on a phone with 20 GB free, and over cellular (`allowsCellularAccess = true`).
  *Fix:* compare `source.sizeBytes` with `freeBytes` before starting, and add a "Download over
  cellular" setting, off by default.

### Status and setup

- **B18. The debrid check adds a torrent to the account every time. [M]**
  `DebridCheck.run` (`Health.swift:7`) resolves the first instant Shawshank Redemption source.
  Opening Status, or pressing Test in setup, adds that torrent to the user's debrid account again
  each time. *Fix:* check the key against the service's own account endpoint (for example
  Real-Debrid's `/rest/1.0/user`). That has no side effects and also returns when the plan expires
  (F21). Keep the full resolve path as an optional "Full test".

- **B19. Status waits for its slowest check. [S]**
  `Health.swift:415–422` awaits every network check before writing any result, so the page shows
  "Checking…" everywhere until the slowest one answers, up to 15 s or more. *Fix:* use a task group
  and update each row as its check finishes.

### Search and browsing

- **B20. Search errors look like "No results". [S]**
  `SearchView` (`BrowseView.swift` around line 358) turns errors into empty arrays with `try?`, so
  searching while offline says "Nothing matches". *Fix:* keep the error and show it with Retry.

- **B21. The spinner can stick. [S]**
  `isSearching = true` is never reset when the task is cancelled or the query is cleared mid-request.
  *Fix:* use `defer { isSearching = false }`, and clear the old results when the query changes.

- **B22. Failures with no way to retry. [S]**
  A title page that fails to load (`DetailView.swift:50`), an Explore shelf that fails ("Couldn't
  load this row.") and a grid page that fails in `BrowseModel.loadMore` all stop for good. *Fix:* give
  each one a Retry button.

- **B23. "New Movies" is nearly empty in January. [S]**
  The New rows use the current calendar year (`AppSettings.swift:228`). *Fix:* also show last year's
  list while this year's has fewer than about 20 titles.

### Release parsing and filters

- **B24. Excluding 3D does nothing for addon sources. [S]**
  `SourceFinder.passes` (`Streams.swift:324`) has no case for `threed`, and no 3D tag is detected.
  Torrentio filters 3D itself; other addons don't.

- **B25. A `.ts` file can be labelled CAM. [S]**
  When a name has no resolution, `\bts\b` (`Streams.swift:153`) matches the `.ts` extension. With
  "cam" excluded, the release is then hidden. *Fix:* strip the extension before matching, and match
  only `telesync`, `hdts` or a standalone `TS` between separators.

- **B26. Only 14 languages can be preferred. [M]**
  `Languages.options` (`OptionsPanel.swift:272`) lacks Dutch, Polish, Swedish, Hebrew, Greek, Thai,
  Vietnamese, Indonesian and more. The subtitle default is `"eng"` whatever the device language
  (`AppSettings.swift:61`). *Fix:* build the list from `Locale` with ISO 639-1/639-2 mapping, and
  default to the device's language.

### Smaller ones

- **B27.** The README still says playback goes through VLC and that VLCKit is LGPL 2.1
  (`README.md:74, 106`). The engine is AetherEngine (LGPL-3), so the licence section is wrong. [S]
- **B28.** Mark as Watched stores a 60-second duration, and Trakt imports use estimated runtimes, so
  "Hours watched" in Library's Overview (`LibraryView.swift:281`) is off. Count those entries
  separately or leave them out. [S]
- **B29.** `AlertCenter.unseenProblems` isn't saved, so the gear's red dot disappears on relaunch
  while the problem is still in the list. [S]

---

## 2. Performance

- **P1. Playback redraws the whole tab view every 10 seconds. [M]**
  While a film plays, `Library.record` publishes `progress` every 10 s. `RootView` observes `Library`,
  so each time it builds `Attention` again (`RootView.swift:104`), works out `followedSeries` for its
  `.task(id:)` (`:168`, which sorts up to 1,500 entries), and re-evaluates every tab. `HomeView` does
  the same. *Fix:* move to `@Observable` (iOS 17+; the target is 26) so views track only the
  properties they read, or split progress into its own object. Also don't publish progress while the
  player is open: keep it in memory and write it when the player closes.

- **P2. Library's derived lists are recomputed on every read. [S]**
  `continueWatching` and `history` sort every entry each time they are read. The Overview reads
  `history` five or more times per render (`LibraryView.swift:280–292`). *Fix:* cache them, keyed by a
  revision counter that every change increments.

- **P3. New Episodes is computed five times per render. [M]**
  `unwatchedNew` runs for `Attention` (twice: `newEpisodes` and `newEpisodeCount`), for Home's New
  Episodes row (twice) and for the badge. Each run calls `furthestEpisode` for every series, which
  scans all progress and all of Trakt's watched episodes (often 10,000+). *Fix:* work out each
  series' furthest episode once per library revision and reuse it.

- **P4. Sources are ranked over and over. [S]**
  `SourceRanker.rank` runs the `releaseGroup` regex (`Streams.swift:38`) and the memory lookups
  inside the sort comparator, which means O(n log n) regex runs. `SourcesSheet` ranks again for
  "recommended" and for every quality group on every render, including each time a "Check" spinner
  changes. *Fix:* compute each source's sort key once, then sort, and memoize the result per list.

- **P5. Regexes are compiled on every use. [S]**
  `StremioStreams.capture` builds a new `NSRegularExpression` per call, several per stream and
  hundreds per search. *Fix:* compile them once, as statics or Swift `Regex` literals.

- **P6. Saving the library on the main thread. [S]**
  `saveNow()` encodes up to 1,500 entries on the main thread whenever the app goes to the background
  and whenever the player closes. *Fix:* encode the snapshot off the main thread. If history keeps
  growing, move to SQLite or SwiftData.

- **P7. Downloads' storage total reads the disk on each access. [S]** `usedBytes` stats every file on
  every read. Keep a running total and update it when a download finishes or is deleted.

- **P8. The calendar loads in sequence. [S]** `Cinemeta.calendar` fetches its 40-series chunks one
  after another (`Cinemeta.swift:90`). Fetch two or three at a time instead.

- **P9. Trakt sync downloads the full history on every foreground. [M]** Call `/sync/last_activities`
  first and fetch only what changed since the last sync.

- **P10. Fast browsing fires many source searches. [S]** Each title page opened starts a Torrentio
  plus addon search through `prefetch`, and nothing cancels it. Debounce it by a second, and cancel
  it when the page closes.

- **P11. Images. [S]** Prefetch the posters just off-screen in shelves, and request Metahub's small
  size for small cards.

- **P12. CI builds from scratch every time. [S]** Cache SwiftPM checkouts and DerivedData with
  `actions/cache`; AetherEngine's prebuilt stack is downloaded again on every push.

---

## 3. Features

### Playback

- **F1. Up Next in Continue Watching. [M]** After you finish an episode, show the next aired one
  (with its thumbnail and "S2E4 · New") instead of dropping the series. This is what Continue
  Watching is mostly for on a series.
- **F2. Player gestures. [M]** Double-tap the left or right side to skip 10 s (move fill to a pinch),
  swipe up or down at the edges for brightness and volume, and hold for 2× speed.
- **F3. Keyboard control on iPad. [S]** Space to play and pause, ←/→ to skip, ↑/↓ for volume, F for
  fill, C for subtitles, Esc to close.
- **F4. Sleep timer. [S]** End of episode, 15, 30 or 60 minutes.
- **F5. Remember choices per series. [S]** Subtitle delay, audio and subtitle track, fill mode, and
  speed, kept for each series (and the subtitle delay for each file).
- **F6. Learned Skip Intro. [M]** When a release has no chapters, remember where you skipped in one
  episode and offer the same skip in the next episodes of that release group. Optionally use
  community intro timestamps (AniSkip for anime).
- **F7. Automatic skipping. [S]** Settings to skip recaps and intros without a tap.
- **F8. Lock-screen artwork. [S]** `PlayerModel.start` sets only the title and subtitle; add the
  poster or episode thumbnail as `MPMediaItemPropertyArtwork`.
- **F9. Prepare the next episode early. [S]** Resolve the next episode's top source when the Up Next
  card appears, not when it is pressed.
- **F10. More subtitle sources. [M]** Import a subtitle file from Files, and read subtitles from
  Stremio addons that offer the `subtitles` resource; addons are used for streams only today.
- **F11. More subtitle styling. [S]** More colours, background opacity, vertical position, and an
  option to follow Dynamic Type.
- **F12. Night mode. [M, verify]** Dynamic range compression and dialogue boost, if AetherEngine
  exposes the audio graph.
- **F13. Stream health in Info. [S]** Bitrate, buffer ahead, dropped frames and rebuffer count.

### Sources

- **F14. Source preferences. [M]** Prefer or avoid HDR or Dolby Vision, a codec, Atmos, remuxes on
  cellular, dubbed or original audio, and chosen release groups; set a maximum bitrate on cellular.
  `SourceRanker` currently knows only quality, cache state and history.
- **F15. Rank by what the device can play. [M]** Push down Dolby Vision profile 5 and 7 and HDR on
  screens that can't show them (`AVPlayer.availableHDRModes`), and AV1 on chips without hardware
  decode (`VTIsHardwareDecodeSupported`).
- **F16. Filter in the Sources sheet. [S]** Text search, chips for HDR, DV, Atmos, Remux, language
  and addon, a size range, and "Check top 5".
- **F17. Torrentio's other options. [S]** A self-hosted server address (`Torrentio.base` is fixed),
  language priority, minimum seeders and results per quality. The Rex module already has all of
  these.
- **F18. Addon catalogues. [L]** Use addons' `catalog` and `meta` resources too (anime catalogues,
  TMDB-based ones), add a Configure link per addon, and show per-addon response times in Status.
- **F19. More than one debrid service. [M]** Try a second service when the first has nothing cached.

### Debrid account

- **F20. Sign in to debrid without pasting a key. [M]** Real-Debrid, AllDebrid and Premiumize offer
  device-code or PIN sign-in, like the Trakt flow already in the app.
- **F21. Account status and cloud. [M]** Show days left on the plan, warn in Waiting on You a week
  before it ends, and add a "Debrid Cloud" page to play what is already in the account.

### Discovery

- **F22. Better recommendations. [L]** With an optional TMDB key: trending, recommendations for
  More Like This (today it's popular titles in the same genre), cast photos, collections and season
  posters. Without a key, Trakt's trending, anticipated and recommended lists.
- **F23. Trakt lists and ratings. [M]** Personal lists, collection, and rating a title after it ends.
- **F24. Hide watched. [S]** A toggle on Explore rows and grids.
- **F25. More genres and sorting. [S]** Biography, Music, Sport, Reality and Talk for series; sort a
  grid by year or rating.
- **F26. People. [S]** Photos and filmography by year on person pages (with TMDB).

### Library and sync

- **F27. A queue for Trakt changes. [M]** One persisted queue for watchlist, history and scrobble
  writes, retried with backoff; this fixes B4–B7 together.
- **F28. Back up and restore. [S]** Export and import the library, settings, addons and source memory
  as a file. For a sideloaded app this matters: a reinstall or a failed re-sign can wipe its data.
- **F29. iCloud sync. [L]** Keep the library and settings in step across iPhone and iPad without
  Trakt (CloudKit, or `NSUbiquitousKeyValueStore` for the settings).
- **F30. Lists beyond My List. [M]** Your own collections, and notes or ratings per title.

### System integration

- **F31. Notifications. [M]** New episodes of the series you follow (a `BGAppRefreshTask` that checks
  the calendar), and downloads finishing while the app is in the background. Alerts are in-app
  only today.
- **F32. Widgets. [M]** Continue Watching and Airing Today; a Live Activity for a running download.
- **F33. Shortcuts and Siri. [M]** App Intents for "Resume", "Play the next episode of …" and
  "Search Reel".
- **F34. Links into the app. [S]** A `reel://title/tt…` scheme, opening IMDb links pasted or shared,
  and a share extension, so a title in Safari or Letterboxd opens in Reel.
- **F35. Spotlight and Handoff. [M]** Index My List; hand a playing title, with its position, from
  iPhone to iPad.
- **F36. Tap the tab to go back. [S]** Tapping the current tab again pops to its root and scrolls to
  the top. Explore, Calendar and Search have no path in `AppRouter`, so this needs one each.
- **F37. Calendar export. [S]** Add upcoming episodes to the iOS calendar, or export an `.ics` file.

### Offline copies

- **F38. Download a season. [M]** Download a season or the next N episodes, optionally download new
  episodes on Wi-Fi as they air, and delete watched copies after a set time.
- **F39. Download preferences. [S]** A size ceiling and quality for downloads (smaller than for
  streaming), and a storage limit.
- **F40. Subtitles for offline. [S]** Save the preferred-language OpenSubtitles file with the
  download.

### Settings and the rest

- **F41. Localisation. [M]** Move strings into a String Catalog. The Rex module already ships Chinese.
- **F42. Profiles. [L]** Separate history, My List and Trakt per person, with an optional rating
  limit for children.
- **F43. Accessibility. [M]** One combined VoiceOver label per poster (name, year, rating, mark);
  stop the featured row from advancing when Reduce Motion is on; Dynamic Type for the hard-coded
  sizes in the player; a scrubber step that suits the length of the film (30 s is tiny for a
  3-hour film).

---

## 4. Code quality, tests and tooling

- **T1. A test target. [M]** Use Swift Testing for the pure logic: `StremioStreams` parsing with saved
  Torrentio, Comet and MediaFusion responses; `TorrentioConfig.pathSegment`; `SourceFinder.passes`
  and `merge`; `SourceRanker`; `ResolveError(errorVideo:)`; `Library.nextEpisode`,
  `furthestEpisode` and `continueWatching`; `UpcomingStore.unwatchedNew`; Cinemeta decoding;
  `ChapterKind`; `Languages`. Run it in the existing simulator job.
- **T2. One persistence helper. [S]** `Library`, `SourceMemory`, `DownloadStore` and `AlertCenter`
  each have their own save code. Replace them with one `JSONStore<T>` that handles versions,
  unreadable files (B1), atomic writes and debouncing.
- **T3. Swift 6 and `@Observable`. [L]** `project.yml:17` pins `SWIFT_VERSION: "5.0"`. Strict
  concurrency would catch the `@unchecked Sendable` and detached-task patterns, and `@Observable`
  fixes much of P1.
- **T4. One HTTP client. [S]** Per-host timeouts, retry with backoff for GETs, and a User-Agent with
  the real version (`"Reel/1.0"` is hard-coded in three places).
- **T5. Diagnostics. [M]** Log with OSLog, add a log viewer, and let the Status report include recent
  errors, with debrid keys removed from any URL first. The Torrentio path carries the key, so the
  redaction needs a test of its own.
- **T6. Narrower App Transport Security. [S]** `NSAllowsArbitraryLoads: true` (`project.yml:67`)
  allows plain HTTP for everything. Keep `NSAllowsArbitraryLoadsForMedia`, and warn when an addon's
  address is `http://`: its stream links may carry the debrid key unencrypted.
- **T7. Releases you can roll back. [S]** The workflow deletes every older release, so a bad build
  can't be undone from the store. Keep the last three, and write release notes from the commits since
  the previous tag rather than the last commit's first line.
- **T8. Lint and format. [S]** SwiftFormat and SwiftLint in CI.
- **T9. Screenshot checks. [M]** `ScreenshotTour` (`-ReelShot`) already opens every screen. Compare
  the shots against references, and fail on horizontal overflow (the Duo bugs fixed earlier).
- **T10. A mock mode. [M]** A `-ReelMock` flag that serves saved JSON, so CI and screenshots don't
  depend on Cinemeta and Torrentio being up.
- **T11. Split the largest files. [S]** `PlayerView.swift` (644 lines) and `BrowseView.swift` (556).

## 5. Rex module

- **R1. [S]** Node tests for `buildTorrentioConfig`, `parseTorrentioLink` and `toVideoResources`.
- **R2. [S]** A CI step that runs `tools/build.js` and fails if `manifest.json` no longer matches the
  module's version.

---

## 6. Suggested order

1. **Stop losing data and fix wrong answers** (about a week): B1, B9, B10, B14, B18, B2, B3,
   B20–B22, T1, T2.
2. **Sync and speed**: F27 (which covers B4–B7), B8, P1–P5, P9, T3.
3. **Playback**: F1, B11, F2, F3, F5, F8, F9, F14, F15.
4. **Living outside the app**: F28, F31, F32, F34, F36.
5. **Bigger bets**: F22 discovery, F21 debrid account and cloud, F20 debrid sign-in, F29 iCloud,
   F41 localisation.
