#!/bin/sh
# Cuts a release — the local equivalent of a GitHub release.
#
# Usage: Scripts/release.sh <MAJOR.MINOR.PATCH>       e.g. Scripts/release.sh 1.1.0
#        SKIP_SMOKE=1 Scripts/release.sh 1.1.0        unit tests only
#
# Steps, stopping at the first failure:
#   1. Refuses unless the working tree is clean and CHANGELOG.md has notes under
#      "## [Unreleased]" — a release with no description of what changed is
#      just a number.
#   2. Runs the full suite (Scripts/check.sh).
#   3. Stamps the version into Resources/Info.plist and moves the Unreleased
#      notes under a dated heading for this version.
#   4. Commits that, builds the app from the commit, and saves it as
#      releases/PhotoVault-<version>.zip with a SHA-256 checksum.
#   5. Tags the commit v<version>, with the notes and checksum in the tag.
#
# releases/ is kept out of git history (binaries bloat it), but the tag records
# the checksum, so any saved zip can be verified against the history. Old
# versions are installable with:
#   Scripts/install-to-vault.sh /Volumes/<vault> releases/PhotoVault-<version>.zip

set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-}"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
    echo "usage: Scripts/release.sh <MAJOR.MINOR.PATCH>   (e.g. 1.1.0)" >&2
    exit 64
}
TAG="v$VERSION"
DATE="$(date +%Y-%m-%d)"

git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not a git repository" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
    echo "error: there are uncommitted changes — commit them first:" >&2
    git status --short >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: $TAG already exists" >&2
    exit 1
fi

NOTES="$(awk '/^## \[Unreleased\]/ { f = 1; next } /^## \[/ { f = 0 } f' CHANGELOG.md | sed '/^[[:space:]]*$/d')"
if [ -z "$NOTES" ]; then
    echo "error: nothing under '## [Unreleased]' in CHANGELOG.md — describe the release first" >&2
    exit 1
fi

echo "Releasing PhotoVault $VERSION"
Scripts/check.sh

# ---------------------------------------------------------------- stamp

# Edited with awk rather than plutil/PlistBuddy, which would rewrite the file
# and drop its comments.
set_plist_string() {  # set_plist_string key value
    awk -v key="$1" -v val="$2" '
        found && /<string>/ { sub(/<string>[^<]*<\/string>/, "<string>" val "</string>"); found = 0 }
        index($0, "<key>" key "</key>") { found = 1 }
        { print }
    ' Resources/Info.plist > Resources/Info.plist.tmp && mv Resources/Info.plist.tmp Resources/Info.plist
}
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))
set_plist_string CFBundleShortVersionString "$VERSION"
set_plist_string CFBundleVersion "$BUILD"
plutil -lint -s Resources/Info.plist

awk -v v="$VERSION" -v d="$DATE" '
    !done && /^## \[Unreleased\]/ { print; print ""; print "## [" v "] — " d; done = 1; next }
    { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

git add Resources/Info.plist CHANGELOG.md
if [ -n "${COMMIT_TRAILER:-}" ]; then
    git commit -q -m "Release $VERSION" -m "$NOTES" -m "$COMMIT_TRAILER"
else
    git commit -q -m "Release $VERSION" -m "$NOTES"
fi

# ---------------------------------------------------------------- build and save

Scripts/build-app.sh >/dev/null
mkdir -p releases
ZIP="releases/PhotoVault-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/PhotoVault.app "$ZIP"
SUM="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
echo "$SUM  PhotoVault-$VERSION.zip" > "$ZIP.sha256"
COMMIT="$(git rev-parse --short HEAD)"
[ -f releases/index.tsv ] || printf 'version\tdate\tcommit\tsha256\n' > releases/index.tsv
printf '%s\t%s\t%s\t%s\n' "$VERSION" "$DATE" "$COMMIT" "$SUM" >> releases/index.tsv

git tag -a "$TAG" -m "PhotoVault $VERSION" -m "$NOTES" -m "App build: PhotoVault-$VERSION.zip  sha256 $SUM"

echo
echo "Released PhotoVault $VERSION"
echo "  commit:  $COMMIT"
echo "  tag:     $TAG"
echo "  app:     $ZIP"
echo "  sha256:  $SUM"
