"""Scores every photo and video in a vault against SigLIP 2's tag list.

Run it through Scripts/siglip/evaluate.sh:

    Scripts/siglip/evaluate.sh --vault "/path/to/vault"

1. Reads the tag list (Scripts/siglip/vocabulary.txt) and turns each tag's
   phrase into a text embedding with SigLIP 2's text tower, through the
   prompt template SigLIP 2 is documented with ("This is a photo of …").
   The table is saved as tools/siglip/text/ — what PhotoVault would ship, so
   the app needs no text model.
2. Reads each item's 512-pixel thumbnail from the vault's thumbnail pack, in
   memory (videos by their poster frame), prepares it as SigLIP 2's processor
   does — squashed to 256 × 256 with a bilinear resize, scaled to -1…1 — and
   embeds it with the image tower.
3. Scores each item against every tag the way SigLIP 2 does: the sigmoid of
   logit_scale × cosine + logit_bias. Saves the scores to
   tools/siglip/report/scores.npz (git-ignored; derived from the photos).

The vault is only read: the catalog is opened read-only and the thumbnail pack
with os.pread.
"""

import argparse
import io
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageOps
from transformers import AutoTokenizer, SiglipModel

SIZE = 256
TEMPLATE = "This is a photo of {}."


def vocabulary(path: Path):
    """[(group, tag, phrase)] in file order."""
    out, group = [], "Other"
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            group = line[1:-1]
            continue
        tag, _, phrase = line.partition("=")
        tag, phrase = tag.strip(), phrase.strip() or tag.strip()
        out.append((group, tag, phrase))
    seen = set()
    for _, tag, _ in out:
        if tag in seen:
            sys.exit(f"tag listed twice: {tag}")
        seen.add(tag)
    return out


def prepare(image: Image.Image) -> np.ndarray:
    image = image.convert("RGB").resize((SIZE, SIZE), Image.BILINEAR)
    x = np.asarray(image, dtype=np.float32) / 255.0
    return ((x - 0.5) / 0.5).transpose(2, 0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", required=True, type=Path)
    ap.add_argument("--vocabulary", type=Path, default=Path(__file__).with_name("vocabulary.txt"))
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[2] / "tools" / "siglip"
    (root / "report").mkdir(exist_ok=True)
    (root / "text").mkdir(exist_ok=True)
    torch.set_num_threads(os.cpu_count() or 8)

    model = SiglipModel.from_pretrained(str(root / "model"), attn_implementation="eager").eval()
    tok = AutoTokenizer.from_pretrained(str(root / "model"))
    scale, bias = model.logit_scale.exp().item(), model.logit_bias.item()

    vocab = vocabulary(args.vocabulary)
    print(f"1. {len(vocab)} tags in {len({g for g, _, _ in vocab})} groups")
    prompts = [TEMPLATE.format(p) for _, _, p in vocab]
    with torch.no_grad():
        chunks = []
        for i in range(0, len(prompts), 64):
            t = tok(prompts[i:i + 64], padding="max_length", max_length=64, truncation=True, return_tensors="pt")
            chunks.append(model.get_text_features(input_ids=t["input_ids"]))
        text = torch.cat(chunks)
        text = (text / text.norm(dim=-1, keepdim=True)).numpy().astype(np.float32)
    text.tofile(root / "text" / "text_embeddings.f32")
    (root / "text" / "tags.txt").write_text("".join(f"{t}\n" for _, t, _ in vocab))
    (root / "text" / "text.json").write_text(json.dumps(
        {"template": TEMPLATE, "count": len(vocab), "dim": int(text.shape[1]),
         "logit_scale": scale, "logit_bias": bias}, indent=2))

    db = sqlite3.connect((args.vault / ".catalog" / "catalog.sqlite").as_uri() + "?mode=ro", uri=True)
    rows = db.execute("""
        SELECT id, rel_path, media_type, thumb_off, thumb_len FROM photo
        WHERE missing = 0 AND thumb_off IS NOT NULL
        ORDER BY sort_name, rel_path""").fetchall()
    db.close()
    print(f"2. {len(rows)} items with thumbnails")
    fd = os.open(args.vault / ".catalog" / "thumbs.pack", os.O_RDONLY)
    embeds, kept, start = [], [], time.time()
    batch, batch_rows = [], []

    def flush():
        with torch.no_grad():
            pooled = model.vision_model(pixel_values=torch.from_numpy(np.stack(batch))).pooler_output
            embeds.append((pooled / pooled.norm(dim=-1, keepdim=True)).numpy())
        kept.extend(batch_rows)
        batch.clear(); batch_rows.clear()

    for n, (pid, rel, media, off, length) in enumerate(rows):
        try:
            img = ImageOps.exif_transpose(Image.open(io.BytesIO(os.pread(fd, length, off))))
            batch.append(prepare(img))
            batch_rows.append((pid, rel, media))
        except Exception as e:  # a damaged thumbnail is skipped and counted
            print(f"   skipped {rel}: {e}")
        if len(batch) == 16:
            flush()
        if n % 400 == 399:
            print(f"   {n + 1} done, {(time.time() - start) / (n + 1):.3f} s each")
    if batch:
        flush()
    os.close(fd)
    images = np.concatenate(embeds).astype(np.float32)
    print(f"   {len(kept)} embedded in {time.time() - start:.0f} s")

    scores = 1 / (1 + np.exp(-(scale * images @ text.T + bias)))
    np.savez_compressed(root / "report" / "scores.npz",
                        scores=scores.astype(np.float32), images=images,
                        ids=np.array([k[0] for k in kept]),
                        paths=np.array([k[1] for k in kept]),
                        media=np.array([k[2] for k in kept]),
                        tags=np.array([t for _, t, _ in vocab]),
                        groups=np.array([g for g, _, _ in vocab]))
    print("3. saved tools/siglip/report/scores.npz")


if __name__ == "__main__":
    main()
