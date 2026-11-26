#!/usr/bin/env python3
"""Prints the crashed thread of a crash report (.ips) in a few readable lines.

usage: crash_summary.py REPORT.ips
"""
import json
import sys


def main(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    # An .ips file is a one-line JSON header followed by the JSON report.
    header, _, body = text.partition("\n")
    try:
        report = json.loads(body)
    except ValueError:
        print(text[:4000])
        return
    images = report.get("usedImages", [])
    exception = report.get("exception", {})
    print("exception:", exception.get("type"), exception.get("signal"), exception.get("subtype", ""))
    for line in report.get("asi", {}).values():
        print("note:", " ".join(line) if isinstance(line, list) else line)
    threads = report.get("threads", [])
    index = report.get("faultingThread", 0)
    if index >= len(threads):
        return
    thread = threads[index]
    print("thread", index, thread.get("queue", ""), thread.get("name", ""))
    for number, frame in enumerate(thread.get("frames", [])[:40]):
        image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
        symbol = frame.get("symbol", hex(frame.get("imageOffset", 0)))
        print(f"  {number:2} {image:28} {symbol}")


if __name__ == "__main__":
    main(sys.argv[1])
