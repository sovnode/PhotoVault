#!/bin/sh
# Runs Scripts/siglip/evaluate.py in the environment Scripts/siglip/fetch.sh
# builds. Output lands in tools/siglip/ (git-ignored).
#
# Usage: Scripts/siglip/evaluate.sh --vault "/path/to/vault"
set -eu
cd "$(dirname "$0")/../.."
S="$(pwd)/tools/siglip"
[ -x "$S/env/bin/python" ] || { echo "run Scripts/siglip/fetch.sh first" >&2; exit 1; }
export TMPDIR="$S/tmp/" HF_HUB_OFFLINE=1 HF_HOME="$S/tmp/hf" PYTHONWARNINGS=ignore TOKENIZERS_PARALLELISM=false
exec "$S/env/bin/python" -I -B Scripts/siglip/evaluate.py "$@"
