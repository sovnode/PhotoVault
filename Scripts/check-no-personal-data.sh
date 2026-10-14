#!/bin/sh
# Fails if anything under the given paths carries a trace of who built it, or
# where: this Mac's home folder, the project folder, the account name, git's
# name and email, or any /Users/ path at all. PhotoVault is for the public, so
# nothing it ships may hold one. build-app.sh and build-installer.sh run this
# on everything they make.
#
# Usage: Scripts/check-no-personal-data.sh <file-or-folder>...
#
# Says which files hold what kind of trace, never the trace itself.
set -eu
[ $# -gt 0 ] || { echo "usage: Scripts/check-no-personal-data.sh <file-or-folder>..." >&2; exit 64; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

FOUND=0
for KIND in "home folder" "project folder" "account name" "git name" "git email" "/Users/ path"; do
    case "$KIND" in
        "home folder") P="$HOME" ;;
        "project folder") P="$ROOT" ;;
        "account name") P="$(id -un)" ;;
        "git name") P="$(git -C "$ROOT" config user.name 2>/dev/null || true)" ;;
        "git email") P="$(git -C "$ROOT" config user.email 2>/dev/null || true)" ;;
        "/Users/ path") P="/Users/" ;;
    esac
    # Too short to search for without matching by chance.
    [ "${#P}" -ge 5 ] || continue
    # This script holds the "/Users/" it searches for, and nothing else.
    HITS="$(grep -r -a -l -F --exclude=check-no-personal-data.sh -e "$P" -- "$@" 2>/dev/null || true)"
    if [ -n "$HITS" ]; then
        echo "error: the $KIND is in:" >&2
        printf '%s\n' "$HITS" | sed 's/^/  /' >&2
        FOUND=1
    fi
done
[ "$FOUND" = 0 ] || exit 1
