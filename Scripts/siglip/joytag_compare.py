"""JoyTag's tags for the same items evaluate.py scored, for the side-by-side
review report. Uses the ONNX model and test environment that
Scripts/joytag/fetch.sh test downloads (in the main checkout's tools/joytag/,
read only).

    <joytag env python> -I -B Scripts/siglip/joytag_compare.py --vault V --joytag DIR

Saves tools/siglip/report/joytag.json: {photo id: [[tag, score], ...]}.
"""

import argparse
import io
import json
import os
import sqlite3
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)


def prepare(image):
    image = image.convert("RGB")
    w, h = image.size
    side = max(w, h)
    square = Image.new("RGB", (side, side), (255, 255, 255))
    square.paste(image, ((side - w) // 2, (side - h) // 2))
    square = square.resize((448, 448), Image.BICUBIC)
    x = np.asarray(square, dtype=np.float32) / 255.0
    return ((x - MEAN) / STD).transpose(2, 0, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", required=True, type=Path)
    ap.add_argument("--joytag", required=True, type=Path)
    args = ap.parse_args()
    out = Path(__file__).resolve().parents[2] / "tools" / "siglip" / "report" / "joytag.json"
    tags = [t.strip() for t in (args.joytag / "model" / "top_tags.txt").read_text().splitlines() if t.strip()]
    session = ort.InferenceSession(str(args.joytag / "model" / "model.onnx"), providers=["CPUExecutionProvider"])
    db = sqlite3.connect((args.vault / ".catalog" / "catalog.sqlite").as_uri() + "?mode=ro", uri=True)
    rows = db.execute("SELECT id, thumb_off, thumb_len FROM photo WHERE missing = 0 AND thumb_off IS NOT NULL").fetchall()
    db.close()
    fd = os.open(args.vault / ".catalog" / "thumbs.pack", os.O_RDONLY)
    result = {}
    for n, (pid, off, length) in enumerate(rows):
        try:
            img = ImageOps.exif_transpose(Image.open(io.BytesIO(os.pread(fd, length, off))))
        except Exception:
            continue
        logits = session.run(None, {"input": prepare(img)[None]})[0][0]
        p = 1 / (1 + np.exp(-logits))
        idx = np.where(p > 0.4)[0]
        idx = idx[np.argsort(-p[idx])]
        result[str(pid)] = [[tags[i].replace("_", " "), round(float(p[i]), 3)] for i in idx]
        if n % 500 == 499:
            print(f"  {n + 1} done")
    os.close(fd)
    out.write_text(json.dumps(result))
    print(f"saved {len(result)} items to {out}")


if __name__ == "__main__":
    main()
