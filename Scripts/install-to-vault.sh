#!/bin/sh
# Installs, or reinstalls, PhotoVault.app onto a vault that already exists.
#
# Usage: Scripts/install-to-vault.sh <mount-point-or-sparsebundle> [release.zip] [--without-joytag]
#
#   Scripts/install-to-vault.sh /Volumes/PhotoVault
#   Scripts/install-to-vault.sh /Volumes/PhotoVault releases/PhotoVault-1.0.0.zip
#
# With no release, builds the current source and installs that. With a release
# saved by release.sh, installs that exact build instead — which is how you roll
# a vault back to an older version without rebuilding it. (Rebuilding old
# source isn't always possible: the macOS 27 SDK broke the September code until
# Xcode was installed.)
#
#   Scripts/install-to-vault.sh /Volumes/PhotoVault
#   Scripts/install-to-vault.sh ~/PhotoVault.sparsebundle
#
# Leaves Photos/ and the catalog alone: the catalog is checked before and after
# and the run fails if the row count moved. To create a vault from nothing, use
# new-vault.sh instead.
#
# JoyTag goes into .catalog/models/ too (Scripts/joytag/install.sh), unless the
# vault already has it or --without-joytag says not to. Without it the app
# works as before, minus tagging.

set -e
cd "$(dirname "$0")/.."

TARGET=""
RELEASE=""
WITH_JOYTAG=1
for arg in "$@"; do
    case "$arg" in
        --without-joytag) WITH_JOYTAG=0 ;;
        *) if [ -z "$TARGET" ]; then TARGET="$arg"; elif [ -z "$RELEASE" ]; then RELEASE="$arg"; fi ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "usage: Scripts/install-to-vault.sh <mount-point-or-sparsebundle> [release.zip]" >&2
    echo "example: Scripts/install-to-vault.sh /Volumes/PhotoVault" >&2
    exit 64
fi

if [ -n "$RELEASE" ]; then
    [ -f "$RELEASE" ] || { echo "error: no such release: $RELEASE" >&2; exit 1; }
    # A saved release carries a checksum; refuse one that no longer matches it.
    if [ -f "$RELEASE.sha256" ]; then
        EXPECTED="$(awk '{ print $1 }' "$RELEASE.sha256")"
        ACTUAL="$(shasum -a 256 "$RELEASE" | awk '{ print $1 }')"
        [ "$EXPECTED" = "$ACTUAL" ] || { echo "error: $RELEASE does not match its recorded checksum" >&2; exit 1; }
        echo "Release: $RELEASE (checksum verified)"
    else
        echo "Release: $RELEASE (no checksum file to verify against)"
    fi
fi
TARGET="${TARGET%/}"

# Physical path, symlinks resolved — hdiutil reports the resolved path (/tmp
# comes back as /private/tmp), so a raw string compare would miss the match.
physical_path() {
    _dir="$(dirname "$1")"
    _base="$(basename "$1")"
    ( cd "$_dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$_base" )
}

# The mount point of an already-attached image, or empty. hdiutil info prints
# an "image-path : ..." header then tab-separated device lines whose third
# field is the mount point, when there is one.
mount_for_bundle() {
    hdiutil info | awk -F'\t' -v img="$1" '
        /^image-path[ \t]*:/ {
            cur = $0
            sub(/^image-path[ \t]*:[ \t]*/, "", cur)
            next
        }
        cur == img && NF >= 3 && $3 ~ /^\// { print $3; exit }
    '
}

# ---------------------------------------------------------------- resolve

case "$TARGET" in
    *.sparsebundle|*.sparseimage|*.dmg)
        [ -e "$TARGET" ] || { echo "error: no such image: $TARGET" >&2; exit 1; }
        IMG="$(physical_path "$TARGET")"
        MOUNT="$(mount_for_bundle "$IMG")"
        if [ -n "$MOUNT" ]; then
            echo "Already mounted at $MOUNT"
        else
            # Never attach an image that is already attached: hdiutil happily
            # creates a second, unmounted attachment of the same bundle, and
            # detaching either one then takes the real mount down with it.
            echo "Attaching $TARGET"
            MOUNT="$(hdiutil attach "$TARGET" | awk -F'\t' '$3 != "" { print $3 }' | tail -1)"
        fi
        ;;
    *)
        MOUNT="$TARGET"
        ;;
esac

[ -n "$MOUNT" ] && [ -d "$MOUNT" ] || { echo "error: could not resolve a mounted volume for $TARGET" >&2; exit 1; }

# ---------------------------------------------------------------- validate

if [ ! -d "$MOUNT/Photos" ] && [ ! -d "$MOUNT/.catalog" ]; then
    echo "error: $MOUNT has no Photos/ or .catalog/ — this does not look like a vault." >&2
    echo "       To create one: Scripts/new-vault.sh <path> [size]" >&2
    exit 1
fi

echo "Vault:  $MOUNT"

