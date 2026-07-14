#!/usr/bin/env python3
"""Automatic photo culling using enhanced multi-model scoring."""

import json
from pathlib import Path
from typing import Optional
import rawpy
from PIL import Image

from scoring import EnhancedScorer

RAW_EXTENSIONS = {".orf", ".nef", ".dng", ".cr2", ".cr3", ".arw", ".rw2", ".raf"}
PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff", ".tif", ".gif"}
ALL_PHOTO_EXTENSIONS = RAW_EXTENSIONS | PHOTO_EXTENSIONS


class AutoCuller:
    def __init__(
        self,
        originals_dir: str = "originals",
        output_dir: str = "culled",
    ):
        self.originals_dir = Path(originals_dir)
        self.output_dir = Path(output_dir)
        self.scores_file = self.output_dir / "scores.json"
        self.scorer: Optional[EnhancedScorer] = None
        self.scores: dict = {}

    def setup(self) -> None:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self._load_scores()

    def _load_scorer(self) -> None:
        if self.scorer is None:
            self.scorer = EnhancedScorer()

    def _load_scores(self) -> None:
        if self.scores_file.exists():
            with open(self.scores_file, "r") as f:
                self.scores = json.load(f)
        else:
            self.scores = {}

    def _save_scores(self) -> None:
        with open(self.scores_file, "w") as f:
            json.dump(self.scores, f, indent=2)

    def _raw_to_rgb(self, raw_path: Path) -> Image.Image:
        with rawpy.imread(str(raw_path)) as raw:
            rgb = raw.postprocess(
                use_camera_wb=True,
                half_size=True,
                no_auto_bright=True,
            )
        return Image.fromarray(rgb)

    def _load_image(self, photo_path: Path) -> Optional[Image.Image]:
        try:
            if photo_path.suffix.lower() == ".dng":
                return self._raw_to_rgb(photo_path)
            elif photo_path.suffix.lower() in RAW_EXTENSIONS:
                return self._raw_to_rgb(photo_path)
            else:
                return Image.open(photo_path).convert("RGB")
        except Exception as e:
            print(f"Error loading {photo_path.name}: {e}")
            return None

    def _is_raw(self, photo_path: Path) -> bool:
        return photo_path.suffix.lower() in RAW_EXTENSIONS

    def _compute_score(
        self, image: Image.Image, is_raw: bool = False, scene_override: str = None
    ) -> dict:
        return self.scorer.score(image, is_raw=is_raw, scene_override=scene_override)

    def scan_photos(self) -> list[Path]:
        photos = []
        for f in self.originals_dir.iterdir():
            # `._*` files are macOS AppleDouble metadata forks that appear on
            # non-HFS+ volumes (FAT/exFAT/NTFS externals). They carry `.JPG`
            # extensions but aren't images — PIL fails to open them.
            if f.name.startswith("._"):
                continue
            if f.is_file() and f.suffix.lower() in ALL_PHOTO_EXTENSIONS:
                photos.append(f)
        return sorted(photos)

    def score_photos(self, force: bool = False) -> dict:
        photos = self.scan_photos()

        self._load_scorer()

        for photo in photos:
            photo_name = photo.name

            if not force and photo_name in self.scores:
                continue

            print(f"Scoring: {photo_name}")
            image = self._load_image(photo)
            is_raw = self._is_raw(photo)

            if image is None:
                self.scores[photo_name] = {"score": 0.0, "error": True}
                continue

            result = self._compute_score(image, is_raw)
            self.scores[photo_name] = {
                "score": result["score"],
                "error": False,
                "clip_score": result.get("clip_score", 0),
                "aesthetic_score": result.get("aesthetic_score", 0),
                "technical_score": result.get("technical_score", 0),
                "breakdown": result.get("breakdown", {}),
                "technical_breakdown": result.get("technical_breakdown", {}),
                "embedding": result.get("embedding").tolist()
                if result.get("embedding") is not None
                else None,
            }
            self._save_scores()

        return self.scores

    def get_stats(self) -> dict:
        total = len(self.scan_photos())
        scored = len([s for s in self.scores.values() if not s.get("error", False)])
        errors = len([s for s in self.scores.values() if s.get("error", False)])

        scores_list = [
            s["score"] for s in self.scores.values() if not s.get("error", False)
        ]

        avg_score = sum(scores_list) / len(scores_list) if scores_list else 0
        max_score = max(scores_list) if scores_list else 0
        min_score = min(scores_list) if scores_list else 0

        return {
            "total": total,
            "scored": scored,
            "errors": errors,
            "avg_score": round(avg_score, 4),
            "max_score": round(max_score, 4),
            "min_score": round(min_score, 4),
        }
