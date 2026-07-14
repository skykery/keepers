#!/usr/bin/env python3
"""Web interface for photo culling tool - Interactive Image Culling Workspace."""

import os
import io
import base64
import json
import subprocess
import sys
import threading
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from flask import (
    Flask,
    render_template,
    request,
    jsonify,
    send_from_directory,
    send_file,
)
from PIL import Image
import rawpy

from typing import Optional
import paths
from auto_cull import AutoCuller, RAW_EXTENSIONS, PHOTO_EXTENSIONS, ALL_PHOTO_EXTENSIONS
from folder_manager import FolderManager, FolderType

app = Flask(__name__, template_folder=str(paths.templates_dir()))
app.config["MAX_CONTENT_LENGTH"] = 16 * 1024 * 1024

culler: Optional[AutoCuller] = None
folder_manager: Optional[FolderManager] = None
processing_status = {
    "running": False,
    "stage": "",
    "progress": 0,
    "total": 0,
    "message": "",
    "error": None,
}

THUMBNAIL_SIZE = 300
THUMBNAIL_DIR: Optional[Path] = None
progress_lock = threading.Lock()
scores_lock = threading.Lock()


def _safe_filename(filename: str) -> bool:
    """Reject anything that isn't a plain basename. Blocks path traversal
    (`../etc/passwd`), absolute paths, null bytes, and Windows separators."""
    if not filename or filename in (".", ".."):
        return False
    if "/" in filename or "\\" in filename or "\x00" in filename:
        return False
    return filename == Path(filename).name


def serialize_face(face: dict) -> dict:
    result = {
        "bbox": face.get("bbox"),
        "eye_contact_score": face.get("eye_contact_score", 0.5),
        "blink_score": face.get("blink_score", 0),
        "center_proximity": face.get("center_proximity", 0.5),
        "relative_size": face.get("relative_size", 0),
        "sharpness": face.get("sharpness", 0.5),
        "emotion_score": face.get("emotion_score", 0.5),
    }
    return result


def get_directories(path: str) -> list[str]:
    try:
        p = Path(path)
        if not p.exists():
            return []
        dirs = [
            str(d) for d in p.iterdir() if d.is_dir() and not d.name.startswith(".")
        ]
        return sorted(dirs)
    except Exception:
        return []


def get_parent_directory(path: str) -> str:
    try:
        return str(Path(path).parent)
    except Exception:
        return str(Path.home())


def get_thumbnail_cache_dir(output_dir: Path) -> Path:
    cache_dir = output_dir / ".thumbnails"
    cache_dir.mkdir(parents=True, exist_ok=True)
    return cache_dir


def get_cached_thumbnail_path(photo_name: str) -> Optional[Path]:
    global THUMBNAIL_DIR
    if THUMBNAIL_DIR is None:
        return None
    return THUMBNAIL_DIR / f"{photo_name}.jpg"


def raw_to_thumbnail(
    raw_path: Path, cache_path: Optional[Path] = None, size: int = THUMBNAIL_SIZE
) -> bool:
    try:
        with rawpy.imread(str(raw_path)) as raw:
            rgb = raw.postprocess(
                use_camera_wb=True,
                half_size=True,
                no_auto_bright=True,
            )
        img = Image.fromarray(rgb)
        img.thumbnail((size, size), Image.Resampling.LANCZOS)
        if cache_path:
            img.save(cache_path, format="JPEG", quality=85)
        return True
    except Exception:
        return False


def image_to_thumbnail(
    image_path: Path, cache_path: Optional[Path] = None, size: int = THUMBNAIL_SIZE
) -> bool:
    try:
        img = Image.open(image_path)
        img.thumbnail((size, size), Image.Resampling.LANCZOS)
        if cache_path:
            img.save(cache_path, format="JPEG", quality=85)
        return True
    except Exception:
        return False


def generate_thumbnail(photo_path: Path, cache_path: Optional[Path] = None) -> bool:
    if photo_path.suffix.lower() in RAW_EXTENSIONS:
        return raw_to_thumbnail(photo_path, cache_path)
    else:
        return image_to_thumbnail(photo_path, cache_path)


