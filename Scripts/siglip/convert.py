"""Converts SigLIP 2's image tower to Core ML, compiled the way PhotoVault
loads models (an .mlmodelc for Accelerate's BNNS graph).

Run it through Scripts/siglip/convert.sh, after Scripts/siglip/fetch.sh.

1. Loads SigLIP 2 base/16 at 256 pixels from tools/siglip/model.
2. Wraps the image tower so the model's one output is the photo's embedding,
   already normalised to length 1: PhotoVault scores a tag by its dot product
   with the tag's text embedding, scaled and offset by the model's own
   logit_scale and logit_bias, then a sigmoid — SigLIP's own scoring.
3. Traces it and converts it to a Core ML program in 32-bit precision, saved as
   tools/siglip/coreml/SigLIP2.mlpackage, then compiles it to
   tools/siglip/coreml/SigLIP2.mlmodelc.
4. Saves eight test inputs (made up of gradients and seeded noise, nothing from
   any photo) with PyTorch's embeddings for them, in tools/siglip/reference/,
   for the BNNS check (Scripts/siglip/bnns-check.swift).

Core ML itself never runs the model here: running it makes macOS write a
compiled copy into ~/Library/Caches. BNNS is what PhotoVault uses, so BNNS is
what's checked.
"""

import json
import subprocess
import sys
import warnings
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from transformers import SiglipModel

warnings.filterwarnings("ignore", category=torch.jit.TracerWarning)

SIZE = 256


class ImageTower(torch.nn.Module):
    def __init__(self, model: SiglipModel):
        super().__init__()
        self.vision = model.vision_model

    def forward(self, image):
        pooled = self.vision(pixel_values=image).pooler_output
        return pooled / pooled.norm(dim=-1, keepdim=True)


def test_inputs():
    """Eight inputs in the model's -1…1 range: plain gradients, stripes and
    seeded noise."""
    rng = np.random.default_rng(20261126)
    y, x = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32) / (SIZE - 1)
    out = [
        np.stack([x, y, 1 - x]),
        np.stack([y, y * x, x]),
        np.stack([np.sin(x * 20), np.cos(y * 13), np.sin((x + y) * 7)]) * 0.5 + 0.5,
        np.stack([(x > 0.5), (y > 0.5), ((x + y) > 1)]).astype(np.float32),
    ]
    out += [rng.random((3, SIZE, SIZE), dtype=np.float32) for _ in range(2)]
    out += [np.clip(rng.normal(0.5, 0.15, (3, SIZE, SIZE)), 0, 1).astype(np.float32) for _ in range(2)]
    return [(a * 2 - 1).astype(np.float32) for a in out]


def main():
    root = Path(__file__).resolve().parents[2] / "tools" / "siglip"
    out = root / "coreml"
    ref = root / "reference"
    out.mkdir(exist_ok=True)
    ref.mkdir(exist_ok=True)

    print("1. Loading SigLIP 2")
    model = SiglipModel.from_pretrained(str(root / "model"), attn_implementation="eager").eval()
    tower = ImageTower(model).eval()

    print("2. Reference embeddings (PyTorch)")
    inputs = test_inputs()
    with torch.no_grad():
        refs = [tower(torch.from_numpy(a)[None]).numpy()[0] for a in inputs]
    for i, (a, e) in enumerate(zip(inputs, refs)):
        a.tofile(ref / f"input{i}.f32")
        e.astype(np.float32).tofile(ref / f"embedding{i}.f32")

    print("3. Tracing and converting (32-bit)")
    example = torch.from_numpy(inputs[0])[None]
    with torch.no_grad():
        traced = torch.jit.trace(tower, example)
        drift = (traced(example) - tower(example)).abs().max().item()
    print(f"   trace vs model: max difference {drift:.2e}")
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 3, SIZE, SIZE))],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
    )
    package = out / "SigLIP2.mlpackage"
    mlmodel.save(str(package))
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(out)],
                   check=True, stdout=subprocess.DEVNULL)

    meta = {
        "size": SIZE,
        "dim": int(refs[0].shape[0]),
        "count": len(inputs),
        "logit_scale": float(model.logit_scale.exp().item()),
        "logit_bias": float(model.logit_bias.item()),
        "torch": torch.__version__,
        "coremltools": ct.__version__,
    }
    (ref / "reference.json").write_text(json.dumps(meta, indent=2))
    print(f"   saved {package.name} and SigLIP2.mlmodelc; references: {json.dumps(meta)}")


if __name__ == "__main__":
    sys.exit(main())
