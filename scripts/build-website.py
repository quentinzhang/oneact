#!/usr/bin/env python3
"""Build Pages using metadata from the latest published GitHub Release."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent


def latest_appcast(repository):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "OneAct-Pages"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    request = Request(f"https://api.github.com/repos/{repository}/releases/latest", headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            release = json.load(response)
    except HTTPError as error:
        if error.code == 404:
            print("No public release yet; publishing the source/download landing page.")
            return None
        raise
    assets = {asset["name"]: asset["browser_download_url"] for asset in release["assets"]}
    # A published release missing metadata is a release error, not an empty channel.
    with urlopen(assets["appcast.json"], timeout=30) as response:
        appcast = json.load(response)
    if release["tag_name"] != "v" + appcast["version"]:
        raise ValueError("Release tag and appcast version disagree")
    if appcast["download"] != assets["OneAct-macOS-arm64.zip"]:
        raise ValueError("Appcast does not point to this release's installation asset")
    if not re.fullmatch(r"[0-9a-f]{64}", appcast["sha256"]):
        raise ValueError("Invalid installation asset checksum")
    if type(appcast.get("notarized")) is not bool:
        raise ValueError("Appcast must declare its notarization status")
    return appcast


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default="quentinzhang/oneact")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
        parser.error("repository must be owner/name")
    output = args.output.resolve()
    if output == ROOT or ROOT in output.parents and not output.is_relative_to(ROOT / "build"):
        parser.error("use a build/ subdirectory or a separate output directory")
    output.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "website/index.html", output / "index.html")
    shutil.copytree(ROOT / "website/assets", output / "assets", dirs_exist_ok=True)
    (output / ".nojekyll").touch()
    appcast = latest_appcast(args.repository)
    feed = output / "appcast.json"
    if appcast is None:
        feed.unlink(missing_ok=True)
    else:
        feed.write_text(json.dumps(appcast, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Pages release: v{appcast['version']}")


if __name__ == "__main__":
    main()