def run_culling(
    input_dir: str,
    output_dir: str,
    threshold: float,
    force_rescore: bool = False,
):
    global culler, folder_manager, processing_status, THUMBNAIL_DIR

    try:
        processing_status["running"] = True
        processing_status["error"] = None
        processing_status["stage"] = "Preparing session"
        processing_status["message"] = "Reading existing scores..."

        culler = AutoCuller(originals_dir=input_dir, output_dir=output_dir)
        culler.setup()

        THUMBNAIL_DIR = get_thumbnail_cache_dir(culler.output_dir)

        folder_manager = FolderManager(culler.output_dir)

        photos = culler.scan_photos()
        total_photos = len(photos)
        processing_status["total"] = total_photos * 2
        processing_status["progress"] = 0

        if force_rescore:
            photos_to_score = photos
        else:
            photos_to_score = [p for p in photos if p.name not in culler.scores]
        already_scored = len(photos) - len(photos_to_score)

        if photos_to_score:
            import paths
            if not paths.models_ready():
                import models_download
                processing_status["stage"] = "Downloading AI models"
                processing_status["message"] = (
                    "First-time setup: downloading ~1 GB of AI models. "
                    "This only happens once."
                )

                def _on_progress(msg: str) -> None:
                    processing_status["message"] = msg

                models_download.download_all(_on_progress)

            processing_status["stage"] = "Scoring photos"
            processing_status["message"] = (
                f"Loading AI models... ({already_scored} cached, {len(photos_to_score)} new to score)"
            )
            culler._load_scorer()
        else:
            processing_status["stage"] = "Resuming session"
            processing_status["message"] = (
                f"All {total_photos} photos already scored — restoring your workspace..."
            )
            processing_status["progress"] = total_photos

        def score_single_photo(photo):
            try:
                image = culler._load_image(photo)
                is_raw = culler._is_raw(photo)
                if image:
                    result = culler._compute_score(image, is_raw)
                    faces = result.get("faces", [])
                    serialized_faces = [serialize_face(f) for f in faces]
                    return {
                        "name": photo.name,
                        "score": result["score"],
                        "error": False,
                        "clip_score": result.get("clip_score", 0),
                        "aesthetic_score": result.get("aesthetic_score", 0),
                        "technical_score": result.get("technical_score", 0),
                        "breakdown": result.get("breakdown", {}),
                        "technical_breakdown": result.get("technical_breakdown", {}),
                        "has_face": result.get("has_face", False),
                        "face_sharpness": result.get("face_sharpness", 0),
                        "faces": serialized_faces,
                        "group_analysis": result.get("group_analysis", {}),
                        "detected_scene": result.get("detected_scene", "unknown"),
                        "scoring_profile": result.get("scoring_profile", "Auto"),
                    }
                else:
                    return {"name": photo.name, "score": 0.0, "error": True}
            except Exception:
                return {"name": photo.name, "score": 0.0, "error": True}

        completed = already_scored
        with progress_lock:
            processing_status["progress"] = completed

        max_workers = min(4, os.cpu_count() or 1)

        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            futures = {
                executor.submit(score_single_photo, p): p for p in photos_to_score
            }

            for future in as_completed(futures):
                result = future.result()
                with scores_lock:
                    culler.scores[result["name"]] = result
                    culler._save_scores()

                with progress_lock:
                    completed += 1
                    processing_status["progress"] = completed
                    processing_status["message"] = (
                        f"Scored {completed}/{total_photos} photos"
                    )

        photos_needing_thumbs = [
            p for p in photos if not (THUMBNAIL_DIR / f"{p.name}.jpg").exists()
        ]

        if not photos_needing_thumbs:
            processing_status["stage"] = "Resuming session"
            processing_status["message"] = (
                f"All {total_photos} thumbnails ready — finalising..."
            )
            with progress_lock:
                processing_status["progress"] = total_photos * 2
        else:
            processing_status["stage"] = "Generating thumbnails"
            processing_status["message"] = (
                f"Creating {len(photos_needing_thumbs)} new thumbnails..."
            )

            def generate_single_thumbnail(photo):
                cache_path = THUMBNAIL_DIR / f"{photo.name}.jpg"
                if not cache_path.exists():
                    generate_thumbnail(photo, cache_path)
                return photo.name

            thumb_completed = total_photos - len(photos_needing_thumbs)
            with progress_lock:
                processing_status["progress"] = total_photos + thumb_completed
            with ThreadPoolExecutor(max_workers=max_workers * 2) as executor:
                futures = {
                    executor.submit(generate_single_thumbnail, p): p
                    for p in photos_needing_thumbs
                }

                for future in as_completed(futures):
                    with progress_lock:
                        thumb_completed += 1
                        processing_status["progress"] = total_photos + thumb_completed
                        processing_status["message"] = (
                            f"Thumbnails: {thumb_completed}/{total_photos}"
                        )

        processing_status["stage"] = "Organizing photos"
        processing_status["message"] = "Creating symlinks based on AI scores..."

        if force_rescore:
            folder_manager.clear_all_symlinks()
            folder_manager._organization = {}
            folder_manager._save_organization()

            for photo in photos:
                score_data = culler.scores.get(photo.name, {})
                if not score_data.get("error"):
                    folder_manager.classify_photo(
                        photo_name=photo.name,
                        source_path=photo,
                        score=score_data.get("score", 0),
                        breakdown=score_data.get("breakdown", {}),
                    )
        else:
            folder_manager.clear_all_symlinks()
            restored = folder_manager.restore_organization(photos)

            for photo in photos:
                if folder_manager.get_manual_override(photo.name):
                    continue
                score_data = culler.scores.get(photo.name, {})
                if not score_data.get("error"):
                    folder_manager.classify_photo(
                        photo_name=photo.name,
                        source_path=photo,
                        score=score_data.get("score", 0),
                        breakdown=score_data.get("breakdown", {}),
                    )

            if restored > 0:
                processing_status["message"] = (
                    f"Restored {restored} manual placements..."
                )

        processing_status["stage"] = "Complete"
        stats = folder_manager.get_stats()
        processing_status["message"] = (
            f"Done! Picks: {stats.get('Picks', 0)}, "
            f"Moments: {stats.get('Emotional_Highlights', 0)}, "
            f"Review: {stats.get('Review_Queue', 0)}, "
            f"Rejected: {stats.get('Rejected', 0)}"
        )

    except Exception as e:
        processing_status["error"] = str(e)
        processing_status["message"] = f"Error: {e}"
    finally:
        processing_status["running"] = False


