#!/usr/bin/env python3
"""Tests for automatic photo culling."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from auto_cull import AutoCuller, RAW_EXTENSIONS, PHOTO_EXTENSIONS, ALL_PHOTO_EXTENSIONS


class TestAutoCuller(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.originals_dir = Path(self.temp_dir) / "originals"
        self.output_dir = Path(self.temp_dir) / "culled"
        self.originals_dir.mkdir()

        self.test_files = [
            "test1.orf",
            "test2.orf",
            "test3.nef",
            "test4.dng",
            "test5.cr2",
        ]

        self.photo_files = [
            "photo1.jpg",
            "photo2.jpeg",
            "photo3.png",
            "photo4.webp",
        ]

        for filename in self.test_files + self.photo_files:
            filepath = self.originals_dir / filename
            filepath.write_bytes(b"0" * 1000)

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def test_setup_creates_output_directory(self):
        culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        culler.setup()

        self.assertTrue(self.output_dir.exists())

    def test_scan_photos_finds_all_raw_files(self):
        culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        photos = culler.scan_photos()

        self.assertEqual(len(photos), 9)
        names = [p.name for p in photos]
        for f in self.test_files:
            self.assertIn(f, names)
        for f in self.photo_files:
            self.assertIn(f, names)

    def test_scan_photos_ignores_non_raw_files(self):
        txt_file = self.originals_dir / "readme.txt"
        txt_file.write_bytes(b"text")

        culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        photos = culler.scan_photos()
        names = [p.name for p in photos]

        self.assertNotIn("readme.txt", names)

    def test_scores_persistence(self):
        culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        culler.setup()

        culler.scores["test1.orf"] = {"score": 0.85, "error": False}
        culler._save_scores()

        new_culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        new_culler._load_scores()

        self.assertIn("test1.orf", new_culler.scores)
        self.assertEqual(new_culler.scores["test1.orf"]["score"], 0.85)

    def test_get_stats(self):
        culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        culler.scores = {
            "test1.orf": {"score": 0.9, "error": False},
            "test2.orf": {"score": 0.7, "error": False},
            "test3.nef": {"score": 0.0, "error": True},
        }

        stats = culler.get_stats()

        self.assertEqual(stats["total"], 9)
        self.assertEqual(stats["scored"], 2)
        self.assertEqual(stats["errors"], 1)
        self.assertEqual(stats["avg_score"], 0.8)
        self.assertEqual(stats["max_score"], 0.9)
        self.assertEqual(stats["min_score"], 0.7)


class TestAutoCullerWithMockedModel(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.originals_dir = Path(self.temp_dir) / "originals"
        self.output_dir = Path(self.temp_dir) / "culled"
        self.originals_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    @patch("auto_cull.EnhancedScorer")
    def test_score_photos_with_mock(self, mock_scorer_class):
        test_file = self.originals_dir / "test.jpg"
        test_file.write_bytes(b"0" * 1000)

        mock_scorer = Mock()
        mock_scorer.score.return_value = {
            "score": 0.85,
            "clip_score": 0.8,
            "aesthetic_score": 0.9,
            "technical_score": 0.85,
            "breakdown": {},
            "technical_breakdown": {},
        }
        mock_scorer_class.return_value = mock_scorer

        culler = AutoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        culler.setup()

        with patch.object(culler, "_load_image") as mock_load:
            from PIL import Image

            mock_image = Image.new("RGB", (100, 100))
            mock_load.return_value = mock_image

            scores = culler.score_photos(force=True)

        self.assertIn("test.jpg", scores)
        self.assertEqual(scores["test.jpg"]["score"], 0.85)


class TestRawExtensionsAutoCull(unittest.TestCase):
    def test_common_raw_extensions_included(self):
        expected = {".orf", ".nef", ".dng", ".cr2", ".cr3", ".arw", ".rw2", ".raf"}
        self.assertTrue(expected.issubset(RAW_EXTENSIONS))

    def test_common_photo_extensions_included(self):
        expected = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff", ".tif", ".gif"}
        self.assertTrue(expected.issubset(PHOTO_EXTENSIONS))

    def test_all_photo_extensions_combined(self):
        self.assertTrue(RAW_EXTENSIONS.issubset(ALL_PHOTO_EXTENSIONS))
        self.assertTrue(PHOTO_EXTENSIONS.issubset(ALL_PHOTO_EXTENSIONS))


if __name__ == "__main__":
    unittest.main()
