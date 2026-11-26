#!/bin/sh
# Downloads what converting and evaluating SigLIP 2 needs, into tools/siglip/,
# which git ignores.
#
# Usage: Scripts/siglip/fetch.sh
#
# SigLIP 2 base, 16-pixel patches, 256-pixel input (google/siglip2-base-patch16-256,
# Apache-2.0): the weights (1.5 GB, image and text towers), its configs and
# tokenizer, pinned to one Hugging Face revision and checked against the
# published hashes; and a Python 3.9 environment (the one that ships with
# Xcode; coremltools has no build for 3.14) with every package at an exact
# version (about 900 MB).
#
# Nothing is written outside tools/siglip/: pip's cache is off, temporary
# files go to tools/siglip/tmp, and Hugging Face's own cache is never used —
# the files are fetched directly and loaded from their folder.

set -eu
cd "$(dirname "$0")/../.."
S="$(pwd)/tools/siglip"

HF="https://huggingface.co/google/siglip2-base-patch16-256/resolve/3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab"

mkdir -p "$S/model" "$S/tmp"
export TMPDIR="$S/tmp"
export PIP_DISABLE_PIP_VERSION_CHECK=1

# fetch FILE sha256|blob HASH — skips a file already present and verified.
fetch() {
    name="$1"; kind="$2"; want="$3"; dest="$S/model/$name"
    check() {
        if [ "$kind" = sha256 ]; then shasum -a 256 "$1" | cut -d' ' -f1
        else git hash-object --no-filters "$1"; fi
    }
    if [ -f "$dest" ] && [ "$(check "$dest")" = "$want" ]; then
        echo "  have $name"; return
    fi
    echo "  downloading $name"
    curl -fL --retry 3 --silent --show-error -o "$dest.part" "$HF/$name"
    got="$(check "$dest.part")"
    if [ "$got" != "$want" ]; then
        rm -f "$dest.part"
        echo "error: $name doesn't match its published hash (got $got)" >&2
        exit 1
    fi
    mv "$dest.part" "$dest"
    echo "    verified ($kind)"
}

fetch model.safetensors sha256 6125cacc01fa93bdc98a0c5101cefcd69b2ed1f8ab4f38d86f4ad5984f5dc863
fetch tokenizer.json sha256 cb9140fae3ac5122c972d37adf83e1248471a38147ad76f8215c8872c6fd8322
fetch tokenizer.model sha256 61a7b147390c64585d6c3543dd6fc636906c9af3865a5548f27f31aee1d4c8e2
fetch config.json blob b0a6b7804332a660ed5d6c2707b39bed80192010
fetch preprocessor_config.json blob 130986149eee6a6fd9a2eb53da12fbc1a415c0e6
fetch tokenizer_config.json blob d97c5412159422c3b56fbc99076b1dcc25dd7856
fetch special_tokens_map.json blob 8d6368f7e735fbe4781bf6e956b7c6ad0586df80

ENV="$S/env"
[ -x "$ENV/bin/python" ] || /usr/bin/python3 -m venv "$ENV"
"$ENV/bin/python" -m pip install --quiet --no-cache-dir \
    torch==2.8.0 coremltools==9.0 numpy==2.0.2 pillow==11.3.0 safetensors==0.7.0 \
    transformers==4.57.1 tokenizers==0.22.1 sentencepiece==0.2.1 protobuf==6.33.0
echo "  env: $("$ENV/bin/python" -V)"
