#!/bin/bash
# Cuts a GitHub release. Run with:  bash scripts/release.sh 0.2.0
#
# Everything that can fail is checked before anything is published, and the app
# is built and zipped before you are asked to confirm -- so a broken build never
# leaves a dangling tag behind.
#
# Before running: add a "## [<version>]" section to CHANGELOG.md and commit it.
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "!! $*" >&2; exit 1; }

VERSION="${1:-}"
[ -n "$VERSION" ] || die "usage: bash scripts/release.sh <version>    e.g. 0.2.0"
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die "version must look like 1.2.3, with no leading v"

TAG="v$VERSION"
ZIP="dist/ActivityMonitor-$VERSION.zip"

echo "==> preflight"
command -v gh >/dev/null           || die "gh is not installed:  brew install gh"
gh auth status >/dev/null 2>&1     || die "gh is not logged in:  gh auth login"
git remote get-url origin >/dev/null 2>&1 \
  || die "no 'origin' remote. Create the repo first:  gh repo create --source=. --public --push"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit your changes first"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
  && die "tag $TAG already exists. Pick a new version, or delete the tag if it was a mistake."
grep -q "^## \[$VERSION\]" CHANGELOG.md \
  || die "CHANGELOG.md has no '## [$VERSION]' section. Write the release notes first."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || echo "   note: releasing from branch '$BRANCH', not main"

# The release notes are the changelog section, verbatim: one place to edit.
NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { on = 1; next }
  on && /^## /            { exit }
  on                      { print }
' CHANGELOG.md)"
[ -n "$(echo "$NOTES" | tr -d '[:space:]')" ] || die "the '## [$VERSION]' section is empty"

echo "$VERSION" > VERSION

# Ad-hoc signed and built for both architectures. Ad-hoc because the local
# "Activity Monitor Dev" certificate means nothing on anyone else's machine, and
# into dist/ so this never overwrites the build/ copy you are running.
echo "==> building"
AM_UNIVERSAL=1 AM_SIGN_IDENTITY="-" AM_APP_DIR=dist bash scripts/build.sh

echo "==> packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent dist/ActivityMonitor.app "$ZIP"
lipo -info dist/ActivityMonitor.app/Contents/MacOS/ActivityMonitor

cat <<SUMMARY

------------------------------------------------------------
Ready to publish $TAG

  commit  VERSION (if changed)
  tag     $TAG
  push    $BRANCH and $TAG to $(git remote get-url origin)
  release $TAG on GitHub, attaching $ZIP

Release notes:
$NOTES
------------------------------------------------------------
SUMMARY

read -r -p "Publish? [y/N] " reply
[ "$reply" = "y" ] || [ "$reply" = "Y" ] || die "aborted; nothing was pushed"

if ! git diff --quiet -- VERSION; then
  git add VERSION
  git commit -m "Release $TAG"
fi
git tag -a "$TAG" -m "Release $TAG"
git push origin "$BRANCH"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" --title "$TAG" --notes "$NOTES"

echo
echo "Published: $(gh release view "$TAG" --json url -q .url)"
