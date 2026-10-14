"""JoyTag on a vault's photos: how it does, before it's converted.

Run it through Scripts/joytag/evaluate.sh, which uses the environment that
`Scripts/joytag/fetch.sh test` builds:

    Scripts/joytag/evaluate.sh --vault "/Volumes/Family Photos"

Picks photos spread evenly across the vault's file-name order (one at random
from each of --count equal slices, seeded, so a rerun picks the same ones) and
runs JoyTag twice on each: on the original, and on the 512-pixel thumbnail
PhotoVault keeps in its thumbnail pack. It uses JoyTag's reference
preprocessing (from its README) and threshold, on onnxruntime's CPU provider.
The Core ML provider would compile the model into a cache outside the project.
It then compares the two runs, and compares JoyTag's tags with the keywords
already in each photo.

It only reads. The catalog is opened read-only, photos and thumbnails are
decoded in memory, and no image is written anywhere. The output is text — file
names, tags and scores — in --out.
"""

import argparse
import io
import json
import os
import re
import statistics
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).resolve().parent))  # this folder's own modules
from common import pick, prepare, thumbnail


# ---------------------------------------------------------------- keywords

XMP_HEADER = b"http://ns.adobe.com/xap/1.0/\x00"
RDF = "{http://www.w3.org/1999/02/22-rdf-syntax-ns#}"
DC = "{http://purl.org/dc/elements/1.1/}"


def jpeg_segments(data: bytes):
    """(marker, payload) for each segment before the image data."""
    if data[:2] != b"\xff\xd8":
        return
    i = 2
    while i + 4 <= len(data) and data[i] == 0xFF:
        marker = data[i + 1]
        if marker in (0xD9, 0xDA):  # end of image, start of scan
            return
        if 0xD0 <= marker <= 0xD7 or marker == 0x01:
            i += 2
            continue
        length = int.from_bytes(data[i + 2:i + 4], "big")
        yield marker, data[i + 4:i + 2 + length]
        i += 2 + length


def iptc_keywords(resources: bytes) -> list:
    """IPTC 2:25 (Keywords) inside Photoshop image resource 0x0404."""
    words, i = [], 0
    while i + 12 <= len(resources) and resources[i:i + 4] == b"8BIM":
        rid = int.from_bytes(resources[i + 4:i + 6], "big")
        name_len = resources[i + 6]
        j = i + 7 + name_len + ((1 + name_len) % 2)  # Pascal name, padded to even
        size = int.from_bytes(resources[j:j + 4], "big")
        block = resources[j + 4:j + 4 + size]
        if rid == 0x0404:
            k = 0
            while k + 5 <= len(block) and block[k] == 0x1C:
                record, dataset = block[k + 1], block[k + 2]
                n = int.from_bytes(block[k + 3:k + 5], "big")
                if record == 2 and dataset == 25:
                    words.append(block[k + 5:k + 5 + n].decode("utf-8", "replace"))
                k += 5 + n
        i = j + 4 + size + (size % 2)
    return words


def keywords(data: bytes):
    """The photo's keywords — XMP dc:subject, else IPTC — and where from."""
    for marker, payload in jpeg_segments(data):
        if marker == 0xE1 and payload.startswith(XMP_HEADER):
            try:
                root = ET.fromstring(payload[len(XMP_HEADER):].strip(b"\x00 \t\r\n"))
            except ET.ParseError:
                continue
            words = [li.text.strip() for subject in root.iter(DC + "subject")
                     for li in subject.iter(RDF + "li") if li.text and li.text.strip()]
            if words:
                return words, "XMP"
    for marker, payload in jpeg_segments(data):
        if marker == 0xED and payload.startswith(b"Photoshop 3.0\x00"):
            words = iptc_keywords(payload[14:])
            if words:
                return words, "IPTC"
    return [], None


# ---------------------------------------------------------------- tag groups

def load_groups(path: Path):
    """Resources/Tag Groups.txt: group order, and each tag's groups. Matching
    ignores capitals and treats a space and an underscore as the same."""
    order, where, current = [], {}, None
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1].strip()
            order.append(current)
        elif current:
            where.setdefault(group_key(line), []).append(current)
    return order, where


