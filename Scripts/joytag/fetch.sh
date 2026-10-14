#!/bin/sh
# Downloads what evaluating, converting and packaging JoyTag needs,
# into tools/joytag/, which git ignores.
#
# Usage: Scripts/joytag/fetch.sh test      the ONNX model and tag list, and a
#                                          Python 3.14 environment with
#                                          onnxruntime (about 410 MB)
#        Scripts/joytag/fetch.sh convert   the safetensors weights and JoyTag's
#                                          model code, and a Python 3.9
#                                          environment with torch and
#                                          coremltools (about 470 MB)
#
# Everything is pinned: the model to one Hugging Face revision, JoyTag's code to
# one GitHub commit, each file checked against its published hash, and each
# Python package to an exact version. Nothing is written outside tools/joytag/:
# pip's cache is off and temporary files go to tools/joytag/tmp.
#
# coremltools 9.0, the newest, has no build for Python 3.14, hence the second
# environment on the Python 3.9 that ships with Xcode.

set -eu
cd "$(dirname "$0")/../.."
J="$(pwd)/tools/joytag"

HF="https://huggingface.co/fancyfeast/joytag/resolve/6b7f16331a6ccf0fdce37d5a9564715f6e772b22"
GH="https://raw.githubusercontent.com/fpgaminer/joytag/ce0c4a451e31b69a92df24c8bcd1c0418e3e4feb"

mkdir -p "$J/model" "$J/code" "$J/tmp"
export TMPDIR="$J/tmp"
export PIP_DISABLE_PIP_VERSION_CHECK=1

# fetch URL DEST sha256|blob HASH — skips a file already present and verified.
# Large files are checked by the SHA-256 Hugging Face publishes; small ones by
# their git blob hash, which both Hugging Face and GitHub publish.
fetch() {
    url="$1"; dest="$2"; kind="$3"; want="$4"
    check() {
        if [ "$kind" = sha256 ]; then shasum -a 256 "$1" | cut -d' ' -f1
        else git hash-object --no-filters "$1"; fi
    }
    if [ -f "$dest" ] && [ "$(check "$dest")" = "$want" ]; then
        echo "  have $(basename "$dest")"; return
    fi
    echo "  downloading $(basename "$dest")"
    curl -fL --retry 3 --silent --show-error -o "$dest.part" "$url"
    got="$(check "$dest.part")"
    if [ "$got" != "$want" ]; then
        rm -f "$dest.part"
        echo "error: $(basename "$dest") doesn't match its published hash (got $got)" >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
    echo "    verified ($kind)"
}

# venv DIR PYTHON PACKAGE==VERSION...
venv() {
    dir="$1"; python="$2"; shift 2
    [ -x "$dir/bin/python" ] || "$python" -m venv "$dir"
    "$dir/bin/python" -m pip install --quiet --no-cache-dir "$@"
    echo "  $(basename "$dir"): $("$dir/bin/python" -V), $*"
}

case "${1:-}" in
test)
    fetch "$HF/model.onnx" "$J/model/model.onnx" sha256 f85b7130e6e549b5b0822537007b7482e8c4c8e754c8d9a5bee08e27050e1097
    fetch "$HF/top_tags.txt" "$J/model/top_tags.txt" blob a3131d7ccefe5f2b15cf49f2cc15eb1a9c6b110a
    fetch "$HF/config.json" "$J/model/config.json" blob ce0dab109bc5f9b55494d29667fa1e421f42e530
    # JoyTag's reference preprocessing and threshold are in its README.
    fetch "$GH/README.md" "$J/code/README.md" blob 7e16054f2781bbb90f66a3a44ce593fb4afd2eba
    venv "$J/env-test" python3.14 onnxruntime==1.31.0 numpy==2.5.4 pillow==12.3.0
    ;;
convert)
    fetch "$HF/model.safetensors" "$J/model/model.safetensors" sha256 5304065c0e4fb26b265194fa2209b8dddfa2b9a7239397c1ae0f47649f91e293
    fetch "$GH/Models.py" "$J/code/Models.py" blob ddeba5f5cd8beb65c7e691e87e650542b4c6d366
    fetch "$GH/LICENSE" "$J/code/LICENSE" blob 261eeb9e9f8b2b4b0d119366dda99c6fd7d35c64
    venv "$J/env-convert" /usr/bin/python3 torch==2.8.0 coremltools==9.0 numpy==2.0.2 pillow==11.3.0 safetensors==0.7.0
    ;;
*)
    echo "usage: Scripts/joytag/fetch.sh test|convert" >&2
    exit 64
    ;;
esac
