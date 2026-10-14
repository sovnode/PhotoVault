"""Converts JoyTag to Core ML and checks the result.

Run it through Scripts/joytag/convert.sh, which uses the environment that
`Scripts/joytag/fetch.sh convert` builds, after Scripts/joytag/evaluate.sh:

    Scripts/joytag/convert.sh --vault "/Volumes/Family Photos"

1. Builds JoyTag's network from its own published code (Models.py) and loads
   the safetensors weights.
2. Checks PyTorch against the ONNX scores evaluate.py saved for the same
   photos' thumbnails, so the converted model starts from the one tested.
3. Traces it and converts it to a Core ML program in 32-bit precision, saved
   as tools/joytag/coreml/JoyTag.mlpackage.
4. Runs it with Core ML on the CPU over the same thumbnails and compares it
   with PyTorch: score differences, and whether the same tags clear the
   threshold. Smaller versions are tried the same way and reported, then
   deleted: 16-bit maths, 16-bit maths with the attention kept in 32-bit, and
   8-bit weights. None of them keeps JoyTag's tags.

The Neural Engine and GPU are left alone: running there makes macOS
compile the model into a cache outside the project. Photos are read straight
from the vault into memory, as in evaluate.py; nothing derived from them is
written.
"""

import argparse
import json
import os
import shutil
import statistics
import sys
import time
import types
import warnings
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch

# Shape checks in JoyTag's forward become constants when traced, which is right
# for a fixed 448-pixel input.
warnings.filterwarnings("ignore", category=torch.jit.TracerWarning)

sys.path.insert(0, str(Path(__file__).resolve().parent))  # this folder's own modules
from common import pick, prepare, thumbnail


def load_joytag(code_dir: Path, model_dir: Path) -> torch.nn.Module:
    """JoyTag's network, built by its own Models.py, read as published.

    Models.py imports helpers from transformers, einops and torchvision that
    only its other model types use; the ViT that JoyTag ships calls none of
    them. Stand-ins that fail if called take their place, so nothing extra is
    installed and nothing is quietly substituted. It is also written for
    Python 3.10 annotations ("Path | str"); postponing annotations lets
    Python 3.9 read it unchanged.
    """
    def unavailable(name):
        def fail(*args, **kwargs):
            raise RuntimeError(f"{name} isn't installed; JoyTag's ViT shouldn't need it")
        return fail

    for name in ("transformers", "transformers.activations", "einops", "einops.layers",
                 "einops.layers.torch", "torchvision"):
        sys.modules[name] = types.ModuleType(name)
    sys.modules["transformers.activations"].QuickGELUActivation = unavailable("QuickGELUActivation")
    sys.modules["einops.layers.torch"].Rearrange = unavailable("einops Rearrange")
    sys.modules["einops"].repeat = unavailable("einops.repeat")
    sys.modules["torchvision"].ops = types.SimpleNamespace(stochastic_depth=unavailable("stochastic_depth"))

    path = code_dir / "Models.py"
    module = types.ModuleType("Models")
    module.__file__ = str(path)
    sys.modules["Models"] = module
    exec(compile("from __future__ import annotations\n" + path.read_text(), str(path), "exec"), module.__dict__)
    model = module.VisionModel.load_model(model_dir)
    model.eval()
    return model


