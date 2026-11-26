#!/usr/bin/env python3
"""Compares CI screenshots with the references in ReelTests/Screenshots.

Both sides are scaled to 160 pixels wide with macOS's `sips` and read as BMP, so this needs no
packages. The status bar (clock, battery) is left out. A screen whose mean difference passes the
threshold is reported as a GitHub warning; nothing fails the build, because a deliberate change
to a screen also changes its picture. Refresh the references by copying the run's *-small.jpg
files into ReelTests/Screenshots.

    python3 tools/compare_shots.py shots ReelTests/Screenshots
"""
import os
import struct
import subprocess
import sys
import tempfile

THRESHOLD = 8.0   # mean absolute difference per channel, 0-255
WIDTH = 160


def pixels(path, workdir):
    out = os.path.join(workdir, os.path.basename(path) + ".bmp")
    subprocess.run(["sips", "-s", "format", "bmp", "--resampleWidth", str(WIDTH), path, "--out", out],
                   check=True, capture_output=True)
    data = open(out, "rb").read()
    offset = struct.unpack_from("<I", data, 10)[0]
    width, height = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0] // 8
    row = (width * bpp + 3) & ~3
    rows = []
    for y in range(abs(height)):
        start = offset + y * row
        rows.append([data[start + x * bpp: start + x * bpp + 3] for x in range(width)])
    if height > 0:
        rows.reverse()   # BMP rows run bottom to top
    return rows


def difference(a, b):
    height = min(len(a), len(b))
    skip = int(height * 0.06)   # the status bar
    total = count = 0
    for y in range(skip, height):
        for pa, pb in zip(a[y], b[y]):
            total += sum(abs(x - z) for x, z in zip(pa, pb))
            count += 3
    return total / count if count else 0.0


def main():
    shots, references = sys.argv[1], sys.argv[2]
    names = sorted(f for f in os.listdir(shots) if f.endswith("-small.jpg"))
    if not names:
        print("No screenshots to compare.")
        return
    changed = []
    with tempfile.TemporaryDirectory() as work:
        for name in names:
            reference = os.path.join(references, name)
            if not os.path.exists(reference):
                print(f"{name}: no reference yet")
                continue
            score = difference(pixels(os.path.join(shots, name), work), pixels(reference, work))
            print(f"{name}: {score:.1f}")
            if score > THRESHOLD:
                changed.append((name, score))
    for name, score in changed:
        print(f"::warning::{name} differs from its reference ({score:.1f}); check the screenshot, and refresh the reference if the change is meant.")


if __name__ == "__main__":
    main()
