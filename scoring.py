#!/usr/bin/env python3
"""Enhanced scoring with CLIP, LAION Aesthetics, and technical quality metrics."""

import os
import numpy as np
from PIL import Image
import torch
import paths
from transformers import CLIPModel, CLIPProcessor

try:
    import mediapipe as mp
    import cv2

    MEDIAPIPE_AVAILABLE = True
except ImportError:
    MEDIAPIPE_AVAILABLE = False

FACE_LANDMARKER_MODEL_URL = "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task"

from scipy import ndimage

MODEL_CACHE_DIR = str(paths.model_cache_dir())

os.environ["HF_HOME"] = MODEL_CACHE_DIR
os.environ["TRANSFORMERS_CACHE"] = MODEL_CACHE_DIR
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def _autodetect_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("cpu")


def _move_inputs(inputs, device: torch.device):
    return {
        k: (v.to(device) if torch.is_tensor(v) else v) for k, v in inputs.items()
    }

CONTRASTIVE_PAIRS = {
    "focus": {
        "positive": [
            "a tack sharp image with beautiful bokeh",
            "sharp focus on the subject's eyes",
        ],
        "negative": ["an out of focus blurry photo"],
    },
    "exposure": {
        "positive": ["a perfectly exposed photograph"],
        "negative": [
            "a severely overexposed white washed photo",
            "a severely underexposed dark photo",
        ],
    },
    "composition": {
        "positive": ["a stunning composition following rule of thirds"],
        "negative": ["a poorly composed snapshot with bad framing"],
    },
    "lighting": {
        "positive": ["a photograph with perfect lighting"],
        "negative": ["a dark muddy unclear photograph"],
    },
    "color": {
        "positive": ["a photo with vibrant colors and excellent contrast"],
        "negative": ["a washed out faded photo with poor colors"],
    },
    "quality": {
        "positive": ["a masterpiece photograph with exceptional detail"],
        "negative": ["a grainy noisy low quality image"],
    },
    "emotion": {
        "positive": ["a happy smiling person", "a joyful laughing face"],
        "negative": ["a sad unhappy expression", "a neutral bored face"],
    },
}

ALL_POSITIVE_PROMPTS = []
ALL_NEGATIVE_PROMPTS = []
for pair in CONTRASTIVE_PAIRS.values():
    ALL_POSITIVE_PROMPTS.extend(pair["positive"])
    ALL_NEGATIVE_PROMPTS.extend(pair["negative"])

QUALITY_PROMPTS = ALL_POSITIVE_PROMPTS
LOW_QUALITY_PROMPTS = ALL_NEGATIVE_PROMPTS

SHARPNESS_THRESHOLD = 0.25
EXPOSURE_CLIP_THRESHOLD = 0.4
EXPOSURE_SCORE_CAP = 0.3

WEIGHTS = {
    "clip": 0.45,
    "aesthetic": 0.25,
    "technical": 0.30,
}

SCENE_TYPES = {
    "portrait": "portrait",
    "group": "group",
    "macro": "macro",
    "landscape": "landscape",
    "action": "action",
    "unknown": "unknown",
}

SCENE_PROMPTS = {
    "portrait": [
        "a portrait photo of a single person",
        "a close-up headshot of a person",
        "a medium shot portrait of someone",
        "a professional portrait photograph",
    ],
    "group": [
        "a group photo with multiple people",
        "a family portrait with several people",
        "a crowd of people at an event",
        "people gathered together for a photo",
    ],
    "macro": [
        "a macro photograph of a small object",
        "a close-up detail shot of a ring or flower",
        "an extreme close-up of texture or pattern",
        "a detailed photograph of a small subject",
    ],
    "landscape": [
        "a landscape photograph of scenery",
        "an architectural photo of a building",
        "a wide shot of nature or cityscape",
        "a scenic view without people",
    ],
    "action": [
        "an action sports photograph with motion",
        "a dynamic photo of athletes in motion",
        "a sports shot capturing movement",
        "an action photo with motion blur",
    ],
}

SCORING_PROFILES = {
    "portrait": {
        "weights": {
            "face_sharpness": 0.50,
            "emotion": 0.20,
            "composition": 0.20,
            "color": 0.10,
        },
        "veto_mode": "strict_blink",
        "enable_face_detection": True,
        "enable_emotion": True,
        "sharpness_metric": "face",
        "description": "Portrait - Face sharpness priority with emotion bonus",
    },
    "group": {
        "weights": {
            "group_joy": 0.40,
            "focus_consistency": 0.30,
            "exposure": 0.20,
            "composition": 0.10,
        },
        "veto_mode": "relaxed_sharpness_on_joy",
        "enable_face_detection": True,
        "enable_emotion": True,
        "sharpness_metric": "depth_weighted",
        "description": "Group - Joy and consistency priority",
    },
    "macro": {
        "weights": {
            "global_sharpness": 0.60,
            "lighting_texture": 0.30,
            "color": 0.10,
        },
        "veto_mode": "standard",
        "enable_face_detection": False,
        "enable_emotion": False,
        "sharpness_metric": "global_full_frame",
        "description": "Macro - Detail sharpness priority",
    },
    "landscape": {
        "weights": {
            "dynamic_range": 0.40,
            "composition": 0.40,
            "global_sharpness": 0.20,
        },
        "veto_mode": "standard",
        "enable_face_detection": False,
        "enable_emotion": False,
        "sharpness_metric": "global",
        "description": "Landscape - Dynamic range and composition priority",
    },
    "action": {
        "weights": {
            "composition": 0.35,
            "exposure": 0.30,
            "motion_quality": 0.20,
            "color": 0.15,
        },
        "veto_mode": "motion_blur_tolerance",
        "enable_face_detection": True,
        "enable_emotion": False,
        "sharpness_metric": "motion_aware",
        "description": "Action - Motion blur tolerance enabled",
    },
    "unknown": {
        "weights": {
            "clip": 0.45,
            "aesthetic": 0.25,
            "technical": 0.30,
        },
        "veto_mode": "standard",
        "enable_face_detection": True,
        "enable_emotion": True,
        "sharpness_metric": "auto",
        "description": "Auto - Standard balanced scoring",
    },
}


