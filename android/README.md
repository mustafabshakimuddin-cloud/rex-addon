# Reel for Android and Android TV

The same app as [Reel for iOS](../app/README.md), for Android phones, tablets, foldables and
Android TV, in one APK. It finds films and series in Cinemeta's catalogue and plays them through
your debrid service, with sources from Torrentio and any Stremio addons you add.

## Install

Download the newest build and open it on the device:

<https://github.com/mustafabshakimuddin-cloud/Reel-Media-Center/releases/download/android-latest/Reel.apk>

Android asks once to allow installs from your browser or file manager. On **Android TV**, copy
the APK over with a file manager app (or `adb install Reel.apk`); Reel then appears among the
apps with its banner.

Every push to `main` replaces that file with a new build. Builds signed with the project's
release key install over the previous one; see *Signing* below.

## What's the same as iOS

Everything a viewer does: Home with the featured row, Waiting on You, Continue Watching (with the
next episode), New Episodes, My List and catalogue rows; Explore in rows or a filtered grid with
addon catalogues; Calendar; Library with History, lists, Downloads and the debrid account's own
files; Search with People and pasted IMDb links; title pages; the source list with filters,
recommendations and format checks; profiles; Trakt (watchlist, history, resume points, ratings,
scrobbling, lists); Status; Setup; Back Up and Restore; the five languages.

The logic is a line-by-line port of the iOS app's in [`core/`](core/src/main/kotlin/community/reel/core):
release parsing, ranking and source memory, Torrentio options, resolving and fallbacks, the
library's rules, the Trakt queue, the settings (stored under the same keys, so a backup made on
one platform restores on the other). The iOS logic tests are ported to JUnit and run on any JVM.

## Where Android differs

Where a platform can't do the same thing, Reel does the nearest one:

| iOS | Android |
|---|---|
| AetherEngine (FFmpeg + Apple's decoders) | Media3 ExoPlayer, with Jellyfin's FFmpeg decoder for DTS, TrueHD and other audio Android lacks. Dolby Vision, HDR10+ and Atmos depend on the device. |
| Skip Intro from the file's chapters | Media3 doesn't read MKV chapters, so Skip Intro comes from where you skipped in an earlier episode (iOS does this too, as a fallback). |
| Live Activity for a download | An ongoing notification with progress; a foreground service keeps the download running with the app closed. |
| Background URLSession | HTTP range requests: an interrupted download carries on from the bytes already saved. |
| Keychain | Credentials encrypted with a key held in the Android Keystore. |
| WidgetKit widgets | Glance home-screen widgets: Continue Watching and Next Episodes. |
| Shortcuts, Spotlight, Handoff | App shortcuts on the icon (Continue Watching, Search, Downloads), `reel://` and IMDb links, and IMDb links shared from other apps. |
| AirPlay | Not on Android (Google Cast needs a receiver app); picture-in-picture and the media notification are there. |
| Night mode, dialogue lift | The platform's DynamicsProcessing and LoudnessEnhancer effects. |
| Subtitle timing | A shifted clock on Media3's text renderer: earlier or later, in quarter seconds. |
| Adding an online subtitle | Media3 reads side-loaded files when a stream opens, so the stream reopens at the same place for a moment. |
| Scrub previews from the engine | Frames read with Android's media retriever where the server and format allow; the time otherwise. |
| iPhone Duo tabletop layout | Phones get a bottom tab bar, wide windows a side rail. |

**Android TV** uses the same screens in a TV layout: a navigation drawer that opens as focus
reaches it, margins clear of the screen's overscan edge, a focus ring on every card and button,
and a player that answers the remote's centre, arrows and media keys (left and right skip 10 s
with the controls hidden; Back hides the controls, then closes).

## Building

```sh
cd android
./gradlew :core:test            # the logic tests, on the JVM
./gradlew :app:assembleDebug    # app/build/outputs/apk/debug/app-debug.apk
```

Needs JDK 17 or later and the Android SDK (platform 37). Translations come from the iOS String
Catalog; after changing `app/Reel/Localizable.xcstrings`, run `python3 android/tools/strings.py`.

## Signing

CI signs the release APK with a key from the repository secrets, so each build installs over the
last. Without them it signs with a throwaway debug key and warns; such a build has to be
uninstalled before the next one goes on. To set the key up once:

```sh
keytool -genkeypair -v -keystore reel.keystore -alias reel -keyalg RSA -keysize 4096 -validity 36500
base64 -w0 reel.keystore    # the value of REEL_KEYSTORE_BASE64
```

Then add the secrets `REEL_KEYSTORE_BASE64`, `REEL_KEYSTORE_PASSWORD` and (if they differ from
the defaults) `REEL_KEY_ALIAS` and `REEL_KEY_PASSWORD` under the repository's Settings → Secrets
and variables → Actions. Keep `reel.keystore` safe: a lost key means users reinstall once.

## Checks

The `Android app` workflow runs the logic tests, builds the release and debug APKs, then launches
the release APK on a phone and an Android TV emulator with `ReelMock` (every request answered from
fixed data) and opens each screen with `ReelShot`, as the iOS simulator job does. A screen on
which the app isn't running fails the job; the screenshots are uploaded, and printed in the log as
small images.

## Licences

Media3 is Apache 2.0; the FFmpeg decoder is LGPL. Cinemeta, Torrentio, OpenSubtitles, Trakt and
TMDB are third-party services; the app hosts and stores no media.