@app.route("/")
def index():
    home = str(Path.home())
    return render_template("index.html", home=home)


@app.route("/api/reveal/<folder>", methods=["POST"])
def reveal_folder(folder: str):
    if folder_manager is None:
        return jsonify({"success": False, "error": "no active session"}), 400

    folder_map = {
        "picks": FolderType.PICKS,
        "moments": FolderType.MOMENTS,
        "review": FolderType.REVIEW,
        "trash": FolderType.TRASH,
    }
    ftype = folder_map.get(folder)
    if ftype is None:
        return jsonify({"success": False, "error": "unknown folder"}), 400

    target = folder_manager.get_folder(ftype)
    if target is None or not Path(target).exists():
        return jsonify({"success": False, "error": "folder missing"}), 404

    try:
        if sys.platform == "darwin":
            subprocess.run(["open", str(target)], check=False)
        elif sys.platform.startswith("win"):
            os.startfile(str(target))
        else:
            subprocess.run(["xdg-open", str(target)], check=False)
        return jsonify({"success": True, "path": str(target)})
    except Exception as e:
        return jsonify({"success": False, "error": str(e)}), 500


@app.route("/api/browse", methods=["POST"])
def browse():
    data = request.get_json()
    path = data.get("path", str(Path.home()))

    if not Path(path).exists():
        path = str(Path.home())

    parent = get_parent_directory(path)
    directories = get_directories(path)

    return jsonify({"current": path, "parent": parent, "directories": directories})


