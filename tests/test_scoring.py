#!/usr/bin/env python3
"""Tests for enhanced scoring module."""

import tempfile
import unittest
from pathlib import Path
from PIL import Image
import numpy as np

from scoring import TechnicalQualityScorer, QUALITY_PROMPTS, LOW_QUALITY_PROMPTS


class TestTechnicalQualityScorer(unittest.TestCase):
    def setUp(self):
        self.scorer = TechnicalQualityScorer()
        self.temp_dir = tempfile.mkdtemp()

    def tearDown(self):
        import shutil

        shutil.rmtree(self.temp_dir)

    def _create_image(self, color, size=(100, 100)):
        img = Image.new("RGB", size, color=color)
        return img

    def test_compute_sharpness_uniform(self):
        img = self._create_image((128, 128, 128))
        score = self.scorer.compute_sharpness(img)
        self.assertGreaterEqual(score, 0)
        self.assertLessEqual(score, 1)

    def test_compute_sharpness_edges(self):
        img_array = np.zeros((100, 100, 3), dtype=np.uint8)
        img_array[:, 50:] = 255
        img = Image.fromarray(img_array)
        score = self.scorer.compute_sharpness(img)
        self.assertGreater(score, 0)

    def test_compute_exposure_score_ideal(self):
        img = self._create_image((128, 128, 128))
        score = self.scorer.compute_exposure_score(img)
        self.assertGreater(score, 0.8)

    def test_compute_exposure_score_dark(self):
        img = self._create_image((30, 30, 30))
        score = self.scorer.compute_exposure_score(img)
        self.assertLess(score, 0.8)

    def test_compute_exposure_score_bright(self):
        img = self._create_image((230, 230, 230))
        score = self.scorer.compute_exposure_score(img)
        self.assertLess(score, 0.8)

    def test_compute_exposure_score_raw_clipped_highlights(self):
        img_array = np.full((100, 100, 3), 255, dtype=np.uint8)
        img = Image.fromarray(img_array)
        score = self.scorer.compute_exposure_score(img, is_raw=True)
        self.assertLess(score, 0.8)

    def test_compute_exposure_score_raw_clipped_shadows(self):
        img_array = np.zeros((100, 100, 3), dtype=np.uint8)
        img = Image.fromarray(img_array)
        score = self.scorer.compute_exposure_score(img, is_raw=True)
        self.assertLess(score, 0.8)

    def test_compute_exposure_score_raw_well_exposed(self):
        img_array = np.full((100, 100, 3), 128, dtype=np.uint8)
        img = Image.fromarray(img_array)
        score = self.scorer.compute_exposure_score(img, is_raw=True)
        self.assertGreater(score, 0.5)

    def test_compute_contrast_score_uniform(self):
        img = self._create_image((128, 128, 128))
        score = self.scorer.compute_contrast_score(img)
        self.assertGreaterEqual(score, 0)
        self.assertLessEqual(score, 1)

    def test_compute_contrast_score_high(self):
        img_array = np.zeros((100, 100, 3), dtype=np.uint8)
        img_array[:50, :] = 0
        img_array[50:, :] = 255
        img = Image.fromarray(img_array)
        score = self.scorer.compute_contrast_score(img)
        self.assertGreater(score, 0)

    def test_compute_color_richness_grayscale(self):
        img = self._create_image((128, 128, 128))
        score = self.scorer.compute_color_richness(img)
        self.assertGreaterEqual(score, 0)
        self.assertLessEqual(score, 1)

    def test_compute_color_richness_colorful(self):
        img_array = np.zeros((100, 100, 3), dtype=np.uint8)
        img_array[:, :, 0] = 255
        img_array[:50, :, 1] = 128
        img_array[50:, :, 2] = 200
        img = Image.fromarray(img_array)
        score = self.scorer.compute_color_richness(img)
        self.assertGreater(score, 0)

    def test_compute_composition_score(self):
        img = self._create_image((128, 128, 128))
        score = self.scorer.compute_composition_score(img)
        self.assertGreaterEqual(score, 0)
        self.assertLessEqual(score, 1)

    def test_score_returns_all_metrics(self):
        img = self._create_image((100, 100, 100))
        result = self.scorer.score(img, is_raw=False)

        self.assertIn("sharpness", result)
        self.assertIn("exposure", result)
        self.assertIn("contrast", result)
        self.assertIn("color_richness", result)
        self.assertIn("composition", result)

    def test_score_values_in_range(self):
        img = self._create_image((150, 100, 50))
        result = self.scorer.score(img, is_raw=False)

        for key, value in result.items():
            if key in ("face_crops", "has_face", "faces"):
                continue
            self.assertGreaterEqual(value, 0, f"{key} should be >= 0")
            self.assertLessEqual(value, 1, f"{key} should be <= 1")

    def test_score_raw_mode(self):
        img = self._create_image((150, 100, 50))
        result = self.scorer.score(img, is_raw=True)

        self.assertIn("sharpness", result)
        self.assertIn("exposure", result)
        self.assertIn("contrast", result)
        self.assertIn("color_richness", result)
        self.assertIn("composition", result)


class TestPrompts(unittest.TestCase):
    def test_quality_prompts_not_empty(self):
        self.assertGreater(len(QUALITY_PROMPTS), 0)

    def test_low_quality_prompts_not_empty(self):
        self.assertGreater(len(LOW_QUALITY_PROMPTS), 0)

    def test_quality_prompts_are_strings(self):
        for prompt in QUALITY_PROMPTS:
            self.assertIsInstance(prompt, str)

    def test_low_quality_prompts_are_strings(self):
        for prompt in LOW_QUALITY_PROMPTS:
            self.assertIsInstance(prompt, str)


if __name__ == "__main__":
    unittest.main()
