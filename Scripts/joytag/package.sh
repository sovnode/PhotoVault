#!/bin/sh
# Packages JoyTag the way PhotoVault reads it from a vault: the compiled model,
# its tag list, a manifest and JoyTag's licence (Apache-2.0, which has to travel
# with the model), in tools/joytag/package/JoyTag/ (git-ignored). The vault
# scripts and PhotoVault Installer copy that folder to
# <vault>/.catalog/models/JoyTag/.
#
# Run after Scripts/joytag/convert.sh, which makes the Core ML model:
#
#   Scripts/joytag/package.sh
#
# The model is compiled here, once, so nothing is ever compiled through the
# system temp folder on a Mac that opens the vault.
set -eu
cd "$(dirname "$0")/../.."
J="$(pwd)/tools/joytag"
SRC="$J/coreml/JoyTag.mlpackage"
TAGS="$J/model/top_tags.txt"
LICENSE="$J/code/LICENSE"
[ -d "$SRC" ] || { echo "no $SRC — run Scripts/joytag/convert.sh first" >&2; exit 1; }
[ -f "$TAGS" ] || { echo "no $TAGS — run Scripts/joytag/fetch.sh test first" >&2; exit 1; }
[ -f "$LICENSE" ] || { echo "no $LICENSE — run Scripts/joytag/fetch.sh convert first" >&2; exit 1; }

# The Hugging Face revision fetch.sh pins; its first seven characters are the
# version PhotoVault records for every photo JoyTag tags.
REVISION=6b7f16331a6ccf0fdce37d5a9564715f6e772b22
VERSION=$(echo "$REVISION" | cut -c1-7)

OUT="$J/package/JoyTag"
STAGE="$J/package/.JoyTag-incoming"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$J/tmp"
TMPDIR="$J/tmp/" xcrun coremlcompiler compile "$SRC" "$STAGE" >/dev/null
cp "$TAGS" "$STAGE/tags.txt"
cp "$LICENSE" "$STAGE/LICENSE.txt"
COUNT=$(grep -c . "$STAGE/tags.txt")
cat > "$STAGE/manifest.json" <<EOF
{
  "tool": "JoyTag",
  "prefix": "jt",
  "version": "$VERSION",
  "model": "JoyTag.mlmodelc",
  "tags": "tags.txt",
  "input": "image",
  "output": "logits",
  "imageSize": 448,
  "threshold": 0.4,
  "tagCount": $COUNT,
  "source": "huggingface.co/fancyfeast/joytag at $REVISION, converted by Scripts/joytag/convert.sh",
  "license": "Apache-2.0"
}
EOF
rm -rf "$OUT"
mv "$STAGE" "$OUT"
echo "Packaged JoyTag $VERSION ($COUNT tags, $(du -sh "$OUT" | cut -f1)) in $OUT"
