"""Shared by evaluate.py and convert.py: picking test photos from a vault,
reading their thumbnails, and JoyTag's preprocessing.

Everything is read straight into memory. Nothing derived from a photo is
written anywhere.
"""

import io
import os
import random
import sqlite3
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

MEAN = np.array([0.48145466, 0.4578275, 0.40821073], dtype=np.float32)
STD = np.array([0.26862954, 0.26130258, 0.27577711], dtype=np.float32)


def prepare(image: Image.Image, size: int) -> np.ndarray:
    """JoyTag's prepare_image without torch: pad to a white square, bicubic
    resize, scale to 0-1, normalise with CLIP's mean and std, channels first."""
    image = image.convert("RGB")
    w, h = image.size
    side = max(w, h)
    square = Image.new("RGB", (side, side), (255, 255, 255))
    square.paste(image, ((side - w) // 2, (side - h) // 2))
    if side != size:
        square = square.resize((size, size), Image.BICUBIC)
    x = np.asarray(square, dtype=np.float32) / 255.0
    return ((x - MEAN) / STD).transpose(2, 0, 1)


def pick(vault: Path, count: int, seed: int):
    """(rel_path, thumb_off, thumb_len) for `count` photos — one at random from
    each of `count` equal slices of the vault's file-name order — and how many
    photos the vault has. The catalog is opened read-only."""
    db = sqlite3.connect((vault / ".catalog" / "catalog.sqlite").as_uri() + "?mode=ro", uri=True)
    rows = db.execute("""
        SELECT rel_path, thumb_off, thumb_len FROM photo
        WHERE missing = 0 AND trashed = 0 AND media_type = 0 AND thumb_off IS NOT NULL
        ORDER BY sort_name, rel_path""").fetchall()
    db.close()
    rng = random.Random(seed)
    picks = [rows[rng.randrange(k * len(rows) // count, (k + 1) * len(rows) // count)] for k in range(count)]
    return picks, len(rows)


def thumbnail(pack_fd: int, offset: int, length: int) -> Image.Image:
    """A photo's thumbnail, read from the vault's thumbnail pack."""
    return ImageOps.exif_transpose(Image.open(io.BytesIO(os.pread(pack_fd, length, offset))))
