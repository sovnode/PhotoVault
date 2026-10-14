#!/bin/sh
# Runs Scripts/joytag/convert.py in the environment `Scripts/joytag/fetch.sh
# convert` builds. Run Scripts/joytag/evaluate.sh first: the conversion is
# checked against its results. The models land in tools/joytag/coreml/ and the
# report in tools/joytag/report/conversion.md (both git-ignored).
#
# Usage: Scripts/joytag/convert.sh --vault "/Volumes/Family Photos"
set -eu
cd "$(dirname "$0")/../.."
J="$(pwd)/tools/joytag"
[ -x "$J/env-convert/bin/python" ] || { echo "run Scripts/joytag/fetch.sh convert first" >&2; exit 1; }
[ -f "$J/report/results.json" ] || { echo "run Scripts/joytag/evaluate.sh first" >&2; exit 1; }
export TMPDIR="$J/tmp"
exec "$J/env-convert/bin/python" -I -B Scripts/joytag/convert.py --joytag "$J" "$@"