@app.route("/api/preview", methods=["POST"])
def preview_directory():
    data = request.get_json()
    input_dir = data.get("input_dir")

    if not input_dir or not Path(input_dir).exists():
        return jsonify({"error": "Invalid directory", "photo_count": 0}), 400

    input_path = Path(input_dir)

    raw_count = 0
    jpg_count = 0
    other_count = 0

    for f in input_path.iterdir():
        # Skip macOS AppleDouble metadata files (see auto_cull.py scan_photos).
        if f.name.startswith("._"):
            continue
        if f.is_file():
            ext = f.suffix.lower()
            if ext in RAW_EXTENSIONS:
                raw_count += 1
            elif ext in PHOTO_EXTENSIONS:
                if ext in {".jpg", ".jpeg"}:
                    jpg_count += 1
                else:
                    other_count += 1

    total = raw_count + jpg_count + other_count

    estimated_seconds = total * 2
    if raw_count > 0:
        estimated_seconds += raw_count * 1

    if estimated_seconds < 60:
        estimated_time = f"~{estimated_seconds} seconds"
    elif estimated_seconds < 3600:
        minutes = estimated_seconds // 60
        estimated_time = f"~{minutes} min"
    else:
        hours = estimated_seconds // 3600
        mins = (estimated_seconds % 3600) // 60
        estimated_time = f"~{hours}h {mins}m"

    scores_file = input_path / "scores.json"
    has_previous_session = scores_file.exists()
    previous_count = 0
    if has_previous_session:
        try:
            with open(scores_file) as f:
                previous_scores = json.load(f)
                previous_count = len(
                    [s for s in previous_scores.values() if not s.get("error")]
                )
        except Exception:
            pass

    return jsonify(
        {
            "photo_count": total,
            "raw_count": raw_count,
            "jpg_count": jpg_count,
            "other_count": other_count,
            "estimated_time": estimated_time,
            "has_previous_session": has_previous_session,
            "previous_scored_count": previous_count,
            "supported_formats": list(RAW_EXTENSIONS | PHOTO_EXTENSIONS),
        }
    )


@app.route("/api/start", methods=["POST"])
def start_culling():
    global processing_status

    if processing_status["running"]:
        return jsonify({"error": "Processing already running"}), 400

    data = request.get_json()
    input_dir = data.get("input_dir")
    output_dir = data.get("output_dir", input_dir)
    threshold = float(data.get("threshold", 0.7))
    force_rescore = data.get("force_rescore", False)

    if not input_dir or not Path(input_dir).exists():
        return jsonify({"error": "Invalid input directory"}), 400

    thread = threading.Thread(
        target=run_culling,
        args=(input_dir, output_dir, threshold, force_rescore),
    )
    thread.start()

    return jsonify({"status": "started"})


@app.route("/api/status")
def status():
    return jsonify(processing_status)


@app.route("/api/photos")
def get_all_photos():
    global culler, folder_manager

    if culler is None or folder_manager is None:
        return jsonify({"error": "No culling session active"}), 400

    photos = []
    for photo_name, score_data in culler.scores.items():
        if score_data.get("error"):
            continue

        location = folder_manager.get_photo_location(photo_name)

        photos.append(
            {
                "name": photo_name,
                "score": score_data.get("score", 0),
                "clip_score": score_data.get("clip_score", 0),
                "aesthetic_score": score_data.get("aesthetic_score", 0),
                "technical_score": score_data.get("technical_score", 0),
                "breakdown": score_data.get("breakdown", {}),
                "technical_breakdown": score_data.get("technical_breakdown", {}),
                "has_face": score_data.get("has_face", False),
                "face_sharpness": score_data.get("face_sharpness", 0),
                "faces": score_data.get("faces", []),
                "group_analysis": score_data.get("group_analysis", {}),
                "location": location.value if location else None,
                "emotion_rescue_applied": score_data.get("breakdown", {}).get(
                    "emotion_rescue_applied", False
                ),
                "detected_scene": score_data.get("detected_scene", "unknown"),
                "scoring_profile": score_data.get("scoring_profile", "Auto"),
            }
        )

    return jsonify({"photos": photos})


