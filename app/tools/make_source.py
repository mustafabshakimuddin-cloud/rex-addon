#!/usr/bin/env python3
"""Writes the AltStore-format source that SideStore, AltStore and Feather read.

Run by the release job after each build on main:

    make_source.py --previous old.json --out source.json --version 0.1.42 --build 42 \
        --ipa Reel.ipa --download-url https://…/Reel.ipa --notes "…"

Only the newest version is listed: the release job deletes older releases, so their links
would no longer work. `--previous` may name a file that does not exist (the first release).
"""
import argparse
import datetime
import hashlib
import json
import os

REPO = "https://github.com/mustafabshakimuddin-cloud/Reel-Media-Center"
RAW = "https://raw.githubusercontent.com/mustafabshakimuddin-cloud/Reel-Media-Center/main"
# The release job deletes older releases, so only the newest download link stays valid.
KEEP = 1
TINT = "FF4FA3"

DESCRIPTION = """Reel finds films and series in Cinemeta's catalogue and plays them through your debrid service, with sources from Torrentio and any Stremio addons you add.

• Picks the best source for you and learns which releases actually play
• Checks a file's real format before you press Play: Dolby Vision profile, HDR10+, bit depth, Atmos
• HDR10, HDR10+, Dolby Vision and Dolby Atmos playback, with audio track choice for Spatial Audio
• Skip Intro, Up Next, scrub previews, subtitle search, timing and styles
• Downloads for offline viewing
• Trakt sync for your watchlist, progress and history
• Built for iOS 27 and iPhone Duo, including a half-open tabletop player

Reel hosts no content. You need your own debrid account (Real-Debrid, AllDebrid, Premiumize, TorBox and others) or a Stremio addon that provides streams."""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--previous", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--ipa", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--notes", default="")
    args = parser.parse_args()

    with open(args.ipa, "rb") as handle:
        data = handle.read()
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    entry = {
        "version": args.version,
        "buildVersion": args.build,
        "date": now.isoformat().replace("+00:00", "Z"),
        "localizedDescription": args.notes or f"Build {args.build}.",
        "downloadURL": args.download_url,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "minOSVersion": "26.0",
    }

    previous_versions = []
    if os.path.exists(args.previous):
        try:
            with open(args.previous) as handle:
                old = json.load(handle)
            previous_versions = old["apps"][0].get("versions", [])
        except (ValueError, KeyError, IndexError):
            previous_versions = []
    versions = [entry] + [v for v in previous_versions if v.get("buildVersion") != args.build][: KEEP - 1]

    app = {
        "name": "Reel",
        "bundleIdentifier": "community.reel.app",
        "developerName": "Reel",
        "subtitle": "Stream films and series through your debrid service.",
        "localizedDescription": DESCRIPTION,
        "iconURL": f"{RAW}/app/Reel/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
        "tintColor": TINT,
        "category": "entertainment",
        "screenshots": [f"{RAW}/app/store/{name}.jpg" for name in ("home", "detail", "movies")],
        "versions": versions,
        # Every entitlement the .ipa is signed with must be listed: AltStore and SideStore refuse
        # an install whose app asks for one the source didn't declare. The app and its widgets
        # share an app group (Reel/Reel.entitlements); the signing store adds its own application
        # identifier and team. No protected data is asked for, so no privacy keys.
        "appPermissions": {"entitlements": ["com.apple.security.application-groups"], "privacy": {}},
        # Fields read by older AltStore and SideStore releases.
        "version": entry["version"],
        "versionDate": entry["date"],
        "versionDescription": entry["localizedDescription"],
        "downloadURL": entry["downloadURL"],
        "size": entry["size"],
    }

    source = {
        "name": "Reel",
        "identifier": "community.reel.source",
        "subtitle": "Builds of Reel for SideStore and AltStore.",
        "description": "The official source for Reel. New builds appear here as soon as they are published.",
        "iconURL": app["iconURL"],
        "website": REPO,
        "tintColor": TINT,
        "apps": [app],
        "news": [],
    }

    with open(args.out, "w") as handle:
        json.dump(source, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


if __name__ == "__main__":
    main()
