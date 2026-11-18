#!/usr/bin/env bash
# Cuts a release: ./scripts/release.sh 0.2.0
# 1. Add a "## [0.2.0] - YYYY-MM-DD" section to CHANGELOG.md first.
# 2. This bumps Info.plist, commits, tags v0.2.0, pushes and creates a GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?Usage: scripts/release.sh X.Y.Z}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version must be X.Y.Z"; exit 1; }
TAG="v$VERSION"
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree not clean."; exit 1; }
git rev-parse "$TAG" >/dev/null 2>&1 && { echo "$TAG already exists."; exit 1; }

# Release notes = the CHANGELOG section for this version.
NOTES="$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {f=1; next} /^## \[/ {f=0} f' CHANGELOG.md)"
[[ -n "${NOTES//[[:space:]]/}" ]] || { echo "Add a '## [$VERSION]' section to CHANGELOG.md first."; exit 1; }

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

./scripts/build-app.sh >/dev/null   # make sure it builds before tagging

git commit -qam "Release $TAG"
git tag -a "$TAG" -m "Said $VERSION"
git push -q origin HEAD "$TAG"
gh release create "$TAG" --title "Said $VERSION" --notes "$NOTES"
echo "Released $TAG"
