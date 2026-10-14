#!/bin/sh
# Measures whether anything leaves the volume while the app runs.
#
# The unit tests cover what the app itself writes. They cannot see what other
# processes write *on its behalf* — Quick Look, mediaplaybackd,
# VTDecoderXPCService all run out of process — which is what this is for.
#
# Usage: Scripts/verify-containment.sh /Volumes/PhotoVault
#
# Run it, then exercise the app hard: scroll the whole grid, open several
# photos, play a video, let JoyTag tag (or re-tag a selection with Image ▸
# Classifier), quit. Then press return.

set -e
VOLUME="${1:-/Volumes/PhotoVault}"
NAME="$(basename "$VOLUME")"
MARKER="$(mktemp)"
CACHE="$(getconf DARWIN_USER_CACHE_DIR)com.apple.QuickLook.thumbnailcache"

cache_kb() { du -sk "$CACHE" 2>/dev/null | awk '{print $1}'; }

echo "Volume:          $VOLUME"
echo "Quick Look cache: $CACHE"
echo "  before: $(cache_kb) KB"
echo
echo "Leave this running. Exercise the app, quit it, then press return here."

# fs_usage needs root and shows writes as they happen. Video decode runs out of
# process, hence the helper names — watching only the app's own pid has a blind
# spot exactly where the risk is highest.
if [ "$(id -u)" = "0" ]; then
    fs_usage -w -f filesys 2>/dev/null \
      | grep -E 'PhotoVault|mediaplaybackd|VTDecoder|ThumbnailsAgent|quicklookd' \
      | grep -v "$VOLUME" | grep -v '\.sparsebundle' > "$MARKER.fsusage" &
    FS_PID=$!
    echo "(fs_usage running as pid $FS_PID)"
else
    echo "(not root: skipping fs_usage — re-run with sudo for the live trace)"
    FS_PID=""
fi

read -r _

[ -n "$FS_PID" ] && kill "$FS_PID" 2>/dev/null || true

echo
echo "Quick Look cache after: $(cache_kb) KB"
echo
echo "--- does the Quick Look index name this vault? ---"
if [ -f "$CACHE/index.sqlite" ]; then
    strings "$CACHE/index.sqlite" | grep -i "$NAME" | head || echo "  no hits"
else
    echo "  no index.sqlite on this system"
fi

echo
echo "--- files written outside the volume since this script started ---"
# Partial coverage without root: most of /private/var/folders belongs to other
# users and daemons. Run under sudo for the full picture.
find /private/var/folders -newer "$MARKER" -type f 2>/dev/null | head -40
echo "  (nothing above = clean, as far as this sweep can see)"

echo
echo "--- caches, support files and saved state under PhotoVault's name ---"
# Core ML would cache a compiled copy of JoyTag in Caches/<bundle id>; PhotoVault
# runs it through BNNS precisely so that nothing appears here.
FOUND=""
# Metal's shader cache under the user cache folder is known and harmless (compiled
# GPU functions for drawing the interface, no image data), so it's named, not flagged.
for f in "$(getconf DARWIN_USER_CACHE_DIR)local.photovault.app" "$HOME/Library/Caches/local.photovault.app" \
         "$HOME/Library/Application Support/local.photovault.app" \
         "$HOME/Library/Saved Application State/local.photovault.app.savedState" \
         "$HOME/Library/HTTPStorages/local.photovault.app"; do
    [ -e "$f" ] || continue
    find "$f" -newer "$MARKER" -type f 2>/dev/null | while read -r w; do
        case "$w" in
            */com.apple.metal/*) echo "  Metal shader cache (known, no image data): $w" ;;
            *) echo "  written during the run: $w" ;;
        esac
    done
    [ -n "$(find "$f" -newer "$MARKER" -type f 2>/dev/null | grep -v /com.apple.metal/ | head -1)" ] && FOUND=1
done
[ -z "$FOUND" ] && echo "  none"

if [ -f "$MARKER.fsusage" ]; then
    echo
    echo "--- off-volume writes seen live ---"
    head -40 "$MARKER.fsusage"
    echo "  ($(wc -l < "$MARKER.fsusage") lines total)"
fi

echo
echo "IMPORTANT — confirm this test is actually sensitive before trusting a"
echo "clean result. Re-run it while browsing $VOLUME/Photos in Finder's ICON"
echo "view instead of using the app. The cache number should jump. If it does"
echo "not, the check is measuring the wrong place on this macOS version and a"
echo "clean result above means nothing."

rm -f "$MARKER" "$MARKER.fsusage"