def group_key(tag: str) -> str:
    return tag.replace("_", " ").strip().lower()


# Everyday photo subjects, to see which ones JoyTag has no tag for at all.
COMMON_SUBJECTS = """man woman baby child family crowd dog cat bird horse cow sheep pig chicken duck fish rabbit deer
bear elephant giraffe zebra lion tiger monkey car truck bus train airplane helicopter boat ship bicycle motorcycle
tractor house building church bridge castle tower skyscraper street road city farm barn garden park playground beach
ocean lake river waterfall mountain forest desert snow rain sunset sky cloud tree flower grass cake birthday_cake
pizza bread fruit wine beer coffee tea table chair bed couch kitchen bedroom bathroom television computer laptop
phone camera book guitar piano ball soccer_ball baseball basketball tennis_racket golf swimming fishing camping tent
picnic fireworks christmas christmas_tree halloween wedding wedding_dress graduation birthday gift balloon candle
flag statue fountain pool glasses sunglasses hat umbrella smile hug kiss dancing eating sleeping reading""".split()


def normalise(word: str) -> str:
    """For matching JoyTag tags against keywords: no disambiguation suffix,
    spaces for underscores, lower case, a plural's last word made singular."""
    w = re.sub(r"_\([^)]*\)$", "", word).replace("_", " ").strip().lower()
    parts = w.split(" ")
    last = parts[-1]
    if len(last) > 3 and last.endswith("s") and not last.endswith("ss"):
        if last.endswith("ies"):
            last = last[:-3] + "y"
        elif last.endswith(("ches", "shes", "xes")):
            last = last[:-2]
        else:
            last = last[:-1]
    return " ".join(parts[:-1] + [last])


# ---------------------------------------------------------------- run

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vault", required=True)
    ap.add_argument("--model", required=True, help="folder with model.onnx and top_tags.txt")
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--seed", type=int, default=13)
    ap.add_argument("--threshold", type=float, default=0.4)
    ap.add_argument("--groups", help="tag groups file (Resources/Tag Groups.txt)")
    args = ap.parse_args()

    vault, model_dir, out = Path(args.vault), Path(args.model), Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    tags = (model_dir / "top_tags.txt").read_text().split("\n")
    tags = [t for t in tags if t]
    config = json.loads((model_dir / "config.json").read_text())
    size = config["image_size"]

    picks, total = pick(vault, args.count, args.seed)

    session = ort.InferenceSession(str(model_dir / "model.onnx"), providers=["CPUExecutionProvider"])

    def scores(x: np.ndarray) -> np.ndarray:
        logits = session.run(None, {"input": x[None]})[0][0]
        return 1.0 / (1.0 + np.exp(-logits))

    pack = os.open(vault / ".catalog" / "thumbs.pack", os.O_RDONLY)
    results, failures = [], []
    for n, (rel, off, length) in enumerate(picks, 1):
        try:
            t0 = time.perf_counter()
            data = (vault / rel).read_bytes()
            original = ImageOps.exif_transpose(Image.open(io.BytesIO(data)))
            x_orig = prepare(original, size)
            t1 = time.perf_counter()
            p_orig = scores(x_orig)
            t2 = time.perf_counter()
            thumb = thumbnail(pack, off, length)
            x_thumb = prepare(thumb, size)
            t3 = time.perf_counter()
            p_thumb = scores(x_thumb)
            t4 = time.perf_counter()
            words, source = keywords(data)
        except Exception as e:  # one unreadable photo shouldn't end the run
            failures.append(f"{rel}: {type(e).__name__}: {e}")
            continue
        results.append({
            "file": rel,
            "original_size": list(original.size),
            "thumbnail_size": list(thumb.size),
            "keywords": words,
            "keyword_source": source,
            # Everything above 0.1, for looking at the threshold later.
            "original": {tags[i]: round(float(p_orig[i]), 4) for i in np.nonzero(p_orig > 0.1)[0]},
            "thumbnail": {tags[i]: round(float(p_thumb[i]), 4) for i in np.nonzero(p_thumb > 0.1)[0]},
            "score_correlation": float(np.corrcoef(p_orig, p_thumb)[0, 1]),
            "seconds": {"original_decode": t1 - t0, "original_infer": t2 - t1,
                        "thumbnail_decode": t3 - t2, "thumbnail_infer": t4 - t3},
        })
        print(f"\r  {n}/{len(picks)}", end="", flush=True)
    os.close(pack)
    print()
    for f in failures:
        print("  couldn't read", f)

    (out / "results.json").write_text(json.dumps({
        "vault": vault.name, "photos_in_vault": total, "count": args.count,
        "seed": args.seed, "threshold": args.threshold, "tags": len(tags),
        "failures": failures, "results": results}, indent=1))
    (out / "selection.txt").write_text("".join(r["file"] + "\n" for r in results))
    groups = load_groups(Path(args.groups)) if args.groups else ([], {})
    write_report(results, args, total, out / "report.md", groups, tags)
    return 0


