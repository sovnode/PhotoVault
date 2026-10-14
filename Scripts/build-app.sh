#!/bin/sh
# Assembles PhotoVault.app from the SwiftPM build.
#
# Usage: Scripts/build-app.sh [destination-dir]
#
# With no destination the bundle lands in build/. Pass the vault's mount point
# to drop it straight onto the volume, which is where it has to live: the app
# finds its catalog by walking up from its own bundle URL.
set -e
cd "$(dirname "$0")/.."

CONFIG=release
DEST="${1:-build}"
APP="$DEST/PhotoVault.app"

# Nothing in the app may say where it was built: PhotoVault is for the public.
# Source paths are written relative to the project, and the linker leaves out
# the debug map, which names every object file by its full path. (So the build
# warns "no debug symbols in executable": that's this, as intended.)
swift build -c "$CONFIG" --product PhotoVault -Xswiftc -file-prefix-map -Xswiftc "$(pwd -P)=." -Xlinker -S
BIN="$(swift build -c "$CONFIG" --product PhotoVault --show-bin-path)/PhotoVault"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoVault"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Built from the supplied artwork by Scripts/make-icon.swift, which masks it to
# Apple's icon shape so macOS doesn't shrink it onto a grey tile.
cp Resources/Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The default tag groups, used when a vault has no Tag Groups.txt of its own.
cp "Resources/Tag Groups.txt" "$APP/Contents/Resources/Tag Groups.txt"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The quarantine note belongs at the volume root, beside the app — it is the
# first thing someone opening a copied vault on another Mac needs.
if [ "$DEST" != "build" ]; then
    cp Resources/README.txt "$DEST/README.txt"
    # .Tag Groups.txt sits beside it, hidden, to be edited: an existing one,
    # which may hold someone's changes, is never replaced, and a visible one
    # from before 1.3.0 is renamed rather than replaced.
    if [ ! -e "$DEST/.Tag Groups.txt" ]; then
        if [ -e "$DEST/Tag Groups.txt" ]; then mv "$DEST/Tag Groups.txt" "$DEST/.Tag Groups.txt"
        else cp "Resources/Tag Groups.txt" "$DEST/.Tag Groups.txt"; fi
    fi
fi

# On a vault, give the volume itself the icon, so a mounted vault is
# recognisable in Finder's sidebar. Finder reads it from .VolumeIcon.icns at the
# root, once the volume's custom-icon flag is set.
# A mount point is on a different device from its parent folder. (Comparing
# df's mount-point column broke on names with spaces, like "Family Photos".)
if [ "$DEST" != "build" ] && [ "$(stat -f %d "$DEST")" != "$(stat -f %d "$DEST/..")" ]; then
    cp Resources/Icon/AppIcon.icns "$DEST/.VolumeIcon.icns"
    xcrun SetFile -a C "$DEST" 2>/dev/null || echo "note: couldn't set the volume icon flag (needs Xcode's SetFile)"
fi

# Ad-hoc signature. Without one, a bundle copied to another machine is not just
# quarantined but unsignable-looking, and Gatekeeper refuses it outright.
codesign -s - -f --deep "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"

Scripts/check-no-personal-data.sh "$APP" || { echo "error: $APP holds a trace of this Mac — not built" >&2; rm -rf "$APP"; exit 1; }

echo "Built $APP"