@app.route("/api/photos/<folder>")
def get_photos_by_folder(folder):
    global culler, folder_manager

    if culler is None or folder_manager is None:
        return jsonify({"error": "No culling session active"}), 400

    folder_map = {
        "picks": FolderType.PICKS,
        "moments": FolderType.MOMENTS,
        "review": FolderType.REVIEW,
        "trash": FolderType.TRASH,
    }

    if folder not in folder_map:
        return jsonify({"error": "Invalid folder"}), 400

    folder_type = folder_map[folder]
    photo_names = folder_manager.get_photos_in_folder(folder_type)

    photos = []
    for photo_name in photo_names:
        score_data = culler.scores.get(photo_name, {})
        if score_data.get("error"):
            continue

        photos.append(
            {
                "name": photo_name,
                "score": score_data.get("score", 0),
                "clip_score": score_data.get("clip_score", 0),
                "aesthetic_score": score_data.get("aesthetic_score", 0),
                "technical_score": score_data.get("technical_score", 0),
                "breakdown": score_data.get("breakdown", {}),
                "technical_breakdown": score_data.get("technical_breakdown", {}),
                "has_face": score_data.get("has_face", False),
                "face_sharpness": score_data.get("face_sharpness", 0),
                "faces": score_data.get("faces", []),
                "group_analysis": score_data.get("group_analysis", {}),
                "location": folder,
                "emotion_rescue_applied": score_data.get("breakdown", {}).get(
                    "emotion_rescue_applied", False
                ),
                "detected_scene": score_data.get("detected_scene", "unknown"),
                "scoring_profile": score_data.get("scoring_profile", "Auto"),
            }
        )

    return jsonify({"photos": photos})


@app.route("/api/move", methods=["POST"])
def move_photo():
    global culler, folder_manager

    if culler is None or folder_manager is None:
        return jsonify({"error": "No culling session active"}), 400

    data = request.get_json()
    photo_name = data.get("photo_name")
    target_folder = data.get("target_folder")

    if not photo_name or not target_folder:
        return jsonify({"error": "Missing photo_name or target_folder"}), 400

    folder_map = {
        "picks": FolderType.PICKS,
        "moments": FolderType.MOMENTS,
        "review": FolderType.REVIEW,
        "trash": FolderType.TRASH,
    }

    if target_folder not in folder_map:
        return jsonify({"error": "Invalid target folder"}), 400

    if not _safe_filename(photo_name):
        return jsonify({"error": "Invalid photo name"}), 400

    source_path = culler.originals_dir / photo_name
    if not source_path.exists():
        return jsonify({"error": "Source photo not found"}), 404

    target_type = folder_map[target_folder]
    success = folder_manager.move_photo(photo_name, source_path, target_type)

    if success:
        return jsonify({"status": "success", "location": target_folder})
    else:
        return jsonify({"error": "Failed to move photo"}), 500


@app.route("/api/rescore/<filename>", methods=["POST"])
def rescore_photo(filename):
    global culler, THUMBNAIL_DIR

    if culler is None:
        return jsonify({"error": "No culling session active"}), 400

    if not _safe_filename(filename):
        return jsonify({"error": "Invalid filename"}), 400

    data = request.get_json() or {}
    scene_override = data.get("scene_override", None)

    source_path = culler.originals_dir / filename
    if not source_path.exists():
        return jsonify({"error": "Photo not found"}), 404

    try:
        image = culler._load_image(source_path)
        is_raw = culler._is_raw(source_path)
        if image:
            result = culler._compute_score(image, is_raw, scene_override=scene_override)
            faces = result.get("faces", [])
            serialized_faces = [serialize_face(f) for f in faces]

            score_data = {
                "name": filename,
                "score": result["score"],
                "error": False,
                "clip_score": result.get("clip_score", 0),
                "aesthetic_score": result.get("aesthetic_score", 0),
                "technical_score": result.get("technical_score", 0),
                "breakdown": result.get("breakdown", {}),
                "technical_breakdown": result.get("technical_breakdown", {}),
                "has_face": result.get("has_face", False),
                "face_sharpness": result.get("face_sharpness", 0),
                "faces": serialized_faces,
                "group_analysis": result.get("group_analysis", {}),
                "detected_scene": result.get("detected_scene", "unknown"),
                "scoring_profile": result.get("scoring_profile", "Auto"),
            }

            culler.scores[filename] = score_data
            culler._save_scores()

            return jsonify(score_data)
        else:
            return jsonify({"error": "Could not load image"}), 500
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/thumbnail/<filename>")
def get_thumbnail_file(filename):
    global culler, THUMBNAIL_DIR

    if culler is None or THUMBNAIL_DIR is None:
        return jsonify({"error": "No culling session active"}), 400

    if not _safe_filename(filename):
        return jsonify({"error": "Invalid filename"}), 400

    cache_path = THUMBNAIL_DIR / f"{filename}.jpg"

    if not cache_path.exists():
        photo_path = culler.originals_dir / filename
        if not photo_path.exists():
            return jsonify({"error": "Photo not found"}), 404
        generate_thumbnail(photo_path, cache_path)

    return send_file(cache_path, mimetype="image/jpeg")


