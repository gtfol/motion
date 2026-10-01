#!/usr/bin/env python3
"""Saves the UI test screenshot previews from a GitHub Actions job log as JPEG files.

A manual run of ios.yml with `screenshot_previews: true` prints each screenshot as base64 between
`=====BEGIN <file>=====` and `=====END=====`, after the attachment manifest. Use this where the run's
artifacts can't be downloaded. The log may be raw text or a JSON tool result holding it.

    python3 scripts/extract-screenshot-previews.py job.log previews/

Files are named after the attachment, for example `2-workout.jpg`.
"""
import base64
import json
import re
import sys
from pathlib import Path


def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)


def main(source: Path, output: Path) -> None:
    text = source.read_text(errors="replace")
    try:
        found = [s for s in strings(json.loads(text)) if "=====BEGIN" in s]
        if found:
            text = "\n".join(found)
    except json.JSONDecodeError:
        pass
    lines = [re.sub(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?", "", line) for line in text.splitlines()]

    names = {}
    start = next((i for i, line in enumerate(lines) if line.strip() == "[" and '"attachments"' in "".join(lines[i:i + 3])), None)
    if start is not None:
        manifest, _ = json.JSONDecoder().raw_decode("\n".join(lines[start:]))
        for test in manifest:
            for attachment in test.get("attachments", []):
                readable = attachment["suggestedHumanReadableName"].split("_0_")[0]
                names[attachment["exportedFileName"]] = Path(readable).stem.replace(" ", "-")

    output.mkdir(parents=True, exist_ok=True)
    name, chunks, count = None, [], 0
    for line in (line.strip() for line in lines):
        begin = re.search(r"=====BEGIN (.+)=====$", line)  # the first marker can follow the manifest on one line
        if begin:
            name, chunks = begin.group(1), []
        elif line == "=====END=====" and name:
            target = output / f"{names.get(name, Path(name).stem)}.jpg"
            target.write_bytes(base64.b64decode("".join(chunks)))
            print(target)
            name, count = None, count + 1
        elif name:
            chunks.append(line)
    print(f"{count} previews")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