class FaceDetector:
    def __init__(self):
        self.face_landmarker = None
        self._initialized = False

    def _init(self):
        if not self._initialized and MEDIAPIPE_AVAILABLE:
            model_path = str(paths.mediapipe_face_landmarker_path())
            if not os.path.exists(model_path):
                import urllib.request

                os.makedirs(os.path.dirname(model_path), exist_ok=True)
                print("Downloading face landmarker model...")
                urllib.request.urlretrieve(FACE_LANDMARKER_MODEL_URL, model_path)
                print("Face landmarker model downloaded!")

            options = mp.tasks.vision.FaceLandmarkerOptions(
                base_options=mp.tasks.BaseOptions(model_asset_path=model_path),
                running_mode=mp.tasks.vision.RunningMode.IMAGE,
                num_faces=5,
                min_face_detection_confidence=0.5,
            )
            self.face_landmarker = mp.tasks.vision.FaceLandmarker.create_from_options(
                options
            )
            self._initialized = True

    def detect_faces(self, image: Image.Image) -> list[dict]:
        if not MEDIAPIPE_AVAILABLE:
            return []

        self._init()

        img_array = np.array(image.convert("RGB"))
        h, w = img_array.shape[:2]

        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=img_array)
        results = self.face_landmarker.detect(mp_image)

        faces = []
        if results.face_landmarks:
            for face_landmarks in results.face_landmarks:
                all_x = []
                all_y = []
                left_eye_indices = [33, 133, 160, 159, 158, 144, 145, 153]
                right_eye_indices = [362, 382, 381, 380, 374, 373, 390, 249]

                left_eye_upper = [159, 158, 144, 145]
                left_eye_lower = [153, 154, 155, 133]
                right_eye_upper = [386, 385, 384, 398]
                right_eye_lower = [374, 373, 390, 249]

                left_iris_idx = 468
                right_iris_idx = 473

                left_eye_inner = 133
                left_eye_outer = 33
                right_eye_inner = 362
                right_eye_outer = 263

                left_eye_points = []
                right_eye_points = []
                left_iris = None
                right_iris = None
                left_eye_inner_pt = None
                left_eye_outer_pt = None
                right_eye_inner_pt = None
                right_eye_outer_pt = None

                for idx, landmark in enumerate(face_landmarks):
                    x, y = int(landmark.x * w), int(landmark.y * h)
                    all_x.append(x)
                    all_y.append(y)

                    if idx in left_eye_indices:
                        left_eye_points.append((x, y))
                    if idx in right_eye_indices:
                        right_eye_points.append((x, y))
                    if idx == left_iris_idx:
                        left_iris = (x, y)
                    if idx == right_iris_idx:
                        right_iris = (x, y)
                    if idx == left_eye_inner:
                        left_eye_inner_pt = (x, y)
                    if idx == left_eye_outer:
                        left_eye_outer_pt = (x, y)
                    if idx == right_eye_inner:
                        right_eye_inner_pt = (x, y)
                    if idx == right_eye_outer:
                        right_eye_outer_pt = (x, y)

                eye_contact_score = self._compute_eye_contact(
                    left_iris,
                    right_iris,
                    left_eye_inner_pt,
                    left_eye_outer_pt,
                    right_eye_inner_pt,
                    right_eye_outer_pt,
                )

                blink_score = self._compute_blink_score(
                    face_landmarks,
                    left_eye_upper,
                    left_eye_lower,
                    right_eye_upper,
                    right_eye_lower,
                    w,
                    h,
                )

                padding = 0.2
                face_width = max(all_x) - min(all_x)
                face_height = max(all_y) - min(all_y)

                x_min = max(0, int(min(all_x) - face_width * padding))
                x_max = min(w, int(max(all_x) + face_width * padding))
                y_min = max(0, int(min(all_y) - face_height * padding))
                y_max = min(h, int(max(all_y) + face_height * padding))

                center_x = (x_min + x_max) / 2
                center_y = (y_min + y_max) / 2
                img_center_x = w / 2
                img_center_y = h / 2
                dist_from_center = np.sqrt(
                    ((center_x - img_center_x) / img_center_x) ** 2
                    + ((center_y - img_center_y) / img_center_y) ** 2
                )
                center_proximity = 1.0 - min(1.0, dist_from_center)

                face_area = face_width * face_height
                img_area = w * h
                relative_size = face_area / img_area

                faces.append(
                    {
                        "left_eye": left_eye_points,
                        "right_eye": right_eye_points,
                        "bbox": (x_min, y_min, x_max, y_max),
                        "landmarks": face_landmarks,
                        "eye_contact_score": eye_contact_score,
                        "blink_score": blink_score,
                        "center_proximity": center_proximity,
                        "relative_size": relative_size,
                    }
                )

        return faces

    def _compute_blink_score(
        self, landmarks, left_upper, left_lower, right_upper, right_lower, w, h
    ) -> float:
        def eye_aspect_ratio(upper_indices, lower_indices):
            upper_pts = [
                (landmarks[i].x * w, landmarks[i].y * h)
                for i in upper_indices
                if i < len(landmarks)
            ]
            lower_pts = [
                (landmarks[i].x * w, landmarks[i].y * h)
                for i in lower_indices
                if i < len(landmarks)
            ]

            if len(upper_pts) < 2 or len(lower_pts) < 2:
                return 0.5

            upper_y = np.mean([p[1] for p in upper_pts])
            lower_y = np.mean([p[1] for p in lower_pts])

            left_pt = (
                (landmarks[upper_indices[0]].x * w, landmarks[upper_indices[0]].y * h)
                if upper_indices[0] < len(landmarks)
                else (0, 0)
            )
            right_pt = (
                (landmarks[upper_indices[-1]].x * w, landmarks[upper_indices[-1]].y * h)
                if upper_indices[-1] < len(landmarks)
                else (0, 0)
            )
            eye_width = abs(right_pt[0] - left_pt[0])

            if eye_width < 1:
                return 0.5

            eye_height = abs(lower_y - upper_y)
            ear = eye_height / eye_width

            return min(1.0, ear / 0.35)

        left_ear = eye_aspect_ratio(left_upper, left_lower)
        right_ear = eye_aspect_ratio(right_upper, right_lower)

        avg_ear = (left_ear + right_ear) / 2

        blink_probability = 1.0 - avg_ear

        return max(0.0, min(1.0, blink_probability))

    def _compute_eye_contact(
        self,
        left_iris,
        right_iris,
        left_eye_inner,
        left_eye_outer,
        right_eye_inner,
        right_eye_outer,
    ) -> float:
        if not all(
            [
                left_iris,
                right_iris,
                left_eye_inner,
                left_eye_outer,
                right_eye_inner,
                right_eye_outer,
            ]
        ):
            return 0.5

        def iris_center_ratio(iris, inner, outer):
            if inner[0] == outer[0]:
                return 0.5
            eye_width = abs(outer[0] - inner[0])
            iris_offset = iris[0] - min(inner[0], outer[0])
            ratio = iris_offset / eye_width if eye_width > 0 else 0.5
            return ratio

        left_ratio = iris_center_ratio(left_iris, left_eye_inner, left_eye_outer)
        right_ratio = iris_center_ratio(right_iris, right_eye_inner, right_eye_outer)

        def vertical_center_ratio(iris, inner, outer):
            avg_y = (inner[1] + outer[1]) / 2
            y_diff = abs(iris[1] - avg_y)
            eye_height = abs(inner[1] - outer[1]) if inner[1] != outer[1] else 1
            return max(0, 1 - (y_diff / eye_height))

        left_vert = vertical_center_ratio(left_iris, left_eye_inner, left_eye_outer)
        right_vert = vertical_center_ratio(right_iris, right_eye_inner, right_eye_outer)

        horizontal_score = 1.0 - abs(left_ratio - 0.5) * 2 - abs(right_ratio - 0.5) * 2
        vertical_score = (left_vert + right_vert) / 2

        eye_contact = horizontal_score * 0.6 + vertical_score * 0.4
        return max(0.0, min(1.0, eye_contact))


