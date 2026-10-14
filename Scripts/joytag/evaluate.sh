#!/bin/sh
# Runs Scripts/joytag/evaluate.py in the environment `Scripts/joytag/fetch.sh
# test` builds. The report lands in tools/joytag/report/ (git-ignored).
#
# Usage: Scripts/joytag/evaluate.sh --vault "/Volumes/Family Photos" [--count 50]
set -eu
cd "$(dirname "$0")/../.."
J="$(pwd)/tools/joytag"
[ -x "$J/env-test/bin/python" ] || { echo "run Scripts/joytag/fetch.sh test first" >&2; exit 1; }
export TMPDIR="$J/tmp"
exec "$J/env-test/bin/python" -I -B Scripts/joytag/evaluate.py --model "$J/model" --out "$J/report" \
    --groups "Resources/Tag Groups.txt" "$@"
