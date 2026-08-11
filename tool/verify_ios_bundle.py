"""Validate the built EDUI app and embedded WidgetKit extension metadata."""

import json
import plistlib
import re
import sys
from pathlib import Path


def read_plist(path: Path) -> dict:
    with path.open("rb") as stream:
        return plistlib.load(stream)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify_ios_bundle.py <path-to-app-bundle>")

    app = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    match = re.search(
        r"^version:\s*([^+\s]+)\+(\d+)\s*$",
        (root / "pubspec.yaml").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise SystemExit("invalid pubspec version")
    expected_version, expected_build = match.groups()

    app_info = read_plist(app / "Info.plist")
    widget = app / "PlugIns" / "EDUIWidget.appex"
    widget_info = read_plist(widget / "Info.plist")

    for name, info in (("app", app_info), ("widget", widget_info)):
        if info.get("CFBundleShortVersionString") != expected_version:
            raise SystemExit(f"{name} short version is missing or incorrect")
        if str(info.get("CFBundleVersion")) != expected_build:
            raise SystemExit(f"{name} bundle version is missing or incorrect")

    app_id = app_info.get("CFBundleIdentifier", "")
    widget_id = widget_info.get("CFBundleIdentifier", "")
    if not widget_id.startswith(f"{app_id}."):
        raise SystemExit("widget bundle identifier is not prefixed by app id")

    print(
        json.dumps(
            {
                "version": expected_version,
                "build": expected_build,
                "app_bundle": app_id,
                "widget_bundle": widget_id,
                "widget_present": widget.is_dir(),
            }
        )
    )


if __name__ == "__main__":
    main()