@app.route("/api/facecrop/<filename>")
def get_face_crop(filename):
    global culler, THUMBNAIL_DIR

    if culler is None:
        return jsonify({"error": "No culling session active"}), 400

    if not _safe_filename(filename):
        return jsonify({"error": "Invalid filename"}), 400

    score_data = culler.scores.get(filename, {})
    if not score_data:
        return jsonify({"error": "Photo not scored"}), 404

    cache_path = THUMBNAIL_DIR / f"{filename}.jpg"
    if not cache_path.exists():
        photo_path = culler.originals_dir / filename
        if photo_path.exists():
            generate_thumbnail(photo_path, cache_path)

    return jsonify(
        {
            "has_face": score_data.get("has_face", False),
            "face_sharpness": score_data.get("face_sharpness", 0),
        }
    )


@app.route("/api/facecrop/<filename>/<int:face_index>")
def get_face_crop_by_index(filename, face_index):
    global culler, THUMBNAIL_DIR

    if culler is None:
        return jsonify({"error": "No culling session active"}), 400

    if not _safe_filename(filename):
        return jsonify({"error": "Invalid filename"}), 400

    score_data = culler.scores.get(filename, {})
    if not score_data:
        return jsonify({"error": "Photo not scored"}), 404

    faces = score_data.get("faces", [])
    if face_index >= len(faces):
        return jsonify({"error": "Face index out of range"}), 404

    face = faces[face_index]
    bbox = face.get("bbox")
    if not bbox:
        return jsonify({"error": "No bbox for face"}), 404

    cache_path = THUMBNAIL_DIR / f"{filename}.jpg"
    if not cache_path.exists():
        photo_path = culler.originals_dir / filename
        if photo_path.exists():
            generate_thumbnail(photo_path, cache_path)

    if not cache_path.exists():
        return jsonify({"error": "Could not generate thumbnail"}), 500

    try:
        img = Image.open(cache_path)
        thumb_w, thumb_h = img.size

        photo_path = culler.originals_dir / filename
        orig_w, orig_h = img.size

        if photo_path.suffix.lower() in RAW_EXTENSIONS:
            with rawpy.imread(str(photo_path)) as raw:
                rgb = raw.postprocess(use_camera_wb=True, half_size=True)
                orig_img = Image.fromarray(rgb)
                orig_w, orig_h = orig_img.size
        else:
            try:
                orig_img = Image.open(photo_path)
                orig_w, orig_h = orig_img.size
            except Exception:
                orig_w, orig_h = thumb_w, thumb_h

        x_min, y_min, x_max, y_max = bbox

        scale_x = thumb_w / orig_w if orig_w > 0 else 1
        scale_y = thumb_h / orig_h if orig_h > 0 else 1

        scaled_bbox = (
            int(x_min * scale_x),
            int(y_min * scale_y),
            int(x_max * scale_x),
            int(y_max * scale_y),
        )

        padding = 10
        face_crop = img.crop(
            (
                max(0, scaled_bbox[0] - padding),
                max(0, scaled_bbox[1] - padding),
                min(thumb_w, scaled_bbox[2] + padding),
                min(thumb_h, scaled_bbox[3] + padding),
            )
        )

        face_crop.thumbnail((80, 80), Image.Resampling.LANCZOS)

        buffer = io.BytesIO()
        face_crop.save(buffer, format="JPEG", quality=85)
        buffer.seek(0)

        return send_file(buffer, mimetype="image/jpeg")
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/photo/<filename>")
def get_photo(filename):
    global culler, folder_manager

    if culler is None or folder_manager is None:
        return jsonify({"error": "No culling session active"}), 400

    if not _safe_filename(filename):
        return jsonify({"error": "Invalid filename"}), 400

    photo_path = culler.originals_dir / filename
    if not photo_path.exists():
        return jsonify({"error": "Photo not found"}), 404

    score_data = culler.scores.get(filename, {})
    location = folder_manager.get_photo_location(filename)

    return jsonify(
        {
            "name": filename,
            "score": score_data.get("score", 0),
            "location": location.value if location else None,
        }
    )