class Logits(torch.nn.Module):
    """Image tensor in, tag logits out — JoyTag without its dict wrapper."""

    def __init__(self, model: torch.nn.Module):
        super().__init__()
        self.model = model

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.model({"image": image})["tags"]


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def compare(reference: list, other: list, threshold: float) -> dict:
    """How far `other`'s probabilities are from `reference`'s, photo by photo."""
    max_diff = max(float(np.max(np.abs(r - o))) for r, o in zip(reference, other))
    mean_diff = statistics.mean(float(np.mean(np.abs(r - o))) for r, o in zip(reference, other))
    same, flips = 0, 0
    for r, o in zip(reference, other):
        a, b = set(np.nonzero(r > threshold)[0]), set(np.nonzero(o > threshold)[0])
        same += a == b
        flips += len(a ^ b)
    return {"max_diff": max_diff, "mean_diff": mean_diff, "same_tags": same, "tag_flips": flips}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vault", required=True)
    ap.add_argument("--joytag", required=True, help="tools/joytag")
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--seed", type=int, default=13)
    ap.add_argument("--threshold", type=float, default=0.4)
    args = ap.parse_args()

    vault, j = Path(args.vault), Path(args.joytag)
    model_dir, out = j / "model", j / "coreml"
    out.mkdir(exist_ok=True)
    tags = [t for t in (model_dir / "top_tags.txt").read_text().split("\n") if t]
    size = json.loads((model_dir / "config.json").read_text())["image_size"]
    evaluated = json.loads((j / "report" / "results.json").read_text())

    # The same photos evaluate.py used, read the same way.
    picks, _ = pick(vault, args.count, args.seed)
    assert [p[0] for p in picks] == [r["file"] for r in evaluated["results"]], \
        "a different set of photos from evaluate.py's; rerun it first"
    pack = os.open(vault / ".catalog" / "thumbs.pack", os.O_RDONLY)
    inputs = [prepare(thumbnail(pack, off, length), size)[None] for _, off, length in picks]
    os.close(pack)

    print("1. Building JoyTag from its own code")
    net = Logits(load_joytag(j / "code", model_dir)).eval()
    with torch.no_grad():
        t0 = time.perf_counter()
        ref_logits = [net(torch.from_numpy(x)).numpy()[0] for x in inputs]
        torch_seconds = (time.perf_counter() - t0) / len(inputs)
    reference = [sigmoid(l) for l in ref_logits]

    # evaluate.py kept every ONNX score above 0.1, rounded to 4 places.
    onnx_diff, missing = 0.0, 0
    index = {t: i for i, t in enumerate(tags)}
    for probs, r in zip(reference, evaluated["results"]):
        saved = r["thumbnail"]
        for i in np.nonzero(probs > 0.11)[0]:
            if tags[i] not in saved:
                missing += 1
        for tag, score in saved.items():
            onnx_diff = max(onnx_diff, abs(float(probs[index[tag]]) - score))
    print(f"2. PyTorch against the ONNX model: largest score difference {onnx_diff:.5f}; "
          f"tags above 0.11 the ONNX run didn't have: {missing}")

    print("3. Tracing and converting")
    with torch.no_grad():
        traced = torch.jit.trace(net, torch.from_numpy(inputs[0]))

    def convert(precision):
        return ct.convert(
            traced,
            inputs=[ct.TensorType(name="image", shape=(1, 3, size, size))],
            outputs=[ct.TensorType(name="logits")],
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.macOS14,
            compute_precision=precision,
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )

    def measure(model, path: Path) -> dict:
        model.save(str(path))
        size_mb = sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) / 1e6
        loaded = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
        loaded.predict({"image": inputs[0]})  # the first prediction loads the model
        t0 = time.perf_counter()
        probs = [sigmoid(loaded.predict({"image": x})["logits"][0]) for x in inputs]
        seconds = (time.perf_counter() - t0) / len(inputs)
        return dict(compare(reference, probs, args.threshold), seconds=seconds, mb=size_mb)

    results = {}
    print("4. Core ML, 32-bit, on the CPU")
    model = convert(ct.precision.FLOAT32)
    model.short_description = ("JoyTag (huggingface.co/fancyfeast/joytag, revision 6b7f163): a 448×448 "
                               "RGB image, padded white and normalised, in; 5,813 tag logits out.")
    model.license = "Apache-2.0"
    kept = out / "JoyTag.mlpackage"
    shutil.rmtree(kept, ignore_errors=True)
    results["32-bit (kept)"] = measure(model, kept)

    trials = out / "trials"
    shutil.rmtree(trials, ignore_errors=True)
    trials.mkdir()
    attention_in_32 = ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in ("matmul", "softmax"))
    int8 = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_channel"))
    for label, make in (
        ("16-bit maths", lambda: convert(ct.precision.FLOAT16)),
        ("16-bit, attention in 32-bit", lambda: convert(attention_in_32)),
        ("8-bit weights, 32-bit maths", lambda: cto.linear_quantize_weights(
            ct.models.MLModel(str(kept), compute_units=ct.ComputeUnit.CPU_ONLY), config=int8)),
    ):
        print(f"   trying {label}")
        results[label] = measure(make(), trials / "model.mlpackage")
        shutil.rmtree(trials / "model.mlpackage")
    trials.rmdir()

    lines = [
        "# JoyTag in Core ML",
        "",
        f"Converted with coremltools {ct.__version__} from torch {torch.__version__}; checked on the "
        f"thumbnails of the same {len(inputs)} photos as the test, on the CPU.",
        "",
        f"- PyTorch against the ONNX model used in the test: largest score difference {onnx_diff:.5f} "
        f"(ONNX scores were saved to 4 places).",
        f"- PyTorch on the CPU: {torch_seconds:.2f} s per photo.",
        "",
        "| Core ML | Size | Time per photo | Largest score difference | Mean difference | "
        f"Photos with identical tags at {args.threshold} | Tags that flipped |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for label, r in results.items():
        diff = "invalid (NaN)" if np.isnan(r["max_diff"]) else f"{r['max_diff']:.5f}"
        mean = "invalid (NaN)" if np.isnan(r["mean_diff"]) else f"{r['mean_diff']:.6f}"
        lines.append(f"| {label} | {r['mb']:.0f} MB | {r['seconds']:.2f} s | {diff} | {mean} | "
                     f"{r['same_tags']} of {len(inputs)} | {r['tag_flips']} |")
    lines += ["", "Differences are against PyTorch in 32-bit, JoyTag's own code. Only the 32-bit model "
              "keeps JoyTag's tags; the Neural Engine computes in 16-bit, so whether it can run JoyTag at "
              "all is a separate question."]
    (j / "report" / "conversion.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
