"""py2app build config for the Keepers macOS .app.

Usage:
    ./venv/bin/python setup.py py2app               # build dist/Keepers.app

Followed by scripts/build_dmg.sh for sign + notarize + .dmg.
Models are downloaded on first launch, not bundled.
"""

import os
import sys

from setuptools import setup

APP = ["app.py"]
APP_NAME = "Keepers"
VERSION = (open(os.path.join(os.path.dirname(__file__), "VERSION")).read().strip())


def collect_tree(src_root: str) -> list:
    """Walk src_root and return DATA_FILES tuples preserving the tree."""
    out = []
    if not os.path.isdir(src_root):
        return out
    for dirpath, _, filenames in os.walk(src_root):
        if not filenames:
            continue
        rel = os.path.relpath(dirpath, src_root)
        target = rel if rel != "." else ""
        out.append((target, [os.path.join(dirpath, f) for f in filenames]))
    return out


DATA_FILES = [
    ("templates", ["templates/index.html"]),
]


OPTIONS = {
    "argv_emulation": False,
    "packages": [
        "torch",
        "transformers",
        "mediapipe",
        "rawpy",
        "cv2",
        "scipy",
        "PIL",
        "flask",
        "webview",
        "numpy",
    ],
    "includes": [
        "paths",
        "scoring",
        "auto_cull",
        "cull",
        "folder_manager",
        "webapp",
    ],
    "plist": {
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleIdentifier": "com.skykery.keepers",
        "CFBundleVersion": VERSION,
        "CFBundleShortVersionString": VERSION,
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
    },
}

# Icon is optional — include if the user has dropped one in.
if os.path.exists("icon.icns"):
    OPTIONS["iconfile"] = "icon.icns"

# PyTorch's deep package graph blows the default recursion limit during bundling.
sys.setrecursionlimit(5000)


setup(
    name=APP_NAME,
    version=VERSION,
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
