#!/bin/bash
# Prepare a GitHub release; upload only when --publish is explicitly passed.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=false
if [ "${1:-}" = "--publish" ]; then PUBLISH=true; shift; fi
NOTES="${1:-See CHANGELOG.md for details.}"
REPOSITORY="quentinzhang/oneact"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
TAG="v${VERSION}"
IDENTITY="${CODESIGN_IDENTITY:--}"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Release packages currently require an Apple Silicon build host." >&2
  exit 1
fi
if [ -n "${NOTARY_PROFILE:-}" ] && [ "$IDENTITY" = "-" ]; then
  echo "Apple notarization requires CODESIGN_IDENTITY with a Developer ID certificate." >&2
  exit 1
fi

if $PUBLISH; then
  gh auth status >/dev/null
  if [ -n "$(git status --porcelain)" ]; then
    echo "Commit the release source before publishing." >&2; exit 1
  fi
  case "$(git remote get-url origin)" in
    "git@github.com:${REPOSITORY}.git"|"https://github.com/${REPOSITORY}.git"|"https://github.com/${REPOSITORY}") ;;
    *) echo "origin must point to ${REPOSITORY}." >&2; exit 1 ;;
  esac
  REMOTE_HEAD="$(git ls-remote origin refs/heads/main | cut -f1)"
  if [ "$(git rev-parse HEAD)" != "$REMOTE_HEAD" ]; then
    echo "Push this exact source commit to the public main branch before publishing." >&2; exit 1
  fi
  # Only an explicit 404 permits creation; auth/network errors must stop the release.
  RELEASE_STATUS="$(gh api -i "repos/${REPOSITORY}/releases/tags/${TAG}" 2>/dev/null || true)"
  case "$RELEASE_STATUS" in
    *"404 Not Found"*) ;;
    *) echo "Release already exists or GitHub lookup failed; refusing to overwrite ${TAG}." >&2; exit 1 ;;
  esac
  if [ -n "$(git ls-remote --tags origin "refs/tags/${TAG}")" ]; then
    echo "Tag ${TAG} already exists; choose a new version." >&2; exit 1
  fi
fi

./scripts/package-app.sh
OUTPUT="build/releases/${TAG}"
ZIP="${OUTPUT}/OneAct-macOS-arm64.zip"
mkdir -p "$OUTPUT"
rm -f "$ZIP"
ditto -c -k --keepParent build/OneAct.app "$ZIP"
NOTARIZED=false
if [ -n "${NOTARY_PROFILE:-}" ]; then
  SUBMISSION="${OUTPUT}/notary-submission.json"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format json > "$SUBMISSION"
  SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$SUBMISSION")"
  xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" "${OUTPUT}/notary-log.json"
  python3 - "$SUBMISSION" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get("status") != "Accepted":
    sys.exit("Apple did not accept the notarization; see the local notary log.")
print("Apple notarization accepted: " + result["id"])
PY
  xcrun stapler staple build/OneAct.app
  xcrun stapler validate build/OneAct.app
  spctl --assess --type execute build/OneAct.app
  rm -f "$ZIP"
  ditto -c -k --keepParent build/OneAct.app "$ZIP"
  NOTARIZED=true
fi

VERSION="$VERSION" NOTES="$NOTES" OUTPUT="$OUTPUT" NOTARIZED="$NOTARIZED" \
IDENTITY="$IDENTITY" REPOSITORY="$REPOSITORY" python3 - <<'PY'
import hashlib, json, os
from pathlib import Path

output = Path(os.environ["OUTPUT"])
name = "OneAct-macOS-arm64.zip"
version = os.environ["VERSION"]
repo = os.environ["REPOSITORY"]
notarized = os.environ["NOTARIZED"] == "true"
digest = hashlib.sha256((output / name).read_bytes()).hexdigest()
appcast = {
    "version": version,
    "download": f"https://github.com/{repo}/releases/download/v{version}/{name}",
    "notes": os.environ["NOTES"],
    "minimumSystemVersion": "15.0",
    "architecture": "arm64",
    "notarized": notarized,
    "sha256": digest,
}
(output / "appcast.json").write_text(json.dumps(appcast, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
(output / "SHA256SUMS").write_text(f"{digest}  {name}\n", encoding="utf-8")
signing = "Apple Developer ID signed and notarized." if notarized else (
    "Ad-hoc signed; NOT notarized by Apple." if os.environ["IDENTITY"] == "-" else
    "Developer ID signed; NOT notarized by Apple.")
installation = "Apple notarization is complete and its ticket is stapled to the app." if notarized else (
    "Unnotarized test builds may be blocked by macOS Gatekeeper. After verifying the source, "
    "follow macOS Privacy & Security prompts to allow opening, or build from source. "
    "Do not disable system security settings.")
text = f"""## OneAct {version} — Beta

{os.environ['NOTES']}

Requires an Apple Silicon Mac and macOS 15 or later.

**Signing: {signing}**

{installation}

Download `{name}`, unzip, and move `OneAct.app` to Applications. Verify the download with `shasum -a 256 -c SHA256SUMS`.

Licensed under GPL-3.0-only, without warranty. The app includes LICENSE.txt. Complete corresponding source and build instructions: [source at v{version}](https://github.com/{repo}/tree/v{version}).

See [CHANGELOG](https://github.com/{repo}/blob/v{version}/CHANGELOG.md) for details. Versions up to 0.39 use the old update feed; download this version manually to migrate.
"""
(output / "release-notes.md").write_text(text, encoding="utf-8")
print(f"Prepared {output}; notarized={notarized}; sha256={digest}")
PY

if $PUBLISH; then
  gh release create "$TAG" --repo "$REPOSITORY" --target "$(git rev-parse HEAD)" \
    --draft --title "OneAct ${VERSION} Beta" --notes-file "$OUTPUT/release-notes.md" \
    "$ZIP" "$OUTPUT/SHA256SUMS" "$OUTPUT/appcast.json"
  gh release edit "$TAG" --repo "$REPOSITORY" --draft=false --latest
  echo "Published https://github.com/${REPOSITORY}/releases/tag/${TAG}"
  if ! gh workflow run pages.yml --repo "$REPOSITORY" --ref main; then
    echo "Release published. Pages dispatch failed; run GitHub Pages manually in Actions." >&2
    exit 1
  fi
fi
