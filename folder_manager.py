#!/usr/bin/env python3
"""Folder management with symlink-based organization for photo culling."""

import json
import os
import sys
import platform
import shutil
from pathlib import Path
from typing import Optional
from enum import Enum


class FolderType(Enum):
    PICKS = "Top Picks"
    MOMENTS = "Moments"
    REVIEW = "Review"
    TRASH = "Trash"


FOLDER_DESCRIPTIONS = {
    FolderType.PICKS: "AI-selected top picks (score > 0.7)",
    FolderType.MOMENTS: "Photos rescued by emotion detection",
    FolderType.REVIEW: "Photos needing manual review (0.4 - 0.7)",
    FolderType.TRASH: "Technical failures (score < 0.4)",
}


class FolderManager:
    def __init__(self, output_dir: Path):
        self.output_dir = Path(output_dir)
        self._is_windows = platform.system() == "Windows"
        self._folders: dict[FolderType, Path] = {}
        self._organization_file = self.output_dir / "organization.json"
        self._organization: dict[str, str] = {}
        self._ensure_folders()
        self._load_organization()

    def _ensure_folders(self):
        for folder_type in FolderType:
            folder_path = self.output_dir / folder_type.value
            folder_path.mkdir(parents=True, exist_ok=True)
            self._folders[folder_type] = folder_path

    def _load_organization(self):
        if self._organization_file.exists():
            try:
                with open(self._organization_file, "r") as f:
                    self._organization = json.load(f)
            except Exception:
                self._organization = {}
        else:
            self._organization = {}

    def _save_organization(self):
        try:
            with open(self._organization_file, "w") as f:
                json.dump(self._organization, f, indent=2)
        except Exception:
            pass

    def _create_symlink(self, source: Path, target: Path) -> bool:
        try:
            if target.exists() or target.is_symlink():
                if target.is_symlink():
                    target.unlink()
                else:
                    target.unlink()

            if self._is_windows:
                import subprocess

                cmd = ["mklink", str(target), str(source)]
                subprocess.run(cmd, shell=True, check=True, capture_output=True)
            else:
                os.symlink(str(source), str(target))
            return True
        except Exception:
            return False

    def _remove_symlink(self, target: Path) -> bool:
        try:
            if target.is_symlink() or target.exists():
                target.unlink()
            return True
        except Exception:
            return False

    def get_folder(self, folder_type: FolderType) -> Path:
        return self._folders.get(folder_type)

    def get_photo_location(self, photo_name: str) -> Optional[FolderType]:
        for folder_type, folder_path in self._folders.items():
            potential_link = folder_path / photo_name
            if potential_link.exists() or potential_link.is_symlink():
                return folder_type
        return None

    def move_photo(
        self, photo_name: str, source_path: Path, target_folder: FolderType
    ) -> bool:
        for folder_type in FolderType:
            existing_link = self._folders[folder_type] / photo_name
            if existing_link.exists() or existing_link.is_symlink():
                self._remove_symlink(existing_link)

        target_path = self._folders[target_folder] / photo_name
        success = self._create_symlink(source_path, target_path)

        if success:
            self._organization[photo_name] = target_folder.value
            self._save_organization()

        return success

    def classify_photo(
        self, photo_name: str, source_path: Path, score: float, breakdown: dict = None
    ) -> FolderType:
        breakdown = breakdown or {}

        emotion_rescue = breakdown.get("emotion_rescue_applied", False)

        if emotion_rescue:
            folder = FolderType.MOMENTS
        elif score > 0.7:
            folder = FolderType.PICKS
        elif score >= 0.4:
            folder = FolderType.REVIEW
        else:
            folder = FolderType.TRASH

        self.move_photo(photo_name, source_path, folder)
        return folder

    def get_manual_override(self, photo_name: str) -> Optional[FolderType]:
        folder_value = self._organization.get(photo_name)
        if folder_value:
            for ft in FolderType:
                if ft.value == folder_value:
                    return ft
        return None

    def restore_organization(self, photos: list[Path]) -> int:
        restored = 0
        for photo in photos:
            photo_name = photo.name
            folder_type = self.get_manual_override(photo_name)
            if folder_type:
                target_path = self._folders[folder_type] / photo_name
                if not target_path.exists() and not target_path.is_symlink():
                    if self._create_symlink(photo, target_path):
                        restored += 1
        return restored

    def get_all_photos(self) -> dict[str, list[str]]:
        result = {}
        for folder_type in FolderType:
            folder_path = self._folders[folder_type]
            photos = []
            for item in folder_path.iterdir():
                if item.is_symlink():
                    photos.append(item.name)
            result[folder_type.value] = sorted(photos)
        return result

    def get_photos_in_folder(self, folder_type: FolderType) -> list[str]:
        folder_path = self._folders.get(folder_type)
        if not folder_path:
            return []

        photos = []
        for item in folder_path.iterdir():
            if item.is_symlink():
                photos.append(item.name)
        return sorted(photos)

    def clear_all_symlinks(self):
        for folder_type in FolderType:
            folder_path = self._folders[folder_type]
            for item in folder_path.iterdir():
                if item.is_symlink():
                    item.unlink()

    def get_symlink_target(
        self, photo_name: str, folder_type: FolderType
    ) -> Optional[Path]:
        link_path = self._folders[folder_type] / photo_name
        if link_path.is_symlink():
            try:
                return Path(os.readlink(str(link_path)))
            except Exception:
                return None
        return None

    def get_stats(self) -> dict:
        stats = {"total": 0}
        for folder_type in FolderType:
            count = len(self.get_photos_in_folder(folder_type))
            stats[folder_type.value] = count
            stats["total"] += count
        return stats
