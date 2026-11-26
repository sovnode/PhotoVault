#!/bin/sh
# Packages SigLIP 2 the way PhotoVault reads it from a vault: the compiled
# image tower, the tag list, its text embeddings, a manifest, and the licence
# (Apache-2.0, which has to travel with the model), in
# tools/siglip/package/SigLIP2/ (git-ignored). Scripts/siglip/install.sh copies
# that folder to <vault>/.catalog/models/SigLIP2/.
#
# Run after Scripts/siglip/convert.sh (the model) and Scripts/siglip/evaluate.sh
# (the tag list's text embeddings, from Scripts/siglip/vocabulary.txt):
#
#   Scripts/siglip/package.sh
#
# The licence is the Apache License 2.0's standard text, taken from JoyTag's
# package (tools/joytag in this checkout or the main one), with a notice naming
# SigLIP 2 and its source.
set -eu
cd "$(dirname "$0")/../.."
S="$(pwd)/tools/siglip"
MODEL="$S/coreml/SigLIP2.mlmodelc"
TEXT="$S/text"
[ -d "$MODEL" ] || { echo "no $MODEL — run Scripts/siglip/convert.sh first" >&2; exit 1; }
[ -f "$TEXT/text_embeddings.f32" ] || { echo "no $TEXT — run Scripts/siglip/evaluate.sh first" >&2; exit 1; }
APACHE=""
for f in tools/joytag/code/LICENSE tools/joytag/package/JoyTag/LICENSE.txt; do
    [ -f "$f" ] && { APACHE="$f"; break; }
done
[ -n "$APACHE" ] || { echo "no Apache-2.0 text found (tools/joytag/code/LICENSE)" >&2; exit 1; }
head -1 "$APACHE" | grep -q "Apache License" || { echo "$APACHE isn't the Apache License" >&2; exit 1; }

# The Hugging Face revision fetch.sh pins, and the tag list's own revision:
# together the version PhotoVault records for every photo SigLIP 2 tags. Bump
# TAGLIST when vocabulary.txt changes.
REVISION=3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab
TAGLIST=t1
VERSION="$(echo "$REVISION" | cut -c1-7)-$TAGLIST"
read_json() { sed -n "s/.*\"$1\": \([^,}]*\).*/\1/p" "$TEXT/text.json" | head -1; }
DIM=$(read_json dim)
SCALE=$(read_json logit_scale)
BIAS=$(read_json logit_bias)
COUNT=$(grep -c . "$TEXT/tags.txt")

OUT="$S/package/SigLIP2"
STAGE="$S/package/.SigLIP2-incoming"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$MODEL" "$STAGE/SigLIP2.mlmodelc"
cp "$TEXT/tags.txt" "$STAGE/tags.txt"
cp "$TEXT/text_embeddings.f32" "$STAGE/text_embeddings.f32"
{
    echo "SigLIP 2 (google/siglip2-base-patch16-256), by Google, is licensed under"
    echo "the Apache License, Version 2.0, below. PhotoVault ships its image tower"
    echo "converted to Core ML, and text embeddings of PhotoVault's tag list made"
    echo "with its text tower; neither is otherwise modified."
    echo "Source: https://huggingface.co/google/siglip2-base-patch16-256 at $REVISION"
    echo
    cat "$APACHE"
} > "$STAGE/LICENSE.txt"
cat > "$STAGE/manifest.json" <<JSON
{
  "tool": "SigLIP 2",
  "prefix": "sg",
  "version": "$VERSION",
  "model": "SigLIP2.mlmodelc",
  "tags": "tags.txt",
  "textEmbeddings": "text_embeddings.f32",
  "input": "image",
  "output": "embedding",
  "imageSize": 256,
  "dim": $DIM,
  "logitScale": $SCALE,
  "logitBias": $BIAS,
  "scoreThreshold": 0.05,
  "relativeThreshold": 4,
  "relativeFloor": 0.002,
  "tagCount": $COUNT,
  "source": "huggingface.co/google/siglip2-base-patch16-256 at $REVISION, converted by Scripts/siglip/convert.sh",
  "license": "Apache-2.0"
}
JSON
rm -rf "$OUT"
mv "$STAGE" "$OUT"
echo "Packaged SigLIP 2 $VERSION ($COUNT tags, $(du -sh "$OUT" | cut -f1 | tr -d ' ')) in $OUT"
