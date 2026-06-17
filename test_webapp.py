#!/usr/bin/env python3
"""Tests for web interface."""

import os
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock

from webapp import app, get_directories, get_parent_directory, _safe_filename


class TestWebApp(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.originals_dir = Path(self.temp_dir) / "originals"
        self.output_dir = Path(self.temp_dir) / "output"
        self.originals_dir.mkdir()
        self.output_dir.mkdir()

        for i in range(3):
            filepath = self.originals_dir / f"test{i}.orf"
            filepath.write_bytes(b"0" * 1000)

        app.config["TESTING"] = True
        self.client = app.test_client()

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def test_index_page(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Keepers", response.data)

    def test_browse_endpoint(self):
        response = self.client.post(
            "/api/browse",
            data=json.dumps({"path": self.temp_dir}),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data["current"], self.temp_dir)
        self.assertIn("originals", str(data["directories"]))

    def test_browse_nonexistent_path(self):
        response = self.client.post(
            "/api/browse",
            data=json.dumps({"path": "/nonexistent/path"}),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertIn("directories", data)

    def test_start_endpoint_missing_input(self):
        response = self.client.post(
            "/api/start", data=json.dumps({}), content_type="application/json"
        )

        self.assertEqual(response.status_code, 400)

    def test_start_endpoint_invalid_input(self):
        response = self.client.post(
            "/api/start",
            data=json.dumps({"input_dir": "/nonexistent"}),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 400)

    def test_status_endpoint(self):
        response = self.client.get("/api/status")
        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertIn("running", data)

    def test_photos_endpoint_no_session(self):
        response = self.client.get("/api/photos")
        self.assertEqual(response.status_code, 400)

    def test_photos_by_folder_invalid_folder(self):
        response = self.client.get("/api/photos/invalid")
        self.assertEqual(response.status_code, 400)

    def test_stats_endpoint_no_session(self):
        response = self.client.get("/api/stats")
        self.assertEqual(response.status_code, 400)

    def test_photo_endpoint_no_session(self):
        response = self.client.get("/api/photo/test.orf")
        self.assertEqual(response.status_code, 400)

    def test_preview_endpoint(self):
        response = self.client.post(
            "/api/preview",
            data=json.dumps({"input_dir": str(self.originals_dir)}),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 200)
        data = response.get_json()
        self.assertEqual(data["photo_count"], 3)
        self.assertEqual(data["raw_count"], 3)
        self.assertEqual(data["jpg_count"], 0)
        self.assertIn("estimated_time", data)

    def test_preview_endpoint_invalid_path(self):
        response = self.client.post(
            "/api/preview",
            data=json.dumps({"input_dir": "/nonexistent"}),
            content_type="application/json",
        )

        self.assertEqual(response.status_code, 400)
        data = response.get_json()
        self.assertIn("error", data)


class TestFilenameValidation(unittest.TestCase):
    def test_accepts_plain_basenames(self):
        self.assertTrue(_safe_filename("photo.jpg"))
        self.assertTrue(_safe_filename("IMG_1234.ORF"))
        self.assertTrue(_safe_filename("with spaces.png"))
        self.assertTrue(_safe_filename(".hidden.jpg"))

    def test_rejects_traversal(self):
        self.assertFalse(_safe_filename("../etc/passwd"))
        self.assertFalse(_safe_filename("..\\etc\\passwd"))
        self.assertFalse(_safe_filename(".."))
        self.assertFalse(_safe_filename("."))
        self.assertFalse(_safe_filename("/etc/passwd"))
        self.assertFalse(_safe_filename("foo/bar.jpg"))
        self.assertFalse(_safe_filename("foo\\bar.jpg"))

    def test_rejects_null_byte_and_empty(self):
        self.assertFalse(_safe_filename(""))
        self.assertFalse(_safe_filename("foo\x00.jpg"))

    def test_move_endpoint_rejects_traversal(self):
        app.config["TESTING"] = True
        client = app.test_client()

        import webapp
        webapp.culler = MagicMock()
        webapp.folder_manager = MagicMock()
        try:
            response = client.post(
                "/api/move",
                data=json.dumps({
                    "photo_name": "../../etc/passwd",
                    "target_folder": "picks",
                }),
                content_type="application/json",
            )
            self.assertEqual(response.status_code, 400)
            webapp.folder_manager.move_photo.assert_not_called()
        finally:
            webapp.culler = None
            webapp.folder_manager = None


class TestModelIntegrity(unittest.TestCase):
    def test_sha256_mismatch_raises_and_cleans_up(self):
        import models_download

        tmp_dir = tempfile.mkdtemp()
        try:
            dest = Path(tmp_dir) / "model.pth"
            bad_content = b"not the real model weights"

            def fake_urlretrieve(url, path, reporthook=None):
                Path(path).write_bytes(bad_content)

            with patch.object(
                models_download.urllib.request, "urlretrieve", side_effect=fake_urlretrieve
            ):
                with self.assertRaises(models_download.ModelIntegrityError):
                    models_download._download_file(
                        "http://fake.example/model",
                        dest,
                        "0" * 64,
                        "test model",
                        lambda msg: None,
                    )

            self.assertFalse(dest.exists())
            self.assertFalse(dest.with_suffix(dest.suffix + ".part").exists())
        finally:
            shutil.rmtree(tmp_dir)

    def test_sha256_match_writes_file(self):
        import hashlib
        import models_download

        tmp_dir = tempfile.mkdtemp()
        try:
            dest = Path(tmp_dir) / "model.pth"
            good_content = b"valid model bytes"
            good_sha = hashlib.sha256(good_content).hexdigest()

            def fake_urlretrieve(url, path, reporthook=None):
                Path(path).write_bytes(good_content)

            with patch.object(
                models_download.urllib.request, "urlretrieve", side_effect=fake_urlretrieve
            ):
                models_download._download_file(
                    "http://fake.example/model",
                    dest,
                    good_sha,
                    "test model",
                    lambda msg: None,
                )

            self.assertTrue(dest.exists())
            self.assertEqual(dest.read_bytes(), good_content)
        finally:
            shutil.rmtree(tmp_dir)


class TestDirectoryHelpers(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()

        self.dir1 = Path(self.temp_dir) / "dir1"
        self.dir2 = Path(self.temp_dir) / "dir2"
        self.hidden_dir = Path(self.temp_dir) / ".hidden"

        self.dir1.mkdir()
        self.dir2.mkdir()
        self.hidden_dir.mkdir()

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def test_get_directories(self):
        dirs = get_directories(self.temp_dir)
        self.assertEqual(len(dirs), 2)
        self.assertIn(str(self.dir1), dirs)
        self.assertIn(str(self.dir2), dirs)
        self.assertNotIn(str(self.hidden_dir), dirs)

    def test_get_directories_nonexistent(self):
        dirs = get_directories("/nonexistent/path")
        self.assertEqual(dirs, [])

    def test_get_parent_directory(self):
        parent = get_parent_directory(str(self.dir1))
        self.assertEqual(parent, self.temp_dir)

    def test_get_parent_directory_root(self):
        parent = get_parent_directory("/")
        self.assertEqual(parent, "/")


class TestThumbnailGeneration(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        app.config["TESTING"] = True
        self.client = app.test_client()

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def test_image_to_thumbnail(self):
        from PIL import Image
        from webapp import image_to_thumbnail

        img_path = Path(self.temp_dir) / "test.jpg"
        cache_path = Path(self.temp_dir) / "thumb.jpg"
        img = Image.new("RGB", (500, 500), color="red")
        img.save(img_path)

        result = image_to_thumbnail(img_path, cache_path)
        self.assertTrue(result)
        self.assertTrue(cache_path.exists())

    def test_generate_thumbnail(self):
        from PIL import Image
        from webapp import generate_thumbnail

        img_path = Path(self.temp_dir) / "test.jpg"
        cache_path = Path(self.temp_dir) / "thumb.jpg"
        img = Image.new("RGB", (500, 500), color="blue")
        img.save(img_path)

        result = generate_thumbnail(img_path, cache_path)
        self.assertTrue(result)
        self.assertTrue(cache_path.exists())

    def test_get_thumbnail_cache_dir(self):
        from webapp import get_thumbnail_cache_dir

        cache_dir = get_thumbnail_cache_dir(Path(self.temp_dir))
        self.assertTrue(cache_dir.exists())
        self.assertEqual(cache_dir.name, ".thumbnails")


class TestOrganizationPersistence(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.mkdtemp()
        self.output_dir = Path(self.temp_dir) / "output"
        self.output_dir.mkdir()

        from folder_manager import FolderManager, FolderType

        self.fm = FolderManager(self.output_dir)

        self.photo_path = Path(self.temp_dir) / "test.jpg"
        self.photo_path.write_bytes(b"fake photo")

    def tearDown(self):
        shutil.rmtree(self.temp_dir)

    def test_move_photo_saves_organization(self):
        from folder_manager import FolderType

        self.fm.move_photo("test.jpg", self.photo_path, FolderType.PICKS)

        org_file = self.output_dir / "organization.json"
        self.assertTrue(org_file.exists())

        import json

        with open(org_file) as f:
            org = json.load(f)

        self.assertEqual(org.get("test.jpg"), "Top Picks")

    def test_organization_restored_on_resume(self):
        from folder_manager import FolderManager, FolderType

        self.fm.move_photo("test.jpg", self.photo_path, FolderType.PICKS)

        fm2 = FolderManager(self.output_dir)
        override = fm2.get_manual_override("test.jpg")

        self.assertEqual(override, FolderType.PICKS)

    def test_restore_organization_creates_symlinks(self):
        from folder_manager import FolderManager, FolderType

        self.fm.move_photo("test.jpg", self.photo_path, FolderType.PICKS)

        for folder in self.output_dir.iterdir():
            if folder.is_dir():
                for item in folder.iterdir():
                    if item.is_symlink():
                        item.unlink()

        fm2 = FolderManager(self.output_dir)
        restored = fm2.restore_organization([self.photo_path])

        self.assertEqual(restored, 1)

        location = fm2.get_photo_location("test.jpg")
        self.assertEqual(location, FolderType.PICKS)


if __name__ == "__main__":
    unittest.main()