class TechnicalQualityScorer:
    def __init__(self):
        self.face_detector = FaceDetector()

    def _denoise_for_sharpness(self, img_array: np.ndarray) -> np.ndarray:
        if MEDIAPIPE_AVAILABLE:
            import cv2

            return cv2.medianBlur(img_array.astype(np.uint8), 3).astype(np.float64)
        return img_array

    def compute_local_contrast_map(
        self, img_array: np.ndarray, block_size: int = 8
    ) -> np.ndarray:
        h, w = img_array.shape
        contrast_map = np.zeros_like(img_array)

        for y in range(0, h - block_size, block_size):
            for x in range(0, w - block_size, block_size):
                block = img_array[y : y + block_size, x : x + block_size]
                local_std = np.std(block)
                contrast_map[y : y + block_size, x : x + block_size] = local_std

        return contrast_map

    def compute_sharpness(
        self,
        image: Image.Image,
        top_k_percentile: float = 5.0,
        denoise: bool = True,
    ) -> float:
        img_gray = image.convert("L")
        img_array = np.array(img_gray, dtype=np.float64)

        if denoise:
            img_array = self._denoise_for_sharpness(img_array)

        laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
        lap = ndimage.convolve(img_array, laplacian)
        lap_abs = np.abs(lap)
        lap_flat = lap_abs.flatten()

        k = max(1, int(len(lap_flat) * (top_k_percentile / 100.0)))
        top_k_indices = np.argpartition(lap_flat, -k)[-k:]
        top_k_values = lap_flat[top_k_indices]

        peak_mean = np.mean(top_k_values)
        peak_variance = np.var(top_k_values)
        peak_score = peak_mean / 50.0

        contrast_map = self.compute_local_contrast_map(img_array)
        high_contrast_mask = contrast_map > np.percentile(contrast_map, 70)
        if np.any(high_contrast_mask):
            high_contrast_lap = lap_abs[high_contrast_mask]
            contrast_boost = np.mean(high_contrast_lap) / (np.mean(lap_abs) + 1e-8)
            contrast_boost = min(1.5, max(1.0, contrast_boost))
            peak_score *= contrast_boost

        final_score = peak_score * 0.7 + min(1.0, peak_variance / 2000.0) * 0.3

        return min(1.0, final_score)

    def detect_bokeh_presence(self, image: Image.Image) -> tuple[float, float, float]:
        img_gray = image.convert("L")
        img_array = np.array(img_gray, dtype=np.float64)
        img_array = self._denoise_for_sharpness(img_array)

        laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
        lap = ndimage.convolve(img_array, laplacian)
        lap_abs = np.abs(lap)

        global_variance = lap.var()
        global_mean = np.mean(lap_abs)

        lap_flat = lap_abs.flatten()
        top_5_percent = max(1, int(len(lap_flat) * 0.05))
        top_k_indices = np.argpartition(lap_flat, -top_5_percent)[-top_5_percent:]
        top_k_values = lap_flat[top_k_indices]

        peak_mean = np.mean(top_k_values)
        peak_variance = np.var(top_k_values)

        variance_ratio = peak_variance / (global_variance + 1e-8)
        mean_ratio = peak_mean / (global_mean + 1e-8)

        low_detail_ratio = np.sum(lap_abs < 5) / lap_abs.size
        high_detail_ratio = np.sum(lap_abs > 30) / lap_abs.size

        if low_detail_ratio > 0.7 and mean_ratio > 3.0:
            bokeh_score = min(1.0, low_detail_ratio * mean_ratio / 5.0)
        else:
            bokeh_score = low_detail_ratio * 0.5

        return min(1.0, bokeh_score), variance_ratio, mean_ratio

    def compute_eye_micro_sharpness(
        self, img_array: np.ndarray, landmarks, w: int, h: int
    ) -> float:
        eye_indices = {
            "left_eye": [33, 133, 160, 159, 158, 144, 145, 153],
            "right_eye": [362, 263, 387, 386, 385, 373, 374, 380],
            "left_eyelash": [156, 154, 153, 145, 144, 163, 162, 161],
            "right_eyelash": [383, 382, 381, 373, 372, 390, 391, 392],
        }

        eye_scores = []

        for eye_name, indices in eye_indices.items():
            eye_points = []
            for idx in indices:
                if idx < len(landmarks):
                    x = int(landmarks[idx].x * w)
                    y = int(landmarks[idx].y * h)
                    eye_points.append((x, y))

            if len(eye_points) < 4:
                continue

            xs = [p[0] for p in eye_points]
            ys = [p[1] for p in eye_points]

            margin = 3
            x_min = max(0, min(xs) - margin)
            x_max = min(w, max(xs) + margin)
            y_min = max(0, min(ys) - margin)
            y_max = min(h, max(ys) + margin)

            if x_max <= x_min + 2 or y_max <= y_min + 2:
                continue

            eye_region = img_array[y_min:y_max, x_min:x_max]
            if eye_region.size == 0:
                continue

            if len(eye_region.shape) == 3:
                eye_gray = np.mean(eye_region, axis=2).astype(np.float64)
            else:
                eye_gray = eye_region.astype(np.float64)

            eye_gray = self._denoise_for_sharpness(eye_gray)

            laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
            lap = ndimage.convolve(eye_gray, laplacian)
            lap_abs = np.abs(lap)

            lap_flat = lap_abs.flatten()
            top_20_percent = max(1, int(len(lap_flat) * 0.2))
            top_k_indices = np.argpartition(lap_flat, -top_20_percent)[-top_20_percent:]
            top_k_values = lap_flat[top_k_indices]

            peak_mean = np.mean(top_k_values)
            eye_score = min(1.0, peak_mean / 40.0)
            eye_scores.append(eye_score)

        if eye_scores:
            return float(np.mean(eye_scores))
        return -1.0

    def compute_eye_focus_score(self, image: Image.Image) -> tuple[float, bool]:
        if not MEDIAPIPE_AVAILABLE:
            return self.compute_sharpness(image), False

        img_array = np.array(image.convert("RGB"))
        h, w = img_array.shape[:2]

        faces = self.face_detector.detect_faces(image)

        if not faces:
            return self.compute_sharpness(image), False

        eye_scores = []

        for face in faces:
            landmarks = face.get("landmarks")
            if not landmarks:
                continue

            micro_score = self.compute_eye_micro_sharpness(img_array, landmarks, w, h)
            if micro_score >= 0:
                eye_scores.append(micro_score)
                continue

            for eye_key in ["left_eye", "right_eye"]:
                eye_points = face.get(eye_key, [])
                if not eye_points:
                    continue

                xs = [p[0] for p in eye_points]
                ys = [p[1] for p in eye_points]

                margin = 4
                x_min = max(0, min(xs) - margin)
                x_max = min(w, max(xs) + margin)
                y_min = max(0, min(ys) - margin)
                y_max = min(h, max(ys) + margin)

                if x_max <= x_min or y_max <= y_min:
                    continue

                eye_region = img_array[y_min:y_max, x_min:x_max]

                if eye_region.size == 0:
                    continue

                eye_gray = np.mean(eye_region, axis=2).astype(np.float64)
                eye_gray = self._denoise_for_sharpness(eye_gray)

                laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
                lap = ndimage.convolve(eye_gray, laplacian)
                lap_abs = np.abs(lap)

                lap_flat = lap_abs.flatten()
                top_15_percent = max(1, int(len(lap_flat) * 0.15))
                top_k_indices = np.argpartition(lap_flat, -top_15_percent)[
                    -top_15_percent:
                ]
                top_k_values = lap_flat[top_k_indices]

                peak_mean = np.mean(top_k_values)
                eye_score = min(1.0, peak_mean / 40.0)
                eye_scores.append(eye_score)

        if eye_scores:
            return float(np.mean(eye_scores)), True

        return self.compute_sharpness(image), False

    def compute_face_sharpness(
        self, image: Image.Image
    ) -> tuple[float, bool, list, list]:
        if not MEDIAPIPE_AVAILABLE:
            return self.compute_sharpness(image), False, [], []

        img_array = np.array(image.convert("RGB"))
        h, w = img_array.shape[:2]

        faces = self.face_detector.detect_faces(image)

        if not faces:
            return self.compute_sharpness(image), False, [], []

        face_crops = []
        face_scores = []

        for face in faces:
            bbox = face.get("bbox")
            landmarks = face.get("landmarks")
            if not bbox:
                continue

            x_min, y_min, x_max, y_max = bbox

            if x_max <= x_min or y_max <= y_min:
                continue

            face_region = img_array[y_min:y_max, x_min:x_max]

            if face_region.size == 0:
                continue

            eye_micro_score = -1.0
            if landmarks:
                eye_micro_score = self.compute_eye_micro_sharpness(
                    img_array, landmarks, w, h
                )

            if eye_micro_score >= 0:
                face_score = (
                    eye_micro_score * 0.85
                    + self.compute_sharpness(Image.fromarray(face_region)) * 0.15
                )
                face_scores.append(face_score)
                face["sharpness"] = face_score
                face_crops.append(Image.fromarray(face_region))
                continue

            face_gray = np.mean(face_region, axis=2).astype(np.float64)
            face_gray = self._denoise_for_sharpness(face_gray)

            laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
            lap = ndimage.convolve(face_gray, laplacian)
            lap_abs = np.abs(lap)

            lap_flat = lap_abs.flatten()
            top_10_percent = max(1, int(len(lap_flat) * 0.10))
            top_k_indices = np.argpartition(lap_flat, -top_10_percent)[-top_10_percent:]
            top_k_values = lap_flat[top_k_indices]

            peak_mean = np.mean(top_k_values)
            peak_variance = np.var(top_k_values)

            contrast_map = self.compute_local_contrast_map(face_gray)
            high_contrast_mask = contrast_map > np.percentile(contrast_map, 50)
            if np.any(high_contrast_mask):
                high_contrast_lap = lap_abs[high_contrast_mask]
                contrast_weight = np.mean(high_contrast_lap) / (np.mean(lap_abs) + 1e-8)
                peak_mean *= min(1.3, max(1.0, contrast_weight))

            face_score = peak_mean / 50.0 * 0.6 + min(1.0, peak_variance / 2000.0) * 0.4

            for eye_key in ["left_eye", "right_eye"]:
                eye_points = face.get(eye_key, [])
                if not eye_points:
                    continue

                xs = [p[0] for p in eye_points]
                ys = [p[1] for p in eye_points]

                margin = 4
                ex_min = max(0, min(xs) - margin)
                ex_max = min(w, max(xs) + margin)
                ey_min = max(0, min(ys) - margin)
                ey_max = min(h, max(ys) + margin)

                if ex_max <= ex_min or ey_max <= ey_min:
                    continue

                eye_region = img_array[ey_min:ey_max, ex_min:ex_max]
                if eye_region.size == 0:
                    continue

                eye_gray = np.mean(eye_region, axis=2).astype(np.float64)
                eye_gray = self._denoise_for_sharpness(eye_gray)

                eye_lap = ndimage.convolve(eye_gray, laplacian)
                eye_lap_abs = np.abs(eye_lap)

                eye_flat = eye_lap_abs.flatten()
                eye_top_15 = max(1, int(len(eye_flat) * 0.15))
                eye_top_idx = np.argpartition(eye_flat, -eye_top_15)[-eye_top_15:]
                eye_top_vals = eye_flat[eye_top_idx]

                eye_peak_mean = np.mean(eye_top_vals)
                eye_score = min(1.0, eye_peak_mean / 40.0)

                face_score = face_score * 0.3 + eye_score * 0.7
                break

            face_score = min(1.0, face_score)
            face_scores.append(face_score)
            face["sharpness"] = face_score
            face_crops.append(Image.fromarray(face_region))

        if face_scores:
            return float(np.mean(face_scores)), True, face_crops, faces

        return self.compute_sharpness(image), False, [], []

    def compute_exposure_score(self, image: Image.Image, is_raw: bool = False) -> float:
        img_array = np.array(image.convert("L"), dtype=np.float64)

        if is_raw:
            highlight_threshold = 250
            shadow_threshold = 5

            highlights = np.sum(img_array >= highlight_threshold)
            shadows = np.sum(img_array <= shadow_threshold)
            total_pixels = img_array.size

            highlight_ratio = highlights / total_pixels
            shadow_ratio = shadows / total_pixels

            highlight_penalty = min(1.0, highlight_ratio * 20)
            shadow_penalty = min(1.0, shadow_ratio * 20)

            hist, _ = np.histogram(img_array, bins=256, range=(0, 256))
            hist_norm = hist / total_pixels

            peak_position = np.argmax(hist_norm)
            ideal_peak = 128
            peak_deviation = abs(peak_position - ideal_peak) / 128

            score = 1.0 - (
                highlight_penalty * 0.4 + shadow_penalty * 0.4 + peak_deviation * 0.2
            )

            return max(0.0, min(1.0, score))
        else:
            mean_brightness = np.mean(img_array) / 255.0
            ideal = 0.5
            deviation = abs(mean_brightness - ideal)
            score = 1.0 - min(1.0, deviation * 2)
            return score

    def compute_contrast_score(self, image: Image.Image) -> float:
        img_array = np.array(image.convert("L"), dtype=np.float64)
        std = np.std(img_array)
        return min(1.0, std / 80.0)

    def compute_color_richness(self, image: Image.Image) -> float:
        img_array = np.array(image, dtype=np.float64)
        if len(img_array.shape) == 2:
            return 0.5
        r, g, b = img_array[:, :, 0], img_array[:, :, 1], img_array[:, :, 2]
        color_std = np.std([np.std(r), np.std(g), np.std(b)])
        return min(1.0, color_std / 50.0)

    def compute_composition_score(self, image: Image.Image) -> float:
        img_gray = np.array(image.convert("L"), dtype=np.float64)
        h, w = img_gray.shape
        thirds_h = h // 3
        thirds_w = w // 3
        regions = [
            img_gray[:thirds_h, :thirds_w],
            img_gray[:thirds_h, thirds_w : 2 * thirds_w],
            img_gray[:thirds_h, 2 * thirds_w :],
            img_gray[thirds_h : 2 * thirds_h, :thirds_w],
            img_gray[thirds_h : 2 * thirds_h, thirds_w : 2 * thirds_w],
            img_gray[thirds_h : 2 * thirds_h, 2 * thirds_w :],
            img_gray[2 * thirds_h :, :thirds_w],
            img_gray[2 * thirds_h :, thirds_w : 2 * thirds_w],
            img_gray[2 * thirds_h :, 2 * thirds_w :],
        ]
        region_means = [np.mean(r) for r in regions]
        variance = np.var(region_means)
        return min(1.0, variance / 2000.0)

    def score(self, image: Image.Image, is_raw: bool = False) -> dict:
        face_sharpness, has_face, face_crops, faces = self.compute_face_sharpness(image)
        global_sharpness = self.compute_sharpness(image)

        return {
            "sharpness": round(global_sharpness, 4),
            "face_sharpness": round(face_sharpness, 4),
            "has_face": has_face,
            "face_crops": face_crops,
            "faces": faces,
            "exposure": round(self.compute_exposure_score(image, is_raw), 4),
            "contrast": round(self.compute_contrast_score(image), 4),
            "color_richness": round(self.compute_color_richness(image), 4),
            "composition": round(self.compute_composition_score(image), 4),
        }


