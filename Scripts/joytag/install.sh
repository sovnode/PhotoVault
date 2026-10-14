#!/bin/sh
# Installs JoyTag into a vault: the folder Scripts/joytag/package.sh builds,
# copied to <vault>/.catalog/models/JoyTag/. PhotoVault looks for it there
# when it opens; it isn't part of the app, so app updates don't re-copy it.
#
# Usage: Scripts/joytag/install.sh <mounted vault>
#
# A new version is copied beside the old, checked against the package, then
# swapped in whole, so a vault never holds half of one model and half of
# another. About 370 MB. A vault that has this version already gets only the
# files it's missing or that differ — its licence, if it was set up before the
# licence shipped — since copying the whole model again would grow its disk
# image by as much.
set -eu
cd "$(dirname "$0")/../.."
MOUNT="${1:-}"
MOUNT="${MOUNT%/}"
[ -n "$MOUNT" ] || { echo "usage: Scripts/joytag/install.sh <mounted vault>" >&2; exit 64; }
[ -d "$MOUNT/.catalog" ] || [ -d "$MOUNT/Photos" ] || { echo "error: $MOUNT doesn't look like a vault" >&2; exit 1; }

PKG="tools/joytag/package/JoyTag"
if [ ! -f "$PKG/manifest.json" ]; then
    echo "JoyTag: not packaged in this checkout, so not installed. The vault works without it, minus tagging."
    echo "        To package it: Scripts/joytag/fetch.sh test, fetch.sh convert, convert.sh, then package.sh."
    exit 0
fi
version() { sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$1/manifest.json"; }

DEST="$MOUNT/.catalog/models/JoyTag"
if [ -f "$DEST/manifest.json" ] && cmp -s "$PKG/manifest.json" "$DEST/manifest.json"; then
    ADDED=0
    for f in $(cd "$PKG" && find . -type f | sed 's|^\./||'); do
        cmp -s "$PKG/$f" "$DEST/$f" && continue
        mkdir -p "$(dirname "$DEST/$f")"
        cp "$PKG/$f" "$DEST/$f.incoming" && mv "$DEST/$f.incoming" "$DEST/$f"
        echo "JoyTag: put back $f"
        ADDED=1
    done
    diff -rq "$PKG" "$DEST" 2>/dev/null | grep -v "^Only in $DEST" | grep -q . \
        && { echo "error: JoyTag in $DEST still differs from the package" >&2; exit 1; }
    [ "$ADDED" = 1 ] || echo "JoyTag: $(version "$DEST") already installed"
    exit 0
fi

mkdir -p "$MOUNT/.catalog/models"
STAGE="$MOUNT/.catalog/models/.JoyTag-incoming"
rm -rf "$STAGE"
cp -R "$PKG" "$STAGE"
diff -rq "$PKG" "$STAGE" >/dev/null || { rm -rf "$STAGE"; echo "error: the copy of JoyTag didn't match the package" >&2; exit 1; }
rm -rf "$DEST.old"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$STAGE" "$DEST"
rm -rf "$DEST.old"
echo "JoyTag: installed $(version "$DEST") in .catalog/models ($(du -sh "$DEST" | cut -f1 | tr -d ' '))"
