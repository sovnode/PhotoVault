#!/bin/sh
# Builds PhotoVault Installer, the app the public downloads. It makes a new
# vault, or puts PhotoVault on an existing one, with JoyTag in every one — what
# new-vault.sh and install-to-vault.sh do, for someone without this project.
#
# Usage: Scripts/build-installer.sh [release.zip | --from-source]
#
#   Scripts/build-installer.sh                     the newest saved release
#   Scripts/build-installer.sh releases/PhotoVault-1.4.0.zip
#   Scripts/build-installer.sh --from-source       the current source, built now
#
# By default it carries a release saved by release.sh, checked against its
# checksum, with the README and default tag groups from that release's tag: what
# it installs is exactly a released build. --from-source is for trying out
# changes before a release; its zip is named after the commit, not a version.
#
# JoyTag isn't optional: the build stops without tools/joytag/package/JoyTag
# (Scripts/joytag/package.sh) and its licence. About 370 MB of the installer.
#
# Nothing personal goes in. It's built only from the app, two texts from
# Resources/ and JoyTag — never from a vault — and every file is checked for any
# trace of the Mac it was built on (Scripts/check-no-personal-data.sh): a build
# that holds one stops. Releases cut before 1.4.0 hold this Mac's paths, so they
# can't be packaged.
#
# Output, in build/:
#   PhotoVault Installer.app
#   PhotoVault-Installer-<version>.zip and .sha256, to publish. The zip holds no
#   extended attributes, so nothing of this Mac's file history goes with it.
set -eu
cd "$(dirname "$0")/.."

RELEASE=""
FROM_SOURCE=0
for arg in "$@"; do
    case "$arg" in
        --from-source) FROM_SOURCE=1 ;;
        -*) echo "usage: Scripts/build-installer.sh [release.zip | --from-source]" >&2; exit 64 ;;
        *) RELEASE="$arg" ;;
    esac
done

APP="build/PhotoVault Installer.app"
STAGE="build/.installer-payload"
CHECK="build/.installer-check"
# An installer left from an earlier build goes first, so a build that stops
# part-way never leaves an old one looking like its result.
rm -rf "$STAGE" "$CHECK" "$APP"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE" "$CHECK"' EXIT

# ---------------------------------------------------------------- PhotoVault

if [ "$FROM_SOURCE" = 1 ]; then
    [ -z "$RELEASE" ] || { echo "error: give a release or --from-source, not both" >&2; exit 64; }
    Scripts/build-app.sh
    ditto --noextattr --noqtn build/PhotoVault.app "$STAGE/PhotoVault.app"
    cp Resources/README.txt "$STAGE/README.txt"
    cp "Resources/Tag Groups.txt" "$STAGE/Tag Groups.txt"
    COMMIT="$(git rev-parse --short HEAD)"
    [ -z "$(git status --porcelain)" ] || COMMIT="$COMMIT-modified"
    FROM="the current source ($COMMIT)"
else
    if [ -z "$RELEASE" ]; then
        [ -f releases/index.tsv ] || { echo "error: no saved releases — cut one with release.sh, or use --from-source" >&2; exit 1; }
        RELEASE="releases/PhotoVault-$(tail -1 releases/index.tsv | cut -f1).zip"
    fi
    [ -f "$RELEASE" ] || { echo "error: no such release: $RELEASE" >&2; exit 1; }
    [ -f "$RELEASE.sha256" ] || { echo "error: $RELEASE has no checksum file to check it against" >&2; exit 1; }
    EXPECTED="$(awk '{ print $1 }' "$RELEASE.sha256")"
    ACTUAL="$(shasum -a 256 "$RELEASE" | awk '{ print $1 }')"
    [ "$EXPECTED" = "$ACTUAL" ] || { echo "error: $RELEASE doesn't match its recorded checksum" >&2; exit 1; }
    ditto -x -k --noextattr --noqtn "$RELEASE" "$STAGE"
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/PhotoVault.app/Contents/Info.plist")"
    # The README and tag groups as they were in that release.
    git show "v$VERSION:Resources/README.txt" > "$STAGE/README.txt"
    git show "v$VERSION:Resources/Tag Groups.txt" > "$STAGE/Tag Groups.txt"
    COMMIT=""
    FROM="$RELEASE (checksum verified)"
fi
codesign --verify --deep --strict "$STAGE/PhotoVault.app" || { echo "error: PhotoVault.app's signature doesn't check out" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/PhotoVault.app/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGE/PhotoVault.app/Contents/Info.plist")"

# ---------------------------------------------------------------- JoyTag

JOYTAG="tools/joytag/package/JoyTag"
for f in manifest.json tags.txt LICENSE.txt JoyTag.mlmodelc; do
    [ -e "$JOYTAG/$f" ] || {
        echo "error: $JOYTAG/$f is missing. JoyTag goes into every installer: package it with" >&2
        echo "       Scripts/joytag/fetch.sh test, fetch.sh convert, convert.sh, then package.sh." >&2
        exit 1
    }
done
ditto --noextattr --noqtn "$JOYTAG" "$STAGE/JoyTag"
JOYTAG_VERSION="$(sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$STAGE/JoyTag/manifest.json")"

if ! Scripts/check-no-personal-data.sh "$STAGE"; then
    echo "error: what the installer would carry holds a trace of this Mac (above)." >&2
    [ "$FROM_SOURCE" = 1 ] || echo "       $RELEASE was built before build-app.sh removed it: cut a new release, or use --from-source." >&2
    exit 1
fi

# ---------------------------------------------------------------- the installer

# As build-app.sh builds PhotoVault: no source paths, no debug map. (So the
# build warns "no debug symbols in executable", as intended.)
swift build -c release --product PhotoVaultInstaller -Xswiftc -file-prefix-map -Xswiftc "$(pwd -P)=." -Xlinker -S
BIN="$(swift build -c release --product PhotoVaultInstaller --show-bin-path)/PhotoVaultInstaller"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoVaultInstaller"
cp Resources/Installer-Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Its own, generic icon (Scripts/make-installer-icon.swift): it isn't PhotoVault.
cp Resources/Icon/InstallerIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
mv "$STAGE" "$APP/Contents/Resources/Payload"

# Ad-hoc, like PhotoVault. Not --deep: PhotoVault.app inside keeps its own
# signature, and is sealed into the installer's as it is.
codesign -s - -f "$APP" >/dev/null 2>&1 || { echo "error: couldn't sign the installer" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "error: the installer's signature doesn't check out" >&2; exit 1; }
Scripts/check-no-personal-data.sh "$APP" || { echo "error: the installer holds a trace of this Mac (above)" >&2; rm -rf "$APP"; exit 1; }

# ---------------------------------------------------------------- the zip

NAME="PhotoVault-Installer-$VERSION${COMMIT:+-$COMMIT}"
ZIP="build/$NAME.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
# What someone downloading it gets: unpacked, it must still be signed, whole,
# and clean.
mkdir -p "$CHECK"
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/PhotoVault Installer.app" || { echo "error: the zipped installer's signature doesn't check out" >&2; exit 1; }
Scripts/check-no-personal-data.sh "$CHECK" || { echo "error: the zip holds a trace of this Mac (above)" >&2; rm -f "$ZIP"; exit 1; }
SUM="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"
echo "$SUM  $NAME.zip" > "$ZIP.sha256"

echo
echo "Built $APP ($(du -sh "$APP" | cut -f1 | tr -d ' '))"
echo "  installs: PhotoVault $VERSION, from $FROM"
echo "  JoyTag:   $JOYTAG_VERSION, with its licence"
echo "  zip:      $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
echo "  sha256:   $SUM"
