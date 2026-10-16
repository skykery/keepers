#!/usr/bin/env python3
"""Build the optional aesthetics model used on macOS 13-14.

macOS 15+ scores aesthetics with Vision's built-in model. Older systems can
use this instead: CLIP ViT-B/32 image embeddings fed to the LAION aesthetic
predictor v1 linear head, packaged as one Core ML model that takes a
224x224 RGB image and returns `score` (roughly 1-10).

One-off developer tool; the app never runs Python. Usage:

    python3 -m venv /tmp/aes && /tmp/aes/bin/pip install torch transformers coremltools
    /tmp/aes/bin/python scripts/convert_aesthetics_model.py --out build/KeepersAesthetics.mlpackage
    xcrun coremlcompiler compile build/KeepersAesthetics.mlpackage \
        ~/Library/Application\\ Support/Keepers/Models/

The app picks the compiled `KeepersAesthetics.mlmodelc` up from that folder
(see `AestheticsModel.installURL`).
"""

import argparse
import hashlib
import urllib.request
from pathlib import Path

import coremltools as ct
import torch
from transformers import CLIPVisionModelWithProjection

CLIP_REPO = "openai/clip-vit-base-patch32"
HEAD_URL = "https://github.com/LAION-AI/aesthetic-predictor/raw/main/sa_0_4_vit_b_32_linear.pth"
CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)


class AestheticsModel(torch.nn.Module):
    def __init__(self, vision, head):
        super().__init__()
        self.vision = vision
        self.head = head
        self.register_buffer("mean", torch.tensor(CLIP_MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(CLIP_STD).view(1, 3, 1, 1))

    def forward(self, image):  # image: 1x3x224x224, 0...1
        pixels = (image - self.mean) / self.std
        embeds = self.vision(pixel_values=pixels).image_embeds
        embeds = embeds / embeds.norm(dim=-1, keepdim=True)
        return self.head(embeds)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()

    vision = CLIPVisionModelWithProjection.from_pretrained(CLIP_REPO, use_safetensors=True).eval()
    head_path = args.out.parent / "sa_0_4_vit_b_32_linear.pth"
    args.out.parent.mkdir(parents=True, exist_ok=True)
    if not head_path.exists():
        urllib.request.urlretrieve(HEAD_URL, head_path)
    print("head sha256:", hashlib.sha256(head_path.read_bytes()).hexdigest())

    head = torch.nn.Linear(512, 1)
    head.load_state_dict(torch.load(head_path, map_location="cpu", weights_only=True))
    model = AestheticsModel(vision, head.eval()).eval()

    example = torch.rand(1, 3, 224, 224)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="score")],
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "Keepers aesthetics: CLIP ViT-B/32 + LAION aesthetic predictor v1"
    mlmodel.save(str(args.out))
    print("saved", args.out)


if __name__ == "__main__":
    main()
