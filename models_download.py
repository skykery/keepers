"""First-launch download of ML model weights.

Called by webapp.py before scoring starts whenever paths.models_ready()
is False. Progress is reported through a callback so the UI can stream
updates without coupling this module to Flask state.

Integrity:
  CLIP weights from HuggingFace are verified by the HF Hub client (LFS SHA).
  LAION + MediaPipe files are verified against the SHA256 constants below.
  If a hash mismatches the partial file is deleted and an error is raised.
"""

import hashlib
import os
import urllib.request
from pathlib import Path
from typing import Callable

import paths

ProgressFn = Callable[[str], None]

LAION_URL = (
    "https://github.com/christophschuhmann/improved-aesthetic-predictor"
    "/raw/main/sac%2Blogos%2Bava1-l14-linearMSE.pth"
)
LAION_SHA256 = "21dd590f3ccdc646f0d53120778b296013b096a035a2718c9cb0d511bff0f1e0"

MEDIAPIPE_URL = (
    "https://storage.googleapis.com/mediapipe-models/face_landmarker"
    "/face_landmarker/float16/1/face_landmarker.task"
)
MEDIAPIPE_SHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"


class ModelIntegrityError(RuntimeError):
    """Raised when a downloaded file doesn't match its pinned SHA256."""


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _download_file(
    url: str, dest: Path, expected_sha256: str, label: str, progress: ProgressFn
) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")

    def hook(block_num: int, block_size: int, total_size: int) -> None:
        if total_size <= 0:
            progress(f"{label}…")
            return
        done = min(block_num * block_size, total_size)
        pct = int(done * 100 / total_size)
        mb_done = done / (1024 * 1024)
        mb_total = total_size / (1024 * 1024)
        progress(f"{label} — {mb_done:.0f} / {mb_total:.0f} MB ({pct}%)")

    urllib.request.urlretrieve(url, tmp, reporthook=hook)

    progress(f"{label} — verifying integrity…")
    actual = _sha256(tmp)
    if actual != expected_sha256:
        tmp.unlink(missing_ok=True)
        raise ModelIntegrityError(
            f"{dest.name}: SHA256 mismatch. "
            f"expected={expected_sha256} actual={actual}. "
            "Refusing to use a tampered or corrupt model file."
        )

    tmp.replace(dest)


def _download_hf_repo(repo_id: str, label: str, progress: ProgressFn) -> None:
    progress(f"{label}…")
    os.environ["HF_HOME"] = str(paths.model_cache_dir())
    os.environ["TRANSFORMERS_CACHE"] = str(paths.model_cache_dir())
    from transformers import CLIPModel, CLIPProcessor

    CLIPModel.from_pretrained(
        repo_id, cache_dir=str(paths.model_cache_dir()), use_safetensors=True
    )
    CLIPProcessor.from_pretrained(repo_id, cache_dir=str(paths.model_cache_dir()))


def download_all(progress: ProgressFn) -> None:
    """Download every missing model. Safe to call when everything is already present."""
    if not paths.laion_predictor_path().exists():
        _download_file(
            LAION_URL,
            paths.laion_predictor_path(),
            LAION_SHA256,
            "Aesthetic predictor (1 of 4, ~4 MB)",
            progress,
        )
    if not paths.mediapipe_face_landmarker_path().exists():
        _download_file(
            MEDIAPIPE_URL,
            paths.mediapipe_face_landmarker_path(),
            MEDIAPIPE_SHA256,
            "Face detector (2 of 4, ~4 MB)",
            progress,
        )
    if not paths._hf_repo_cached(paths.HF_REPO_BASE):
        _download_hf_repo(
            paths.HF_REPO_BASE,
            "CLIP ViT-B/32 (3 of 4, ~150 MB)",
            progress,
        )
    if not paths._hf_repo_cached(paths.HF_REPO_LARGE):
        _download_hf_repo(
            paths.HF_REPO_LARGE,
            "CLIP ViT-L/14 (4 of 4, ~900 MB — this is the big one)",
            progress,
        )
