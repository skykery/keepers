#!/usr/bin/env python3
"""Photo culling tool for raw photos."""

import os
import shutil
import json
from pathlib import Path
from typing import Optional

RAW_EXTENSIONS = {".orf", ".nef", ".dng", ".cr2", ".cr3", ".arw", ".rw2", ".raf"}
PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tiff", ".tif", ".gif"}
ALL_PHOTO_EXTENSIONS = RAW_EXTENSIONS | PHOTO_EXTENSIONS


class PhotoCuller:
    def __init__(self, originals_dir: str = "originals", output_dir: str = "culled"):
        self.originals_dir = Path(originals_dir)
        self.output_dir = Path(output_dir)
        self.keeps_dir = self.output_dir / "keeps"
        self.rejects_dir = self.output_dir / "rejects"
        self.state_file = self.output_dir / "cull_state.json"
        self.state: dict = {}

    def setup(self) -> None:
        self.keeps_dir.mkdir(parents=True, exist_ok=True)
        self.rejects_dir.mkdir(parents=True, exist_ok=True)
        self.load_state()

    def load_state(self) -> None:
        if self.state_file.exists():
            with open(self.state_file, "r") as f:
                self.state = json.load(f)
        else:
            self.state = {"keeps": [], "rejects": []}

    def save_state(self) -> None:
        with open(self.state_file, "w") as f:
            json.dump(self.state, f, indent=2)

    def scan_photos(self) -> list[Path]:
        photos = []
        for f in self.originals_dir.iterdir():
            if f.is_file() and f.suffix.lower() in ALL_PHOTO_EXTENSIONS:
                photos.append(f)
        return sorted(photos)

    def get_photo_status(self, photo: Path) -> Optional[str]:
        photo_name = photo.name
        if photo_name in self.state["keeps"]:
            return "keep"
        elif photo_name in self.state["rejects"]:
            return "reject"
        return None

    def mark_keep(self, photo: Path) -> None:
        photo_name = photo.name
        if photo_name in self.state["rejects"]:
            self.state["rejects"].remove(photo_name)
        if photo_name not in self.state["keeps"]:
            self.state["keeps"].append(photo_name)
        self.save_state()

    def mark_reject(self, photo: Path) -> None:
        photo_name = photo.name
        if photo_name in self.state["keeps"]:
            self.state["keeps"].remove(photo_name)
        if photo_name not in self.state["rejects"]:
            self.state["rejects"].append(photo_name)
        self.save_state()

    def unmark(self, photo: Path) -> None:
        photo_name = photo.name
        if photo_name in self.state["keeps"]:
            self.state["keeps"].remove(photo_name)
        if photo_name in self.state["rejects"]:
            self.state["rejects"].remove(photo_name)
        self.save_state()

    def move_keeps(self) -> int:
        moved = 0
        for photo_name in self.state["keeps"]:
            src = self.originals_dir / photo_name
            if src.exists():
                shutil.copy2(src, self.keeps_dir / photo_name)
                moved += 1
        return moved

    def move_rejects(self) -> int:
        moved = 0
        for photo_name in self.state["rejects"]:
            src = self.originals_dir / photo_name
            if src.exists():
                shutil.copy2(src, self.rejects_dir / photo_name)
                moved += 1
        return moved

    def get_stats(self) -> dict:
        photos = self.scan_photos()
        total = len(photos)
        keeps = len(self.state["keeps"])
        rejects = len(self.state["rejects"])
        undecided = total - keeps - rejects
        return {
            "total": total,
            "keeps": keeps,
            "rejects": rejects,
            "undecided": undecided,
        }

    def list_photos(self) -> list[dict]:
        photos = self.scan_photos()
        result = []
        for photo in photos:
            result.append(
                {
                    "name": photo.name,
                    "size": photo.stat().st_size,
                    "status": self.get_photo_status(photo) or "undecided",
                }
            )
        return result
