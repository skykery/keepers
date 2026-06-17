#!/usr/bin/env python3
"""Tests for photo culling tool."""

import os
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from cull import PhotoCuller, RAW_EXTENSIONS, PHOTO_EXTENSIONS, ALL_PHOTO_EXTENSIONS


class TestPhotoCuller(unittest.TestCase):
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

        self.culler = PhotoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        self.culler.setup()

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def test_setup_creates_directories(self):
        self.assertTrue(self.output_dir.exists())
        self.assertTrue((self.output_dir / "keeps").exists())
        self.assertTrue((self.output_dir / "rejects").exists())

    def test_scan_photos_finds_all_raw_files(self):
        photos = self.culler.scan_photos()
        self.assertEqual(len(photos), 9)
        names = [p.name for p in photos]
        for f in self.test_files:
            self.assertIn(f, names)
        for f in self.photo_files:
            self.assertIn(f, names)
            self.assertIn(f, names)

    def test_scan_photos_ignores_non_raw_files(self):
        txt_file = self.originals_dir / "readme.txt"
        txt_file.write_bytes(b"text")
        photos = self.culler.scan_photos()
        names = [p.name for p in photos]
        self.assertNotIn("readme.txt", names)

    def test_mark_keep(self):
        photo = self.originals_dir / "test1.orf"
        self.culler.mark_keep(photo)
        self.assertIn("test1.orf", self.culler.state["keeps"])
        self.assertEqual(self.culler.get_photo_status(photo), "keep")

    def test_mark_reject(self):
        photo = self.originals_dir / "test2.orf"
        self.culler.mark_reject(photo)
        self.assertIn("test2.orf", self.culler.state["rejects"])
        self.assertEqual(self.culler.get_photo_status(photo), "reject")

    def test_mark_keep_removes_reject(self):
        photo = self.originals_dir / "test3.nef"
        self.culler.mark_reject(photo)
        self.assertIn("test3.nef", self.culler.state["rejects"])

        self.culler.mark_keep(photo)
        self.assertIn("test3.nef", self.culler.state["keeps"])
        self.assertNotIn("test3.nef", self.culler.state["rejects"])

    def test_mark_reject_removes_keep(self):
        photo = self.originals_dir / "test4.dng"
        self.culler.mark_keep(photo)
        self.assertIn("test4.dng", self.culler.state["keeps"])

        self.culler.mark_reject(photo)
        self.assertIn("test4.dng", self.culler.state["rejects"])
        self.assertNotIn("test4.dng", self.culler.state["keeps"])

    def test_unmark(self):
        photo = self.originals_dir / "test5.cr2"
        self.culler.mark_keep(photo)
        self.culler.unmark(photo)
        self.assertIsNone(self.culler.get_photo_status(photo))
        self.assertNotIn("test5.cr2", self.culler.state["keeps"])

    def test_state_persistence(self):
        photo = self.originals_dir / "test1.orf"
        self.culler.mark_keep(photo)

        new_culler = PhotoCuller(
            originals_dir=str(self.originals_dir), output_dir=str(self.output_dir)
        )
        new_culler.load_state()

        self.assertIn("test1.orf", new_culler.state["keeps"])

    def test_get_stats(self):
        self.culler.mark_keep(self.originals_dir / "test1.orf")
        self.culler.mark_reject(self.originals_dir / "test2.orf")

        stats = self.culler.get_stats()
        self.assertEqual(stats["total"], 9)
        self.assertEqual(stats["keeps"], 1)
        self.assertEqual(stats["rejects"], 1)
        self.assertEqual(stats["undecided"], 7)

    def test_list_photos(self):
        self.culler.mark_keep(self.originals_dir / "test1.orf")
        self.culler.mark_reject(self.originals_dir / "test2.orf")

        photos = self.culler.list_photos()
        self.assertEqual(len(photos), 9)

        statuses = {p["name"]: p["status"] for p in photos}
        self.assertEqual(statuses["test1.orf"], "keep")
        self.assertEqual(statuses["test2.orf"], "reject")
        self.assertEqual(statuses["test3.nef"], "undecided")

    def test_move_keeps(self):
        self.culler.mark_keep(self.originals_dir / "test1.orf")
        self.culler.mark_keep(self.originals_dir / "test3.nef")

        moved = self.culler.move_keeps()
        self.assertEqual(moved, 2)

        keeps_dir = self.output_dir / "keeps"
        self.assertTrue((keeps_dir / "test1.orf").exists())
        self.assertTrue((keeps_dir / "test3.nef").exists())

    def test_move_rejects(self):
        self.culler.mark_reject(self.originals_dir / "test2.orf")
        self.culler.mark_reject(self.originals_dir / "test4.dng")

        moved = self.culler.move_rejects()
        self.assertEqual(moved, 2)

        rejects_dir = self.output_dir / "rejects"
        self.assertTrue((rejects_dir / "test2.orf").exists())
        self.assertTrue((rejects_dir / "test4.dng").exists())

    def test_move_preserves_original(self):
        self.culler.mark_keep(self.originals_dir / "test1.orf")
        self.culler.move_keeps()

        self.assertTrue((self.originals_dir / "test1.orf").exists())


class TestRawExtensions(unittest.TestCase):
    def test_common_raw_extensions_included(self):
        expected = {".orf", ".nef", ".dng", ".cr2", ".cr3", ".arw", ".rw2", ".raf"}
        self.assertTrue(expected.issubset(RAW_EXTENSIONS))

    def test_extensions_are_lowercase(self):
        for ext in RAW_EXTENSIONS:
            self.assertEqual(ext, ext.lower())


class TestPhotoExtensions(unittest.TestCase):
    def test_common_photo_extensions_included(self):
        expected = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff", ".tif", ".gif"}
        self.assertTrue(expected.issubset(PHOTO_EXTENSIONS))

    def test_all_photo_extensions_combined(self):
        self.assertTrue(RAW_EXTENSIONS.issubset(ALL_PHOTO_EXTENSIONS))
        self.assertTrue(PHOTO_EXTENSIONS.issubset(ALL_PHOTO_EXTENSIONS))


if __name__ == "__main__":
    unittest.main()
