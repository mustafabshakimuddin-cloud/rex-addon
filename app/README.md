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

The store shows each new build as an update. Every push to `main` publishes one: a permanent
release `v0.1.N` holding that build's `.ipa`, and the rolling `latest` release holding the newest
`.ipa` and `source.json`. `tools/make_source.py` writes the source and keeps the last few versions.

**By hand.** Download `Reel.ipa` from the
[latest release](https://github.com/mustafabshakimuddin-cloud/rex-addon/releases/tag/latest) and
install it with Sideloadly.

With a free Apple ID a signature lasts 7 days; SideStore and AltStore refresh it in the background.

## First run

Settings → Debrid Service → pick your service, paste its API key, **Save and Test**. "Working"
means the same path playback uses succeeded (search, then resolve an instant source).

## How playing works

**Play** asks Torrentio for releases, takes the first *instant* (already cached) one, asks the
debrid service to prepare it through Torrentio's resolve link, and hands VLC the final direct HTTPS
address. If a release fails it tries the next, up to three. **Sources** lists everything with
quality, HDR/Dolby Vision tags, size, seeders and provider, to pick one yourself.

Torrentio's resolve links redirect to short explanatory videos when something is wrong (key
refused, not cached yet, file too big). The app reads the redirect itself and shows the reason as a
message instead of playing that clip.

## iPhone Duo and iOS 27

- Built with Xcode 27.1 (the `xcode-27` GitHub-hosted runner), which is what lets the unfolded
  iPhone Duo resize the app instead of letterboxing it.
- Navigation is a system `TabView` with `.sidebarAdaptable`: a Liquid Glass tab bar on narrow
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

VLCKit is LGPL 2.1 and is linked as the `VLCKitSPM` binary package. Cinemeta and Torrentio are
third-party services; the app hosts and stores no media.
