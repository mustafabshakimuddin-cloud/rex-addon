#!/usr/bin/env python3
"""Turns the iOS String Catalog into the Android app's translations.

Both apps look strings up by their English text, so one catalog serves both:

    python3 android/tools/strings.py

writes android/app/src/main/assets/strings.json as {language: {english: translation}}. Format
specifiers become Java's: %@ -> %s, %lld / %ld -> %d (positional forms too).
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "app", "Reel", "Localizable.xcstrings")
OUT = os.path.join(ROOT, "android", "app", "src", "main", "assets", "strings.json")


def java(text):
    text = re.sub(r"%(\d+\$)?@", lambda m: "%" + (m.group(1) or "") + "s", text)
    return re.sub(r"%(\d+\$)?l{0,2}[du]", lambda m: "%" + (m.group(1) or "") + "d", text)


def main():
    with open(CATALOG, encoding="utf-8") as handle:
        catalog = json.load(handle)
    out = {}
    for key, entry in catalog["strings"].items():
        for language, localization in entry.get("localizations", {}).items():
            unit = localization.get("stringUnit")
            if not unit or unit.get("state") not in ("translated", "needs_review"):
                continue
            out.setdefault(language.split("-")[0], {})[java(key)] = java(unit["value"])
    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump(out, handle, ensure_ascii=False, sort_keys=True, indent=0)
        handle.write("\n")
    print(f"{OUT}: {', '.join(f'{k} {len(v)}' for k, v in sorted(out.items()))}")


if __name__ == "__main__":
    main()