# ---------------------------------------------------------------- report

def above(d: dict, t: float) -> dict:
    return {k: v for k, v in d.items() if v > t}


def median(xs):
    return statistics.median(xs) if xs else 0


def write_report(results, args, total, path: Path, groups, vocabulary):
    t = args.threshold
    lines = []
    w = lines.append
    jt_counts, kw_counts, overlaps, precision, recall = [], [], [], [], []
    jaccards, gained, lost = [], Counter(), Counter()
    freq, freq_score, freq_kw = Counter(), Counter(), Counter()
    kw_freq, kw_matched = Counter(), Counter()
    order, where = groups
    group_of = lambda tag: where.get(group_key(tag), ["Other"])
    photos_in_group, r18_tags = Counter(), Counter()
    for r in results:
        o, th = above(r["original"], t), above(r["thumbnail"], t)
        kws = {normalise(k) for k in r["keywords"]}
        jt = {normalise(k) for k in o}
        both = jt & kws
        jt_counts.append(len(o))
        kw_counts.append(len(r["keywords"]))
        overlaps.append(len(both))
        if jt:
            precision.append(len(both) / len(jt))
        if kws:
            recall.append(len(both) / len(kws))
        union = set(o) | set(th)
        jaccards.append(len(set(o) & set(th)) / len(union) if union else 1.0)
        gained.update(set(th) - set(o))
        lost.update(set(o) - set(th))
        for tag, s in o.items():
            freq[tag] += 1
            freq_score[tag] += s
            if normalise(tag) in kws:
                freq_kw[tag] += 1
            if "R18" in group_of(tag):
                r18_tags[tag] += 1
        for g in {g for tag in o for g in group_of(tag)}:
            photos_in_group[g] += 1
        for k in kws:
            kw_freq[k] += 1
            if k in jt:
                kw_matched[k] += 1
    secs = {k: [r["seconds"][k] for r in results] for k in results[0]["seconds"]}
    n = len(results)

    w(f"# JoyTag on {Path(args.vault).name}")
    w("")
    w(f"{n} photos, one at random from each of {n} equal slices of the vault's "
      f"{total:,} photos in file-name order (seed {args.seed}). JoyTag run on each "
      f"original and on its 512-pixel thumbnail; threshold {t}. Keywords are the "
      "ones already in the photos.")
    w("")
    w("## Summary")
    w("")
    w(f"- JoyTag tags per photo (original): median {median(jt_counts)}, "
      f"range {min(jt_counts)}–{max(jt_counts)}")
    w(f"- Keywords per photo: median {median(kw_counts)}, range {min(kw_counts)}–{max(kw_counts)}")
    w(f"- Photos where at least one JoyTag tag matches a keyword: "
      f"{sum(1 for x in overlaps if x)} of {n}; median matches per photo {median(overlaps)}")
    w(f"- Share of JoyTag's tags that are also keywords: median {median(precision):.0%}; "
      f"share of keywords JoyTag also found: median {median(recall):.0%}")
    if order:
        w(f"- Photos that would appear under R18: {photos_in_group['R18']} of {n} — "
          + ", ".join(f"`{k}` ×{c}" for k, c in r18_tags.most_common()))
    w(f"- Thumbnail against original: tag sets overlap by a median of {median(jaccards):.0%} "
      f"(intersection over union); score correlation median "
      f"{median([r['score_correlation'] for r in results]):.3f}")
    w(f"- Time per photo on the CPU: original {median(secs['original_decode']):.2f} s to decode "
      f"+ {median(secs['original_infer']):.2f} s to tag; thumbnail "
      f"{median(secs['thumbnail_decode']):.3f} s + {median(secs['thumbnail_infer']):.2f} s (medians)")
    w("")
    w("## JoyTag's tags across these photos")
    w("")
    w("Every tag above the threshold on at least two originals, with its group from "
      "the tag groups file.")
    w("")
    w("| Tag | Photos | Mean score | Also a keyword | Group |")
    w("|---|---:|---:|---:|---|")
    for tag, c in freq.most_common():
        if c < 2:
            break
        w(f"| `{tag}` | {c} | {freq_score[tag] / c:.2f} | {freq_kw[tag]} | {', '.join(group_of(tag))} |")
    once = sorted(tag for tag, c in freq.items() if c == 1)
    w("")
    w(f"On one photo only ({len(once)}): " + ", ".join(f"`{x}`" for x in once))
    if order:
        w("")
        w("## Groups")
        w("")
        w("How many of these photos have at least one tag in each group.")
        w("")
        w("| Group | Photos |")
        w("|---|---:|")
        for g in order + ["Other"]:
            if photos_in_group[g]:
                w(f"| {g} | {photos_in_group[g]} |")
    missing = [x.replace("_", " ") for x in COMMON_SUBJECTS if x not in set(vocabulary)]
    w("")
    w("## Everyday subjects JoyTag has no tag for")
    w("")
    w(f"Of {len(COMMON_SUBJECTS)} common photo subjects, JoyTag's {len(vocabulary):,} tags lack "
      f"{len(missing)}: " + ", ".join(missing) + ". A photo of one of these can only get a "
      "related tag, or a wrong one.")
    w("")
    w("## Keywords across these photos")
    w("")
    w("The 40 most common, and how often JoyTag found the same word.")
    w("")
    w("| Keyword | Photos | JoyTag too |")
    w("|---|---:|---:|")
    for k, c in kw_freq.most_common(40):
        w(f"| {k} | {c} | {kw_matched[k]} |")
    w("")
    w("## Thumbnail against original")
    w("")
    w("Tags most often above the threshold on one and not the other:")
    w("")
    w("- Only on the thumbnail: " + ", ".join(f"`{k}` ×{c}" for k, c in gained.most_common(15)))
    w("- Only on the original: " + ", ".join(f"`{k}` ×{c}" for k, c in lost.most_common(15)))
    w("")
    w("## Photo by photo")
    w("")
    w("In PhotoVault, the smart album **JoyTag test** holds these photos.")
    for i, r in enumerate(results, 1):
        o = above(r["original"], t)
        th = above(r["thumbnail"], t)
        kws = {normalise(k) for k in r["keywords"]}
        w("")
        w(f"### {i}. {Path(r['file']).name}")
        w("")
        by_group = {}
        for k, _ in sorted(o.items(), key=lambda kv: -kv[1]):
            for g in group_of(k):
                by_group.setdefault(g, []).append(f"**{k}**" if normalise(k) in kws else k)
        parts = [f"{g}: {', '.join(by_group[g])}" for g in order + ["Other"] if g in by_group]
        w(f"- JoyTag — {' · '.join(parts) if parts else '(nothing above the threshold)'}")
        diff_plus = sorted(set(th) - set(o))
        diff_minus = sorted(set(o) - set(th))
        if diff_plus or diff_minus:
            w(f"- Thumbnail differs: " + ", ".join([f"+{k}" for k in diff_plus] + [f"−{k}" for k in diff_minus]))
        else:
            w("- Thumbnail: same tags")
        w(f"- Keywords: {', '.join(r['keywords']) or '(none)'}")
    w("")
    w("Bold JoyTag tags match a keyword.")
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
