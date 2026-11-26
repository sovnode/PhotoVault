#!/bin/sh
# Runs Scripts/siglip/convert.py in the environment Scripts/siglip/fetch.sh
# builds. Output lands in tools/siglip/coreml/ and tools/siglip/reference/
# (both git-ignored).
set -eu
cd "$(dirname "$0")/../.."
S="$(pwd)/tools/siglip"
[ -x "$S/env/bin/python" ] || { echo "run Scripts/siglip/fetch.sh first" >&2; exit 1; }
export TMPDIR="$S/tmp/" HF_HUB_OFFLINE=1 HF_HOME="$S/tmp/hf" PYTHONWARNINGS=ignore
exec "$S/env/bin/python" -I -B Scripts/siglip/convert.py "$@"
