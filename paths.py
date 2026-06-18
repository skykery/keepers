"""Path resolver for dev vs frozen (PyInstaller) builds.

Templates ship inside the .app bundle when frozen.
Model weights always live in a user-writable directory and are
downloaded on first launch — never bundled inside the .app.
"""

import sys
from pathlib import Path

HF_REPO_BASE = "openai/clip-vit-base-patch32"
HF_REPO_LARGE = "openai/clip-vit-large-patch14"


def is_frozen() -> bool:
    return getattr(sys, "frozen", False)


def resources_root() -> Path:
    if is_frozen():
        return Path(sys.executable).resolve().parent.parent / "Resources"
    return Path(__file__).resolve().parent


def app_data_dir() -> Path:
    if sys.platform == "darwin":
        path = Path.home() / "Library" / "Application Support" / "Keepers"
    else:
        path = Path.home() / ".local" / "share" / "keepers"
    path.mkdir(parents=True, exist_ok=True)
    return path


def model_cache_dir() -> Path:
    path = app_data_dir() / "models" / "huggingface"
    path.mkdir(parents=True, exist_ok=True)
    return path


def laion_predictor_path() -> Path:
    return app_data_dir() / "models" / "laion" / "sac+logos+ava1-l14-linearMSE.pth"


def mediapipe_face_landmarker_path() -> Path:
    return app_data_dir() / "models" / "mediapipe" / "face_landmarker.task"


def templates_dir() -> Path:
    if is_frozen():
        return resources_root() / "templates"
    return Path(__file__).resolve().parent / "templates"


def _hf_repo_cached(repo_id: str) -> bool:
    cache_name = "models--" + repo_id.replace("/", "--")
    return (model_cache_dir() / cache_name).exists()


def models_ready() -> bool:
    """True if every model the scorer needs is already on disk."""
    if not laion_predictor_path().exists():
        return False
    if not mediapipe_face_landmarker_path().exists():
        return False
    if not _hf_repo_cached(HF_REPO_BASE):
        return False
    if not _hf_repo_cached(HF_REPO_LARGE):
        return False
    return True