@app.route("/api/stats")
def stats():
    global culler, folder_manager

    if culler is None or folder_manager is None:
        return jsonify({"error": "No culling session active"}), 400

    base_stats = culler.get_stats()
    folder_stats = folder_manager.get_stats()

    return jsonify({**base_stats, **folder_stats})


@app.route("/api/reasoning/<filename>")
def get_reasoning(filename):
    global culler

    if culler is None:
        return jsonify({"error": "No culling session active"}), 400

    if not _safe_filename(filename):
        return jsonify({"error": "Invalid filename"}), 400

    score_data = culler.scores.get(filename, {})
    if not score_data:
        return jsonify({"error": "Photo not found"}), 404

    breakdown = score_data.get("breakdown", {})
    tech_breakdown = score_data.get("technical_breakdown", {})
    score = score_data.get("score", 0)
    has_face = score_data.get("has_face", False)
    group_analysis = score_data.get("group_analysis", {})
    faces = score_data.get("faces", [])

    reasons = []

    detected_scene = score_data.get("detected_scene", "unknown")
    scoring_profile = score_data.get("scoring_profile", "Auto")

    reasons.append(f"Scene detected: {detected_scene.title()}")
    reasons.append(f"Scoring profile: {scoring_profile}")

    if detected_scene == "portrait":
        if breakdown.get("blink_veto_applied"):
            reasons.append(
                "Portrait mode: Blink veto applied (subject has eyes closed)"
            )
        if breakdown.get("portrait_blink_warning"):
            reasons.append("Portrait mode: Blink detected - quality warning")
    elif detected_scene == "action":
        if breakdown.get("action_blur_tolerance"):
            reasons.append("Action mode: Motion blur tolerance enabled (60% reduction)")
        if breakdown.get("motion_blur_rescue"):
            reasons.append("Action mode: Motion blur rescue applied")
    elif detected_scene == "landscape":
        reasons.append("Landscape mode: Dynamic range and composition priority")
    elif detected_scene == "macro":
        reasons.append("Macro mode: Full-frame sharpness analysis enabled")

    emotion_rescue = breakdown.get("emotion_rescue_applied", False)
    if emotion_rescue:
        emotion_score = breakdown.get("emotion_score", 0)
        reasons.append(
            f"Rescued by high emotional value ({emotion_score:.0%}) despite technical issues"
        )

    sharpness_penalty = breakdown.get("sharpness_penalty_applied", 0)
    if sharpness_penalty and sharpness_penalty < 1:
        if not emotion_rescue:
            reasons.append(
                f"Penalized for soft focus (sharpness penalty: {sharpness_penalty:.0%})"
            )

    exposure_cap = breakdown.get("exposure_cap_applied", 0)
    if exposure_cap and exposure_cap < 1:
        reasons.append(f"Score capped due to exposure issues (cap: {exposure_cap:.0%})")

    emotion_bonus = breakdown.get("emotion_bonus", 0)
    if emotion_bonus > 0:
        reasons.append(f"Emotion bonus applied: +{emotion_bonus:.0%}")

    eye_contact_bonus = breakdown.get("eye_contact_bonus", 0)
    if eye_contact_bonus > 0:
        reasons.append(f"Eye contact bonus: +{eye_contact_bonus:.0%}")

    face_count = group_analysis.get("face_count", 0)
    if face_count > 1:
        reasons.append(f"Group photo with {face_count} faces detected")

        group_boost_factor = breakdown.get("group_boost_factor", 1.0)
        if group_boost_factor > 1.0:
            boost_percent = round((group_boost_factor - 1.0) * 100, 1)
            reasons.append(f"Group boost factor: +{boost_percent}% (social context)")

        if breakdown.get("social_multiplier"):
            reasons.append(
                f"Social multiplier applied: {breakdown['social_multiplier']}x (everyone smiling)"
            )

        if breakdown.get("quality_anchor_boost"):
            reasons.append(
                f"Quality anchor boost: +{breakdown['quality_anchor_boost']:.0%} (primary subject smiling)"
            )

        if group_analysis.get("everyone_smiling", False):
            reasons.append("Social bonus: +20% (everyone smiling)")

        if breakdown.get("sharpness_threshold_relaxed"):
            reasons.append("Sharpness threshold relaxed by 30% for group emotion")

        if breakdown.get("group_emotion_rescue"):
            reasons.append("Group emotion rescue: sharpness penalty reduced")

        if breakdown.get("technical_penalty_reduced"):
            reasons.append("Technical penalties reduced for group emotion priority")

        if breakdown.get("exposure_veto_relaxed"):
            reasons.append("Exposure veto relaxed for group emotion")

        group_blink_risk = group_analysis.get("group_blink_risk", 0)
        if group_blink_risk > 0.7:
            blink_penalty = breakdown.get("blink_penalty", 1.0)
            reasons.append(
                f"Blink penalty applied: {blink_penalty:.0%} (someone blinking)"
            )

        if not group_analysis.get("primary_subjects_sharp", True):
            reasons.append("Primary subjects are not in sharp focus")

        focus_consistency = group_analysis.get("focus_consistency", 1.0)
        if focus_consistency < 0.8:
            reasons.append(f"Inconsistent focus across faces ({focus_consistency:.0%})")
    elif has_face:
        face_sharpness = score_data.get("face_sharpness", 0)
        reasons.append(f"Face detected with sharpness: {face_sharpness:.0%}")

    bokeh_score = breakdown.get("bokeh_score", 0)
    if bokeh_score > 0.5:
        reasons.append(f"Bokeh detected (score: {bokeh_score:.0%}) - subject isolation")
        if breakdown.get("bokeh_threshold_relaxed"):
            reasons.append("Sharpness threshold relaxed for bokeh isolation")

    mean_ratio = breakdown.get("mean_ratio", 0)
    if mean_ratio > 5.0:
        reasons.append(
            f"Shallow depth of field detected (mean ratio: {mean_ratio:.1f}x)"
        )
        if has_face:
            reasons.append("Portrait-style subject isolation working well")
    elif mean_ratio > 3.0 and has_face:
        reasons.append("Moderate depth of field - good subject separation")

    variance_ratio = breakdown.get("variance_ratio", 0)
    if variance_ratio > 2.0 and has_face:
        reasons.append("Strong subject-background separation (shallow DOF)")

    high_quality = breakdown.get("high_quality_total", 0)
    low_quality = breakdown.get("low_quality_total", 0)

    if high_quality > low_quality:
        reasons.append(
            f"Strong quality indicators ({high_quality:.0%} vs {low_quality:.0%} issues)"
        )
    elif low_quality > high_quality:
        reasons.append(f"Some quality issues detected ({low_quality:.0%})")

    if score > 0.7:
        reasons.insert(0, "Excellent photo - ranked in top tier")
    elif score >= 0.4:
        reasons.insert(0, "Good photo - recommend manual review")
    else:
        reasons.insert(0, "Technical issues detected - consider rejecting")

    if not reasons:
        reasons.append("Standard scoring applied")

    return jsonify({"reasons": reasons})


if __name__ == "__main__":
    debug = os.environ.get("KEEPERS_DEBUG") == "1"
    app.run(debug=debug, host="127.0.0.1", port=5000)