# ---------------------------------------------------------------- quiesce

# The running binary is mapped from the volume, so replacing it underneath a
# live process is a bad idea — and quitting is also what checkpoints the WAL.
# SIGTERM to that one process, not an AppleEvent quit by bundle id: it quits
# only the copy running from this vault (not one open on another vault), and the
# app treats it as a scripted quit — it stops any scan without asking.
if pgrep -f "$MOUNT/PhotoVault.app" >/dev/null 2>&1; then
    echo "PhotoVault is running from this vault — quitting it first."
    pgrep -f "$MOUNT/PhotoVault.app/Contents/MacOS/PhotoVault" | while read -r pid; do kill -TERM "$pid" 2>/dev/null; done
    _waited=0
    while pgrep -f "$MOUNT/PhotoVault.app" >/dev/null 2>&1; do
        [ "$_waited" -ge 15 ] && {
            echo "error: it is still running after 15s. Quit it by hand (Cmd-Q) and retry." >&2
            exit 1
        }
        sleep 1
        _waited=$((_waited + 1))
    done
    echo "  quit cleanly."
fi

# ---------------------------------------------------------------- before

CATALOG="$MOUNT/.catalog/catalog.sqlite"
PACK="$MOUNT/.catalog/thumbs.pack"
ROWS_BEFORE=""
PACK_BEFORE=""
if [ -f "$CATALOG" ]; then
    ROWS_BEFORE="$(sqlite3 "$CATALOG" "SELECT COUNT(*) FROM photo;" 2>/dev/null || echo "")"
    [ -f "$PACK" ] && PACK_BEFORE="$(stat -f %z "$PACK")"
    echo "Catalog: ${ROWS_BEFORE:-?} items, thumbnail pack ${PACK_BEFORE:-0} bytes"
else
    echo "Catalog: none yet — the app will build one on first launch"
fi

if [ -x "$MOUNT/PhotoVault.app/Contents/MacOS/PhotoVault" ]; then
    echo "Replacing the existing app."
else
    echo "Installing the app for the first time."
fi
echo

# ---------------------------------------------------------------- install

if [ -n "$RELEASE" ]; then
    rm -rf "$MOUNT/PhotoVault.app"
    ditto -x -k "$RELEASE" "$MOUNT"
    [ -x "$MOUNT/PhotoVault.app/Contents/MacOS/PhotoVault" ] || { echo "error: $RELEASE did not contain PhotoVault.app" >&2; exit 1; }
    cp Resources/README.txt "$MOUNT/README.txt"
    if [ ! -e "$MOUNT/.Tag Groups.txt" ]; then
        if [ -e "$MOUNT/Tag Groups.txt" ]; then mv "$MOUNT/Tag Groups.txt" "$MOUNT/.Tag Groups.txt"
        else cp "Resources/Tag Groups.txt" "$MOUNT/.Tag Groups.txt"; fi
    fi
    echo "Installed version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/PhotoVault.app/Contents/Info.plist") from $RELEASE"
else
    Scripts/build-app.sh "$MOUNT"
fi
if [ "$WITH_JOYTAG" = "1" ]; then
    Scripts/joytag/install.sh "$MOUNT"
else
    echo "JoyTag: left as it is (--without-joytag)"
fi
echo

# ---------------------------------------------------------------- verify

FAILED=0

if codesign -dv "$MOUNT/PhotoVault.app" 2>&1 | grep -q "adhoc"; then
    echo "  signature:  ad-hoc, valid"
else
    echo "  signature:  MISSING — the app may not launch" >&2
    FAILED=1
fi

if xattr -lr "$MOUNT/PhotoVault.app" 2>/dev/null | grep -qi quarantine; then
    echo "  quarantine: present — clearing"
    xattr -dr com.apple.quarantine "$MOUNT/PhotoVault.app"
else
    echo "  quarantine: none"
fi

if [ -n "$ROWS_BEFORE" ]; then
    ROWS_AFTER="$(sqlite3 "$CATALOG" "SELECT COUNT(*) FROM photo;" 2>/dev/null || echo "")"
    PACK_AFTER=""
    [ -f "$PACK" ] && PACK_AFTER="$(stat -f %z "$PACK")"
    if [ "$ROWS_AFTER" = "$ROWS_BEFORE" ] && [ "$PACK_AFTER" = "$PACK_BEFORE" ]; then
        echo "  catalog:    untouched ($ROWS_AFTER items, pack unchanged)"
    else
        echo "  catalog:    CHANGED — was $ROWS_BEFORE items/$PACK_BEFORE bytes, now $ROWS_AFTER/$PACK_AFTER" >&2
        FAILED=1
    fi
fi

[ "$FAILED" = "1" ] && { echo; echo "Finished with warnings above." >&2; exit 1; }

echo
echo "Done. Open $MOUNT/PhotoVault.app — it rescans changed folders on launch."
