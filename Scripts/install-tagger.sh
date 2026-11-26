#!/bin/sh
# Puts one tagging model on a vault and takes the other off, as PhotoVault
# Installer does: SigLIP 2 (the default), JoyTag, or none.
#
# Usage: Scripts/install-tagger.sh <mounted vault> [siglip|joytag|none]
#
# The model taken off goes first, so the vault never needs room for both. Its
# tags stay in the catalog. Each model is copied by its own install script
# (Scripts/siglip/install.sh, Scripts/joytag/install.sh), from the package
# built in this checkout.
set -eu
cd "$(dirname "$0")/.."
MOUNT="${1:-}"
MOUNT="${MOUNT%/}"
CHOICE="$(printf '%s' "${2:-siglip}" | tr '[:upper:]' '[:lower:]')"
[ -n "$MOUNT" ] || { echo "usage: Scripts/install-tagger.sh <mounted vault> [siglip|joytag|none]" >&2; exit 64; }
case "$CHOICE" in
    siglip|joytag|none) ;;
    *) echo "error: tagging is siglip, joytag or none (got $CHOICE)" >&2; exit 64 ;;
esac
[ -d "$MOUNT/.catalog" ] || [ -d "$MOUNT/Photos" ] || { echo "error: $MOUNT doesn't look like a vault" >&2; exit 1; }

remove() {
    folder="$1"; name="$2"
    dest="$MOUNT/.catalog/models/$folder"
    rm -rf "$MOUNT/.catalog/models/.$folder-incoming" "$MOUNT/.catalog/models/.$folder-outgoing"
    if [ -d "$dest" ]; then
        rm -rf "$dest"
        echo "$name: taken off the vault (its tags are kept)"
    fi
}

case "$CHOICE" in
    siglip) remove JoyTag JoyTag; Scripts/siglip/install.sh "$MOUNT" ;;
    joytag) remove SigLIP2 "SigLIP 2"; Scripts/joytag/install.sh "$MOUNT" ;;
    none) remove JoyTag JoyTag; remove SigLIP2 "SigLIP 2"; echo "Tagging: none on this vault" ;;
esac