class LAIONAestheticScorer:
    def __init__(self, device=None):
        if device is None:
            device = _autodetect_device()
        elif isinstance(device, str):
            device = torch.device(device)
        self.device = device
        self.model = None
        self.processor = None
        self.aesthetic_model = None
        self._load()

    def _load(self):
        print("Loading CLIP ViT-L-14 model...")
        self.model = CLIPModel.from_pretrained(
            "openai/clip-vit-large-patch14",
            cache_dir=MODEL_CACHE_DIR,
            use_safetensors=True,
        )
        self.processor = CLIPProcessor.from_pretrained(
            "openai/clip-vit-large-patch14",
            cache_dir=MODEL_CACHE_DIR,
        )
        self.model.eval()
        self.model.to(self.device)

        print("Loading LAION aesthetic predictor...")
        predictor_path = paths.laion_predictor_path()
        if predictor_path.exists():
            state_dict = torch.load(str(predictor_path), map_location=self.device)
        else:
            state_dict = torch.hub.load_state_dict_from_url(
                "https://github.com/christophschuhmann/improved-aesthetic-predictor/raw/main/sac%2Blogos%2Bava1-l14-linearMSE.pth",
                map_location=self.device,
                model_dir=MODEL_CACHE_DIR,
            )

        class AestheticMLP(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.layers = torch.nn.Sequential(
                    torch.nn.Linear(768, 1024),
                    torch.nn.Dropout(0.2),
                    torch.nn.Linear(1024, 128),
                    torch.nn.Dropout(0.2),
                    torch.nn.Linear(128, 64),
                    torch.nn.Dropout(0.2),
                    torch.nn.Linear(64, 16),
                    torch.nn.Linear(16, 1),
                )

            def forward(self, x):
                return self.layers(x)

        self.aesthetic_model = AestheticMLP()
        self.aesthetic_model.load_state_dict(state_dict)
        self.aesthetic_model.eval()
        self.aesthetic_model.to(self.device)

    def score(self, image: Image.Image) -> float:
        inputs = self.processor(images=image, return_tensors="pt")
        inputs = _move_inputs(inputs, self.device)

        with torch.no_grad():
            image_features = self.model.get_image_features(**inputs)
            image_features = image_features / image_features.norm(dim=-1, keepdim=True)
            aesthetic_score = self.aesthetic_model(image_features).item()

        normalized_score = max(0, min(1, (aesthetic_score - 1) / 9))
        return normalized_score


class EnhancedScorer:
    def __init__(self, device=None):
        if device is None:
            device = _autodetect_device()
        elif isinstance(device, str):
            device = torch.device(device)
        self.device = device
        print(f"Using device: {self.device}")
        self.technical_scorer = TechnicalQualityScorer()

        print("Loading CLIP ViT-B-32 model...")
        self.clip_model = CLIPModel.from_pretrained(
            "openai/clip-vit-base-patch32",
            cache_dir=MODEL_CACHE_DIR,
            use_safetensors=True,
        )
        self.clip_processor = CLIPProcessor.from_pretrained(
            "openai/clip-vit-base-patch32",
            cache_dir=MODEL_CACHE_DIR,
        )
        self.clip_model.eval()
        self.clip_model.to(self.device)

        print("Loading aesthetic scorer...")
        self.aesthetic_scorer = LAIONAestheticScorer(self.device)
        print("All models loaded!")

    def compute_clip_score(self, image: Image.Image) -> tuple[float, dict, np.ndarray]:
        all_prompts = ALL_POSITIVE_PROMPTS + ALL_NEGATIVE_PROMPTS
        inputs = self.clip_processor(
            text=all_prompts,
            images=image,
            return_tensors="pt",
            padding=True,
        )
        inputs = _move_inputs(inputs, self.device)

        with torch.no_grad():
            outputs = self.clip_model(**inputs)
            logits_per_image = outputs.logits_per_image
            probs = logits_per_image.softmax(dim=1)

            prompt_scores = {}
            for i, prompt in enumerate(all_prompts):
                if i < len(ALL_POSITIVE_PROMPTS):
                    prompt_scores[f"quality: {prompt}"] = round(probs[0, i].item(), 4)
                else:
                    prompt_scores[f"issue: {prompt}"] = round(probs[0, i].item(), 4)

            category_scores = {}
            for category, pair in CONTRASTIVE_PAIRS.items():
                positive_probs = []
                negative_probs = []

                for pos_prompt in pair["positive"]:
                    idx = ALL_POSITIVE_PROMPTS.index(pos_prompt)
                    positive_probs.append(probs[0, idx].item())

                for neg_prompt in pair["negative"]:
                    idx = len(ALL_POSITIVE_PROMPTS) + ALL_NEGATIVE_PROMPTS.index(
                        neg_prompt
                    )
                    negative_probs.append(probs[0, idx].item())

                positive_sum = sum(positive_probs)
                negative_sum = sum(negative_probs)

                category_score = positive_sum / (positive_sum + negative_sum + 1e-8)
                category_scores[category] = round(category_score, 4)
                prompt_scores[f"category_{category}"] = round(category_score, 4)

            focus_weight = 0.25
            exposure_weight = 0.25
            composition_weight = 0.15
            lighting_weight = 0.15
            color_weight = 0.10
            quality_weight = 0.10

            clip_score = (
                category_scores["focus"] * focus_weight
                + category_scores["exposure"] * exposure_weight
                + category_scores["composition"] * composition_weight
                + category_scores["lighting"] * lighting_weight
                + category_scores["color"] * color_weight
                + category_scores["quality"] * quality_weight
            )

            overexposed_idx = len(ALL_POSITIVE_PROMPTS) + ALL_NEGATIVE_PROMPTS.index(
                "a severely overexposed white washed photo"
            )
            underexposed_idx = len(ALL_POSITIVE_PROMPTS) + ALL_NEGATIVE_PROMPTS.index(
                "a severely underexposed dark photo"
            )

            prompt_scores["overexposed_prob"] = round(
                probs[0, overexposed_idx].item(), 4
            )
            prompt_scores["underexposed_prob"] = round(
                probs[0, underexposed_idx].item(), 4
            )

            image_features = self.clip_model.get_image_features(
                **{"pixel_values": inputs["pixel_values"]}
            )
            embedding = image_features / image_features.norm(dim=-1, keepdim=True)
            embedding_np = embedding.cpu().numpy().flatten()

        return clip_score, prompt_scores, embedding_np, category_scores

    EMOTION_PROMPTS = {
        "positive": [
            "a happy smiling person",
            "a joyful laughing face",
            "a genuine smile",
        ],
        "negative": [
            "a sad unhappy expression",
            "a neutral bored face",
            "an angry face",
        ],
    }

    def classify_scene(self, image: Image.Image, faces: list = None) -> str:
        all_scene_prompts = []
        scene_labels = []
        for scene_type, prompts in SCENE_PROMPTS.items():
            all_scene_prompts.extend(prompts)
            scene_labels.extend([scene_type] * len(prompts))

        inputs = self.clip_processor(
            text=all_scene_prompts,
            images=image,
            return_tensors="pt",
            padding=True,
        )
        inputs = _move_inputs(inputs, self.device)

        with torch.no_grad():
            outputs = self.clip_model(**inputs)
            probs = outputs.logits_per_image.softmax(dim=1)

        scene_scores = {}
        for scene_type in SCENE_PROMPTS.keys():
            scene_indices = [
                i for i, label in enumerate(scene_labels) if label == scene_type
            ]
            scene_scores[scene_type] = sum(
                probs[0, i].item() for i in scene_indices
            ) / len(scene_indices)

        if faces and len(faces) >= 3:
            return "group"
        elif faces and len(faces) >= 1:
            if scene_scores.get("portrait", 0) > 0.03:
                return "portrait"
            return "portrait"

        best_scene = max(scene_scores, key=scene_scores.get)
        best_score = scene_scores[best_scene]

        other_scores = [s for name, s in scene_scores.items() if name != best_scene]
        avg_other = sum(other_scores) / len(other_scores) if other_scores else 0

        if best_score > avg_other * 1.5 and best_score > 0.05:
            return best_scene

        if best_score < 0.05:
            return "unknown"

        return best_scene

    def compute_emotion_bonus(
        self, face_crops: list, faces: list = None
    ) -> tuple[float, float, list]:
        if not face_crops:
            return 0.0, 0.0, []

        positive_prompts = self.EMOTION_PROMPTS["positive"]
        negative_prompts = self.EMOTION_PROMPTS["negative"]
        all_prompts = positive_prompts + negative_prompts

        emotion_scores = []

        for i, face_crop in enumerate(face_crops):
            try:
                inputs = self.clip_processor(
                    text=all_prompts,
                    images=face_crop,
                    return_tensors="pt",
                    padding=True,
                )
                inputs = _move_inputs(inputs, self.device)

                with torch.no_grad():
                    outputs = self.clip_model(**inputs)
                    probs = outputs.logits_per_image.softmax(dim=1)

                    positive_sum = sum(
                        probs[0, i].item() for i in range(len(positive_prompts))
                    )
                    negative_sum = sum(
                        probs[0, i].item()
                        for i in range(len(positive_prompts), len(all_prompts))
                    )

                    emotion_score = positive_sum / (positive_sum + negative_sum + 1e-8)
                    emotion_scores.append(emotion_score)

                    if faces and i < len(faces):
                        faces[i]["emotion_score"] = emotion_score
            except Exception:
                emotion_scores.append(0.5)

        if not emotion_scores:
            return 0.0, 0.0, []

        avg_emotion = sum(emotion_scores) / len(emotion_scores)

        if avg_emotion > 0.55:
            bonus = (avg_emotion - 0.55) * 0.25
            return min(0.1, bonus), avg_emotion, emotion_scores

        return 0.0, avg_emotion, emotion_scores

    def compute_group_blink_risk(self, faces: list) -> float:
        if not faces:
            return 0.0

        blink_scores = [f.get("blink_score", 0) for f in faces]

        max_blink = max(blink_scores) if blink_scores else 0

        if max_blink > 0.7:
            return max_blink

        return 0.0

    def compute_depth_priority_sharpness(
        self, faces: list, img_width: int, img_height: int
    ) -> tuple[float, float]:
        if not faces:
            return 0.5, 0.0

        weighted_scores = []
        weights = []

        for face in faces:
            sharpness = face.get("sharpness", 0.5)
            center_proximity = face.get("center_proximity", 0.5)
            relative_size = face.get("relative_size", 0.01)

            weight = center_proximity * 0.6 + min(1.0, relative_size * 50) * 0.4
            weighted_scores.append(sharpness * weight)
            weights.append(weight)

        if not weights or sum(weights) == 0:
            return float(np.mean([f.get("sharpness", 0.5) for f in faces])), 0.0

        depth_weighted_sharpness = sum(weighted_scores) / sum(weights)

        all_sharpness = [f.get("sharpness", 0.5) for f in faces]
        focus_consistency = 1.0 - (
            np.std(all_sharpness) if len(all_sharpness) > 1 else 0
        )

        return depth_weighted_sharpness, focus_consistency

    def compute_group_joy_score(self, emotion_scores: list) -> tuple[float, bool]:
        if not emotion_scores:
            return 0.0, False

        avg_joy = sum(emotion_scores) / len(emotion_scores)
        everyone_smiling = all(s > 0.6 for s in emotion_scores)

        return avg_joy, everyone_smiling

    def compute_group_analysis(self, faces: list, emotion_scores: list) -> dict:
        if not faces:
            return {
                "face_count": 0,
                "everyone_smiling": False,
                "focus_consistency": 1.0,
                "group_blink_risk": 0.0,
                "group_joy_score": 0.0,
                "primary_subjects_sharp": True,
            }

        all_sharpness = [f.get("sharpness", 0.5) for f in faces]
        focus_consistency = 1.0 - (
            np.std(all_sharpness) if len(all_sharpness) > 1 else 0
        )

        center_faces = sorted(
            faces, key=lambda f: f.get("center_proximity", 0), reverse=True
        )
        primary_count = max(1, len(faces) // 3) if len(faces) > 2 else len(faces)
        primary_sharpness = [
            f.get("sharpness", 0.5) for f in center_faces[:primary_count]
        ]
        primary_subjects_sharp = all(s > 0.4 for s in primary_sharpness)

        blink_scores = [f.get("blink_score", 0) for f in faces]
        group_blink_risk = max(blink_scores) if blink_scores else 0

        group_joy_score, everyone_smiling = self.compute_group_joy_score(emotion_scores)

        return {
            "face_count": len(faces),
            "everyone_smiling": everyone_smiling,
            "focus_consistency": round(focus_consistency, 4),
            "group_blink_risk": round(group_blink_risk, 4),
            "group_joy_score": round(group_joy_score, 4),
            "primary_subjects_sharp": primary_subjects_sharp,
        }

    def compute_eye_contact_bonus(self, faces: list) -> float:
        if not faces:
            return 0.0

        eye_contact_scores = []
        for face in faces:
            score = face.get("eye_contact_score", 0.5)
            eye_contact_scores.append(score)

        if not eye_contact_scores:
            return 0.0

        avg_eye_contact = sum(eye_contact_scores) / len(eye_contact_scores)

        if avg_eye_contact > 0.7:
            bonus = (avg_eye_contact - 0.7) * 0.15
            return min(0.08, bonus)

        return 0.0

    def compute_primary_subject_joy(self, faces: list, emotion_scores: list) -> float:
        if not faces or not emotion_scores:
            return 0.0

        sorted_faces = sorted(
            faces, key=lambda f: f.get("center_proximity", 0), reverse=True
        )

        primary_idx = faces.index(sorted_faces[0]) if sorted_faces else 0
        if primary_idx < len(emotion_scores):
            return emotion_scores[primary_idx]
        return emotion_scores[0] if emotion_scores else 0.0

    def compute_quality_anchor_boost(self, faces: list, emotion_scores: list) -> float:
        if len(faces) < 2 or len(emotion_scores) < 2:
            return 0.0

        sorted_faces = sorted(
            faces,
            key=lambda f: (
                f.get("center_proximity", 0) * 0.6
                + min(1.0, f.get("relative_size", 0) * 50) * 0.4
            ),
            reverse=True,
        )

        primary_idx = faces.index(sorted_faces[0]) if sorted_faces else 0
        primary_joy = (
            emotion_scores[primary_idx] if primary_idx < len(emotion_scores) else 0.0
        )

        if primary_joy > 0.7:
            surrounding_boost = (primary_joy - 0.7) * 0.3
            return min(0.1, surrounding_boost)
        return 0.0

    def compute_dynamic_range_score(self, image: Image.Image) -> float:
        img_array = np.array(image.convert("L"), dtype=np.float64)
        hist, _ = np.histogram(img_array, bins=256, range=(0, 256))
        hist_norm = hist / img_array.size

        non_zero_bins = np.sum(hist_norm > 0.001)
        dynamic_range_score = min(1.0, non_zero_bins / 200.0)

        std = np.std(img_array)
        contrast_score = min(1.0, std / 80.0)

        return dynamic_range_score * 0.6 + contrast_score * 0.4

    def compute_lighting_texture_score(self, image: Image.Image) -> float:
        img_array = np.array(image.convert("L"), dtype=np.float64)

        h, w = img_array.shape
        quadrants = [
            img_array[: h // 2, : w // 2],
            img_array[: h // 2, w // 2 :],
            img_array[h // 2 :, : w // 2],
            img_array[h // 2 :, w // 2 :],
        ]
        quadrant_means = [np.mean(q) for q in quadrants]
        lighting_consistency = 1.0 - (np.std(quadrant_means) / 128.0)
        lighting_consistency = max(0, min(1.0, lighting_consistency))

        laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
        lap = ndimage.convolve(img_array, laplacian)
        texture_score = min(1.0, np.mean(np.abs(lap)) / 50.0)

        return lighting_consistency * 0.4 + texture_score * 0.6

    def compute_motion_quality_score(self, image: Image.Image) -> float:
        img_array = np.array(image.convert("L"), dtype=np.float64)

        laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
        lap = ndimage.convolve(img_array, laplacian)
        variance = lap.var()

        sharpness = min(1.0, variance / 1000.0)

        edge_density = np.sum(np.abs(lap) > 20) / img_array.size

        motion_quality = sharpness * 0.5 + min(1.0, edge_density * 3) * 0.5

        return motion_quality

    def score_with_profile(
        self,
        image: Image.Image,
        profile_name: str,
        is_raw: bool = False,
    ) -> dict:
        profile = SCORING_PROFILES.get(profile_name, SCORING_PROFILES["unknown"])
        clip_breakdown = {}

        clip_score, _, _, category_scores = self.compute_clip_score(image)
        aesthetic_score = self.aesthetic_scorer.score(image)
        technical_scores = self.technical_scorer.score(image, is_raw)

        enable_face = profile.get("enable_face_detection", True)
        enable_emotion = profile.get("enable_emotion", True)
        sharpness_metric = profile.get("sharpness_metric", "auto")
        weights = profile.get("weights", {})
        veto_mode = profile.get("veto_mode", "standard")

        has_face = False
        faces = []
        face_crops = []
        emotion_scores = []
        emotion_score = 0.0
        emotion_bonus = 0.0
        face_count = 0

        if enable_face:
            has_face = technical_scores.get("has_face", False)
            faces = technical_scores.get("faces", [])
            face_crops = technical_scores.get("face_crops", [])
            face_count = len(faces)

        if enable_emotion and face_crops:
            emotion_bonus, emotion_score, emotion_scores = self.compute_emotion_bonus(
                face_crops, faces
            )

        img_width, img_height = image.size

        composition = technical_scores.get("composition", 0.5)
        exposure = technical_scores.get("exposure", 0.5)
        color_richness = technical_scores.get("color_richness", 0.5)
        contrast = technical_scores.get("contrast", 0.5)

        if sharpness_metric == "face" and has_face:
            primary_sharpness = technical_scores.get("face_sharpness", 0.5)
        elif sharpness_metric == "depth_weighted" and has_face and len(faces) > 1:
            primary_sharpness, _ = self.compute_depth_priority_sharpness(
                faces, img_width, img_height
            )
        elif sharpness_metric == "global_full_frame":
            primary_sharpness = self._compute_full_frame_sharpness(image)
        elif sharpness_metric == "motion_aware":
            primary_sharpness = self.compute_motion_quality_score(image)
        else:
            if has_face:
                primary_sharpness = technical_scores.get(
                    "face_sharpness", technical_scores.get("sharpness", 0.5)
                )
            else:
                primary_sharpness = technical_scores.get("sharpness", 0.5)

        dynamic_range = self.compute_dynamic_range_score(image)
        lighting_texture = self.compute_lighting_texture_score(image)

        group_analysis = self.compute_group_analysis(faces, emotion_scores)
        everyone_smiling = group_analysis.get("everyone_smiling", False)
        group_joy_score = group_analysis.get("group_joy_score", 0.0)
        focus_consistency = group_analysis.get("focus_consistency", 1.0)

        score_components = {}

        if "face_sharpness" in weights:
            score_components["face_sharpness"] = (
                primary_sharpness * weights["face_sharpness"]
            )
        if "emotion" in weights:
            score_components["emotion"] = emotion_score * weights["emotion"]
        if "composition" in weights:
            score_components["composition"] = composition * weights["composition"]
        if "color" in weights:
            score_components["color"] = color_richness * weights["color"]
        if "group_joy" in weights:
            score_components["group_joy"] = group_joy_score * weights["group_joy"]
        if "focus_consistency" in weights:
            score_components["focus_consistency"] = (
                focus_consistency * weights["focus_consistency"]
            )
        if "exposure" in weights:
            score_components["exposure"] = exposure * weights["exposure"]
        if "global_sharpness" in weights:
            score_components["global_sharpness"] = (
                technical_scores.get("sharpness", 0.5) * weights["global_sharpness"]
            )
        if "lighting_texture" in weights:
            score_components["lighting_texture"] = (
                lighting_texture * weights["lighting_texture"]
            )
        if "dynamic_range" in weights:
            score_components["dynamic_range"] = dynamic_range * weights["dynamic_range"]
        if "motion_quality" in weights:
            score_components["motion_quality"] = (
                primary_sharpness * weights["motion_quality"]
            )
        if "clip" in weights:
            score_components["clip"] = clip_score * weights["clip"]
        if "aesthetic" in weights:
            score_components["aesthetic"] = aesthetic_score * weights["aesthetic"]
        if "technical" in weights:
            technical_avg = np.mean(
                [primary_sharpness, exposure, contrast, color_richness, composition]
            )
            score_components["technical"] = technical_avg * weights["technical"]

        base_score = sum(score_components.values())

        effective_sharpness_threshold = SHARPNESS_THRESHOLD
        sharpness_penalty = 1.0

        if veto_mode == "strict_blink":
            blink_scores = [f.get("blink_score", 0) for f in faces] if faces else []
            max_blink = max(blink_scores) if blink_scores else 0
            if max_blink > 0.5:
                sharpness_penalty = 0.6
                clip_breakdown["blink_veto_applied"] = True
        elif veto_mode == "relaxed_sharpness_on_joy":
            if everyone_smiling and face_count >= 3:
                effective_sharpness_threshold = SHARPNESS_THRESHOLD * 0.7
                clip_breakdown["sharpness_threshold_relaxed"] = True
            if primary_sharpness < effective_sharpness_threshold:
                sharpness_penalty = primary_sharpness / effective_sharpness_threshold
                sharpness_penalty = min(1.0, sharpness_penalty)
        elif veto_mode == "motion_blur_tolerance":
            if primary_sharpness < SHARPNESS_THRESHOLD:
                sharpness_penalty = (
                    1.0 - (1.0 - primary_sharpness / SHARPNESS_THRESHOLD) * 0.6
                )
                clip_breakdown["motion_blur_tolerance_applied"] = True
            sharpness_penalty = min(1.0, sharpness_penalty)
        else:
            if primary_sharpness < SHARPNESS_THRESHOLD:
                sharpness_penalty = primary_sharpness / SHARPNESS_THRESHOLD

        combined_score = base_score * sharpness_penalty
        combined_score = min(1.0, max(0.0, combined_score))

        if emotion_bonus > 0:
            clip_breakdown["emotion_bonus"] = round(emotion_bonus, 4)

        group_boost_factor = 1.0
        if profile_name == "group":
            if face_count > 2 and everyone_smiling:
                combined_score *= 1.2
                group_boost_factor = 1.2
                clip_breakdown["social_multiplier"] = 1.2
            if face_count >= 3 and group_joy_score > 0.85:
                quality_anchor_boost = self.compute_quality_anchor_boost(
                    faces, emotion_scores
                )
                if quality_anchor_boost > 0:
                    combined_score += quality_anchor_boost
                    group_boost_factor += quality_anchor_boost
                    clip_breakdown["quality_anchor_boost"] = round(
                        quality_anchor_boost, 4
                    )

        clip_breakdown["group_boost_factor"] = round(group_boost_factor, 4)
        clip_breakdown["scoring_profile"] = profile_name
        clip_breakdown["profile_description"] = profile.get("description", "")

        return {
            "score": round(combined_score, 4),
            "clip_score": round(clip_score, 4),
            "aesthetic_score": round(aesthetic_score, 4),
            "technical_score": round(primary_sharpness, 4),
            "breakdown": clip_breakdown,
            "technical_breakdown": {
                "sharpness": round(technical_scores.get("sharpness", 0.5), 4),
                "face_sharpness": round(technical_scores.get("face_sharpness", 0.5), 4),
                "exposure": round(exposure, 4),
                "contrast": round(contrast, 4),
                "color_richness": round(color_richness, 4),
                "composition": round(composition, 4),
                "dynamic_range": round(dynamic_range, 4),
                "lighting_texture": round(lighting_texture, 4),
            },
            "category_scores": category_scores,
            "weights": weights,
            "has_face": has_face,
            "face_sharpness": round(technical_scores.get("face_sharpness", 0), 4),
            "faces": faces,
            "group_analysis": group_analysis,
        }

    def _compute_full_frame_sharpness(self, image: Image.Image) -> float:
        img_gray = image.convert("L")
        img_array = np.array(img_gray, dtype=np.float64)

        h, w = img_array.shape
        regions = []
        grid_size = 4
        for i in range(grid_size):
            for j in range(grid_size):
                y_start = i * h // grid_size
                y_end = (i + 1) * h // grid_size
                x_start = j * w // grid_size
                x_end = (j + 1) * w // grid_size
                regions.append(img_array[y_start:y_end, x_start:x_end])

        sharpness_scores = []
        for region in regions:
            laplacian = np.array([[0, 1, 0], [1, -4, 1], [0, 1, 0]])
            lap = ndimage.convolve(region, laplacian)
            variance = lap.var()
            sharpness_scores.append(min(1.0, variance / 1000.0))

        max_sharpness = max(sharpness_scores)
        avg_sharpness = np.mean(sharpness_scores)

        return max_sharpness * 0.6 + avg_sharpness * 0.4

    def score(
        self,
        image: Image.Image,
        weights: dict = None,
        is_raw: bool = False,
        scene_override: str = None,
    ) -> dict:
        if weights is None:
            weights = WEIGHTS.copy()

        clip_score, clip_breakdown, embedding, category_scores = (
            self.compute_clip_score(image)
        )

        aesthetic_score = self.aesthetic_scorer.score(image)

        technical_scores = self.technical_scorer.score(image, is_raw)

        has_face = technical_scores.get("has_face", False)
        faces = technical_scores.get("faces", [])
        face_crops = technical_scores.get("face_crops", [])

        detected_scene = scene_override
        if detected_scene is None:
            detected_scene = self.classify_scene(image, faces)

        clip_breakdown["detected_scene"] = detected_scene

        if detected_scene in SCORING_PROFILES:
            profile = SCORING_PROFILES[detected_scene]
            if profile.get("enable_face_detection", True) == False:
                has_face = False
                faces = []
                face_crops = []

        img_width, img_height = image.size

        emotion_bonus, emotion_score, emotion_scores = self.compute_emotion_bonus(
            face_crops, faces
        )

        group_analysis = self.compute_group_analysis(faces, emotion_scores)
        face_count = group_analysis.get("face_count", 0)
        everyone_smiling = group_analysis.get("everyone_smiling", False)
        group_joy_score = group_analysis.get("group_joy_score", 0.0)

        if has_face and len(faces) > 1:
            depth_sharpness, focus_consistency = self.compute_depth_priority_sharpness(
                faces, img_width, img_height
            )
            primary_sharpness = depth_sharpness
            group_analysis["focus_consistency"] = round(focus_consistency, 4)
        elif has_face:
            primary_sharpness = technical_scores.get("face_sharpness", 0.5)
        else:
            primary_sharpness = technical_scores.get("sharpness", 0.5)

        technical_metrics = {
            "sharpness": technical_scores.get("sharpness", 0.5),
            "face_sharpness": technical_scores.get("face_sharpness", 0.5),
            "exposure": technical_scores.get("exposure", 0.5),
            "contrast": technical_scores.get("contrast", 0.5),
            "color_richness": technical_scores.get("color_richness", 0.5),
            "composition": technical_scores.get("composition", 0.5),
        }

        technical_avg = np.mean(
            [
                primary_sharpness,
                technical_metrics["exposure"],
                technical_metrics["contrast"],
                technical_metrics["color_richness"],
                technical_metrics["composition"],
            ]
        )

        base_weighted_score = (
            clip_score * weights["clip"]
            + aesthetic_score * weights["aesthetic"]
            + technical_avg * weights["technical"]
        )

        eye_contact_bonus = self.compute_eye_contact_bonus(faces)

        group_boost_factor = 1.0
        quality_anchor_boost = 0.0
        social_multiplier = 1.0

        if face_count > 2 and everyone_smiling:
            social_multiplier = 1.2
            clip_breakdown["social_multiplier"] = social_multiplier
            base_weighted_score *= social_multiplier
            group_boost_factor *= social_multiplier

        if face_count > 2 and group_joy_score > 0.85:
            quality_anchor_boost = self.compute_quality_anchor_boost(
                faces, emotion_scores
            )
            if quality_anchor_boost > 0:
                clip_breakdown["quality_anchor_boost"] = round(quality_anchor_boost, 4)
                base_weighted_score += quality_anchor_boost
                group_boost_factor += quality_anchor_boost

        effective_sharpness_threshold = SHARPNESS_THRESHOLD

        bokeh_score, variance_ratio, mean_ratio = (
            self.technical_scorer.detect_bokeh_presence(image)
        )
        clip_breakdown["bokeh_score"] = round(bokeh_score, 4)
        clip_breakdown["variance_ratio"] = round(variance_ratio, 4)
        clip_breakdown["mean_ratio"] = round(mean_ratio, 4)

        if bokeh_score > 0.5 and has_face:
            bokeh_threshold_relaxation = 0.7 + (bokeh_score - 0.5) * 0.3
            effective_sharpness_threshold *= bokeh_threshold_relaxation
            clip_breakdown["bokeh_threshold_relaxed"] = True
            clip_breakdown["bokeh_relaxation_factor"] = round(
                bokeh_threshold_relaxation, 4
            )

        if detected_scene == "action":
            effective_sharpness_threshold = SHARPNESS_THRESHOLD * 0.6
            clip_breakdown["action_blur_tolerance"] = True
        elif face_count >= 3 and group_joy_score > 0.85:
            effective_sharpness_threshold = min(
                effective_sharpness_threshold, SHARPNESS_THRESHOLD * 0.7
            )
            clip_breakdown["sharpness_threshold_relaxed"] = True

        clip_breakdown["effective_sharpness_threshold"] = round(
            effective_sharpness_threshold, 4
        )

        sharpness_penalty = 1.0
        adjusted_sharpness_penalty = 1.0

        if detected_scene == "portrait" and has_face:
            blink_scores = [f.get("blink_score", 0) for f in faces]
            max_blink = max(blink_scores) if blink_scores else 0
            if max_blink > 0.5:
                clip_breakdown["portrait_blink_warning"] = True
                if max_blink > 0.7:
                    sharpness_penalty = 0.5
                    clip_breakdown["blink_veto_applied"] = True

        if sharpness_penalty == 1.0:
            if has_face and not group_analysis.get("primary_subjects_sharp", True):
                sharpness_penalty = primary_sharpness / effective_sharpness_threshold
                clip_breakdown["primary_subject_blur"] = True
            elif primary_sharpness < effective_sharpness_threshold:
                sharpness_penalty = primary_sharpness / effective_sharpness_threshold

            sharpness_penalty = min(1.0, sharpness_penalty)

        if sharpness_penalty < 1.0:
            if detected_scene == "action":
                relaxed_penalty = sharpness_penalty + (1.0 - sharpness_penalty) * 0.6
                adjusted_sharpness_penalty = relaxed_penalty
                clip_breakdown["motion_blur_rescue"] = True
                clip_breakdown["sharpness_penalty_original"] = round(
                    sharpness_penalty, 4
                )
                clip_breakdown["sharpness_penalty_action_relaxed"] = round(
                    relaxed_penalty, 4
                )
            elif has_face and emotion_score > 0.9:
                relaxed_penalty = sharpness_penalty + (1.0 - sharpness_penalty) * 0.5
                adjusted_sharpness_penalty = relaxed_penalty
                clip_breakdown["sharpness_penalty_original"] = round(
                    sharpness_penalty, 4
                )
                clip_breakdown["sharpness_penalty_relaxed"] = round(relaxed_penalty, 4)
                clip_breakdown["emotion_rescue_applied"] = True
            elif face_count >= 3 and group_joy_score > 0.85:
                relaxed_penalty = sharpness_penalty + (1.0 - sharpness_penalty) * 0.4
                adjusted_sharpness_penalty = relaxed_penalty
                clip_breakdown["group_emotion_rescue"] = True
                clip_breakdown["sharpness_penalty_original"] = round(
                    sharpness_penalty, 4
                )
                clip_breakdown["sharpness_penalty_group_relaxed"] = round(
                    relaxed_penalty, 4
                )
            else:
                adjusted_sharpness_penalty = sharpness_penalty

            clip_breakdown["sharpness_penalty_applied"] = round(
                adjusted_sharpness_penalty, 4
            )

        group_blink_risk = group_analysis.get("group_blink_risk", 0)
        blink_penalty = 1.0
        if group_blink_risk > 0.7:
            blink_penalty = 1.0 - (group_blink_risk - 0.7) * 0.5
            clip_breakdown["blink_penalty"] = round(blink_penalty, 4)
            clip_breakdown["blink_risk_face"] = True

        social_bonus = 0.0
        if everyone_smiling and face_count > 1:
            if face_count >= 3:
                social_bonus = 0.20
            else:
                social_bonus = 0.15
            clip_breakdown["social_bonus"] = social_bonus

        group_boost_factor = round(group_boost_factor, 4)
        clip_breakdown["group_boost_factor"] = group_boost_factor

        emotion_aesthetic_weight = 1.0
        if detected_scene in ["portrait", "group"] and face_count >= 3:
            emotion_aesthetic_weight = 0.7
            clip_breakdown["technical_penalty_reduced"] = True

        combined_score = (
            base_weighted_score
            + (emotion_bonus * 1.5)
            + eye_contact_bonus
            + social_bonus
        )

        combined_score = (
            combined_score
            * (
                adjusted_sharpness_penalty * emotion_aesthetic_weight
                + (1 - emotion_aesthetic_weight)
            )
            * blink_penalty
        )

        combined_score = min(1.0, combined_score)

        if emotion_bonus > 0:
            clip_breakdown["emotion_bonus"] = round(emotion_bonus, 4)
            clip_breakdown["emotion_score"] = round(emotion_score, 4)

        if eye_contact_bonus > 0:
            clip_breakdown["eye_contact_bonus"] = round(eye_contact_bonus, 4)

        overexposed_prob = clip_breakdown.get("overexposed_prob", 0)
        underexposed_prob = clip_breakdown.get("underexposed_prob", 0)

        exposure_veto_threshold = EXPOSURE_CLIP_THRESHOLD
        if (
            detected_scene in ["portrait", "group"]
            and face_count >= 3
            and group_joy_score > 0.85
        ):
            exposure_veto_threshold = 0.55
            clip_breakdown["exposure_veto_relaxed"] = True

        if (
            overexposed_prob > exposure_veto_threshold
            or underexposed_prob > exposure_veto_threshold
        ):
            exposure_cap = EXPOSURE_SCORE_CAP
            if (
                detected_scene in ["portrait", "group"]
                and face_count >= 3
                and group_joy_score > 0.85
            ):
                exposure_cap = 0.5
                clip_breakdown["exposure_cap_relaxed"] = True
            if combined_score > exposure_cap:
                combined_score = exposure_cap
            clip_breakdown["exposure_veto_applied"] = True

        profile_desc = SCORING_PROFILES.get(detected_scene, {}).get(
            "description", "Auto"
        )

        return {
            "score": round(combined_score, 4),
            "clip_score": round(clip_score, 4),
            "aesthetic_score": round(aesthetic_score, 4),
            "technical_score": round(technical_avg, 4),
            "breakdown": clip_breakdown,
            "technical_breakdown": technical_metrics,
            "category_scores": category_scores,
            "weights": weights,
            "embedding": embedding,
            "has_face": has_face,
            "face_sharpness": round(technical_scores.get("face_sharpness", 0), 4),
            "faces": faces,
            "group_analysis": group_analysis,
            "detected_scene": detected_scene,
            "scoring_profile": profile_desc,
        }
