#!/bin/sh
# Builds tools/siglip/report/review.html from evaluate.sh's scores (and
# joytag_compare.py's tags, if present). Open it locally; never upload it.
#
# Usage: Scripts/siglip/report.sh --vault "/path/to/vault"
set -eu
cd "$(dirname "$0")/../.."
S="$(pwd)/tools/siglip"
export TMPDIR="$S/tmp/" PYTHONWARNINGS=ignore
exec "$S/env/bin/python" -I -B Scripts/siglip/report.py "$@"
