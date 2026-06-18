# PyInstaller build spec for the Keepers macOS .app.
#
# Build with:
#   ./venv/bin/pyinstaller Keepers.spec --clean --noconfirm
#
# Followed by scripts/build_dmg.sh for sign + notarize + .dmg.
# Models are downloaded on first launch, not bundled.

import os
from PyInstaller.utils.hooks import collect_all

APP_NAME = "Keepers"
VERSION = open(os.path.join(os.path.dirname(os.path.abspath(SPEC)), "VERSION")).read().strip()

datas = [("templates", "templates")]
binaries = []
hiddenimports = [
    "paths",
    "scoring",
    "auto_cull",
    "cull",
    "folder_manager",
    "webapp",
]

# Pull every file (Python, data, binary) belonging to these packages. MediaPipe
# and torch in particular ship .dylib / .task / model files that PyInstaller's
# default analysis misses.
for pkg in [
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
]:
    pkg_datas, pkg_binaries, pkg_hidden = collect_all(pkg)
    datas += pkg_datas
    binaries += pkg_binaries
    hiddenimports += pkg_hidden

icon_path = "icon.icns" if os.path.exists("icon.icns") else None

a = Analysis(
    ["app.py"],
    pathex=[],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name=APP_NAME,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=icon_path,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name=APP_NAME,
)

app = BUNDLE(
    coll,
    name=f"{APP_NAME}.app",
    icon=icon_path,
    bundle_identifier="com.skykery.keepers",
    version=VERSION,
    info_plist={
        "CFBundleName": APP_NAME,
        "CFBundleDisplayName": APP_NAME,
        "CFBundleIdentifier": "com.skykery.keepers",
        "CFBundleVersion": VERSION,
        "CFBundleShortVersionString": VERSION,
        "NSHighResolutionCapable": True,
        "LSMinimumSystemVersion": "11.0",
    },
)
