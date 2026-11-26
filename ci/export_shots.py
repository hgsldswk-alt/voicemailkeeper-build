"""Recover store attachments from an xcresult bundle using their requested names."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

LANGUAGES = ("en", "zh-Hans", "zh-Hant")
SCENES = ("01-home", "02-playback", "03-import", "04-backup", "05-family")
NAMES = re.compile(r"(?<![A-Za-z0-9])(store-(?:en|zh-Hans|zh-Hant)-(?:" + "|".join(SCENES) + r"))(?![A-Za-z0-9])")


def pairs(value):
    if isinstance(value, dict):
        name = value.get("suggestedHumanReadableName") or value.get("name") or ""
        file = value.get("exportedFileName") or ""
        if isinstance(name, str) and isinstance(file, str):
            match = NAMES.search(name)
            if match and Path(file).suffix.lower() == ".png" and Path(file).name == file:
                yield match.group(1), file
        for child in value.values():
            yield from pairs(child)
    elif isinstance(value, list):
        for child in value:
            yield from pairs(child)


def expected():
    return {f"store-{lang}-{scene}" for scene in SCENES for lang in LANGUAGES}


def export(result, output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as work:
        raw = Path(work)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                        "--output-path", str(raw)], check=True)
        manifest = json.loads((raw / "manifest.json").read_text(encoding="utf-8"))
        matches = dict(pairs(manifest))
        missing = expected() - matches.keys()
        if missing:
            raise SystemExit("Missing screenshot attachments: " + ", ".join(sorted(missing)))
        for name in sorted(expected()):
            shutil.copyfile(raw / matches[name], output / (name + ".png"))
    print(f"Exported {len(expected())} store screenshots to {output}")


if __name__ == "__main__":
    export(*map(Path, sys.argv[1:3]))
