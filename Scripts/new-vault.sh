#!/bin/sh
# Creates a new PhotoVault sparse bundle, mounts it, and installs the app.
#
# Usage: Scripts/new-vault.sh <bundle-path> [size] [--without-joytag]
#
#   Scripts/new-vault.sh ~/PhotoVault.sparsebundle
#   Scripts/new-vault.sh ~/Archive.sparsebundle 200g
#
# The size is a ceiling, not an allocation — a sparse bundle only occupies what
# it actually holds, so there is little reason to be stingy. Bear in mind that
# sparse bundles never shrink on delete: reclaiming space needs `hdiutil
# compact`, and the ceiling is not what costs you anything.

set -e
cd "$(dirname "$0")/.."

BUNDLE=""
SIZE=""
WITH_JOYTAG=1
for arg in "$@"; do
    case "$arg" in
        --without-joytag) WITH_JOYTAG=0 ;;
        *) if [ -z "$BUNDLE" ]; then BUNDLE="$arg"; elif [ -z "$SIZE" ]; then SIZE="$arg"; fi ;;
    esac
done
SIZE="${SIZE:-500g}"

if [ -z "$BUNDLE" ]; then
    echo "usage: Scripts/new-vault.sh <bundle-path> [size] [--without-joytag]" >&2
    echo "example: Scripts/new-vault.sh ~/PhotoVault.sparsebundle 500g" >&2
    exit 64
fi

case "$BUNDLE" in
    *.sparsebundle) ;;
    *) BUNDLE="$BUNDLE.sparsebundle" ;;
esac

if [ -e "$BUNDLE" ]; then
    echo "error: $BUNDLE already exists." >&2
    echo "       To put the app on an existing vault, mount it and run:" >&2
    echo "       Scripts/build-app.sh /Volumes/<its mount point>" >&2
    exit 1
fi

VOLNAME="$(basename "$BUNDLE" .sparsebundle)"

echo "Creating $BUNDLE ($SIZE ceiling, volume name \"$VOLNAME\")"
# 65536 sectors = 32 MB bands, against the 8 MB default. A 2 GB video spans ~60
# band files instead of 250, which matters during sequential playback. Don't go
# past 64 MB: reclaim granularity gets coarse and the bundle bloats faster.
hdiutil create \
    -size "$SIZE" \
    -fs APFS \
    -type SPARSEBUNDLE \
    -imagekey sparse-band-size=65536 \
    -volname "$VOLNAME" \
    "$BUNDLE" >/dev/null

# Never assume the mount point is /Volumes/$VOLNAME. If a stale mount of the
# same name exists, macOS appends " 1", and everything after this would then be
# pointed at the wrong volume. Read back what was actually mounted.
MOUNT="$(hdiutil attach "$BUNDLE" | awk -F'\t' '$3 != "" { print $3 }' | tail -1)"

if [ -z "$MOUNT" ] || [ ! -d "$MOUNT" ]; then
    echo "error: created $BUNDLE but could not determine its mount point." >&2
    exit 1
fi
echo "Mounted at $MOUNT"

# The app bootstraps .catalog/ on first launch, but only once it can find a
# Photos directory to anchor on — on a volume holding nothing but the app it
# reports "no .catalog folder found" instead.
mkdir -p "$MOUNT/Photos"

# Written before any media arrives, so Spotlight never gets a window in which
# to index the originals. The app writes this too, but not until first launch.
: > "$MOUNT/.metadata_never_index"

Scripts/build-app.sh "$MOUNT"
if [ "$WITH_JOYTAG" = "1" ]; then
    Scripts/joytag/install.sh "$MOUNT"
fi

echo
echo "Vault ready."
echo
echo "  Bundle:  $BUNDLE"
echo "  Mounted: $MOUNT"
echo
echo "Next:"
echo "  1. Copy your photos and videos into $MOUNT/Photos"
echo "  2. Open $MOUNT/PhotoVault.app — it indexes on first launch"
echo "  3. Eject with Cmd-E from inside the app, not from Finder"
echo
echo "Optional, needs your password — belt and braces on top of the"
echo "\`.metadata_never_index\` marker this script already wrote:"
echo "  sudo mdutil -i off \"$MOUNT\""
