#!/usr/bin/env python3
"""Validate or update EDUI's AltStore/SideStore source manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


EXPECTED_BUNDLE_ID = "com.orangewoker.edui"


def load_source(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("source root must be an object")
    apps = value.get("apps")
    if not isinstance(apps, list) or len(apps) != 1:
        raise ValueError("source must contain exactly one app")
    app = apps[0]
    if not isinstance(app, dict) or app.get("bundleIdentifier") != EXPECTED_BUNDLE_ID:
        raise ValueError(f"source app must use bundle identifier {EXPECTED_BUNDLE_ID}")
    versions = app.get("versions")
    if not isinstance(versions, list):
        raise ValueError("source app versions must be an array")
    required_app_keys = {
        "name",
        "bundleIdentifier",
        "developerName",
        "localizedDescription",
        "iconURL",
        "versions",
        "appPermissions",
    }
    missing_app = sorted(required_app_keys - app.keys())
    if missing_app:
        raise ValueError(f"source app is missing: {', '.join(missing_app)}")
    seen: set[tuple[str, str]] = set()
    for index, version in enumerate(versions):
        validate_version(version, index)
        identity = (version["version"], version["buildVersion"])
        if identity in seen:
            raise ValueError(f"duplicate source version: {identity[0]} ({identity[1]})")
        seen.add(identity)
    return value


def validate_version(value: Any, index: int) -> None:
    if not isinstance(value, dict):
        raise ValueError(f"version {index} must be an object")
    required = {
        "version",
        "buildVersion",
        "date",
        "downloadURL",
        "size",
        "sha256",
        "minOSVersion",
    }
    missing = sorted(required - value.keys())
    if missing:
        raise ValueError(f"version {index} is missing: {', '.join(missing)}")
    if not isinstance(value["size"], int) or value["size"] <= 0:
        raise ValueError(f"version {index} has an invalid size")
    digest = str(value["sha256"]).lower()
    if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
        raise ValueError(f"version {index} has an invalid sha256")
    datetime.fromisoformat(str(value["date"]).replace("Z", "+00:00"))


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def update_source(
    source_path: Path,
    ipa_path: Path,
    version: str,
    build_version: str,
    download_url: str,
    description: str,
    release_date: str | None,
) -> dict[str, Any]:
    source = load_source(source_path)
    app = source["apps"][0]
    versions = app["versions"]
    entry = {
        "version": version,
        "buildVersion": build_version,
        "date": release_date
        or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "localizedDescription": description,
        "downloadURL": download_url,
        "size": ipa_path.stat().st_size,
        "sha256": sha256(ipa_path),
        "minOSVersion": "17.0",
    }
    app["versions"] = [
        entry,
        *[
            item
            for item in versions
            if not (
                str(item.get("version")) == version
                and str(item.get("buildVersion")) == build_version
            )
        ],
    ][:50]
    source_path.write_text(
        json.dumps(source, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return load_source(source_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--version")
    parser.add_argument("--build-version")
    parser.add_argument("--download-url")
    parser.add_argument("--description", default="额度监控与小组件体验更新。")
    parser.add_argument("--date")
    args = parser.parse_args()

    if args.check:
        load_source(args.source)
        print(f"valid AltSource: {args.source}")
        return

    required = {
        "--ipa": args.ipa,
        "--version": args.version,
        "--build-version": args.build_version,
        "--download-url": args.download_url,
    }
    missing = [name for name, value in required.items() if not value]
    if missing:
        parser.error(f"missing required arguments: {', '.join(missing)}")
    update_source(
        args.source,
        args.ipa,
        args.version,
        args.build_version,
        args.download_url,
        args.description,
        args.date,
    )
    print(f"updated AltSource for EDUI {args.version} ({args.build_version})")


if __name__ == "__main__":
    main()
