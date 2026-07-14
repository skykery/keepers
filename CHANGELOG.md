# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add new entries under **[Unreleased]**. `scripts/bump.sh` promotes that
section to a dated version heading at release time — there is no manual
step for that.

## [Unreleased]

### Added

### Changed

### Fixed

## [1.3.4] - 2026-07-14

- Skip macOS AppleDouble metadata files (`._*.JPG`) when scanning a
  photo folder. Common on external drives (FAT/exFAT/NTFS). Previously
  they passed the extension filter and PIL failed on each one — dozens
  of `Error loading ._000001.JPG: cannot identify image file` per session.
- Reduce fork-related warnings and worker crashes. Set
  `TOKENIZERS_PARALLELISM=false` before importing transformers/tokenizers
  in the .app launcher and in `scoring.py`.
- Remove deprecated `TRANSFORMERS_CACHE` env var (`HF_HOME` already covers
  it in modern transformers).
- Install `sys.excepthook` and `threading.excepthook` in the .app launcher
  so silent background-thread crashes produce a stderr traceback instead
  of a mystery restart.

## [1.3.3] - 2026-07-13

- Bundled `.app` crashed at "Downloading AI models" with a bogus
  "CLIPModel requires PyTorch" error. Real cause: `requirements.txt`
  had no upper bounds, so the Intel build pinned `torch==2.2.2` (last
  x86_64 macOS wheel on PyPI) but pulled the newest `transformers`,
  which requires `torch >= 2.4`. transformers detected the mismatch
  and disabled torch integration silently. Pinned `torch==2.2.2`,
  `torchvision==0.17.2`, `transformers<4.50`, `numpy<2` — same lib
  set on both archs.

## [1.3.2] - 2026-06-19

### Added
- Dual-architecture release builds. CI now matrix-builds the .app on a
  `macos-13` Intel runner (x86_64) AND a `macos-14` Apple Silicon runner
  (arm64), notarizes both, and ships two .dmgs per release. Previous
  releases were arm64-only, which left Intel Macs with "this application
  is not supported on this Mac" errors. PyTorch and MediaPipe don't ship
  universal2 wheels on PyPI so a single universal2 build wasn't an option.

### Changed

### Fixed

## [1.3.1] - 2026-06-19

### Changed
- Switched the .app bundler from py2app to PyInstaller. py2app's macholib
  refused to relocate MediaPipe's `libmediapipe.dylib` Mach-O header
  ("delta=56" headerpad overflow), and no version pin or pre-pad worked
  around it. `Keepers.spec` replaces `setup.py`.
- Releases are now a two-workflow pipeline. **Release (build + submit)**
  builds, signs, and submits to Apple, then exits (~30 min). Once Apple
  accepts (typically 1–4 h on this account), the **Finalize release**
  workflow is triggered manually to staple, build the `.dmg`, and publish
  the GitHub Release. Splits the macOS-runner cost without losing
  automation. `scripts/build_dmg.sh` decomposed into
  `build_and_sign.sh` + `submit_notarization.sh` + `finalize_release.sh`.
- Test files moved from the repo root into `tests/`. Run with
  `python -m unittest discover -s tests`.

### Added
- `.github/workflows/notary-status.yml`: a diagnostic workflow that calls
  `notarytool history` + `notarytool log` so we can ask Apple directly
  what state past submissions are in.
- `.github/workflows/finalize-release.yml`: the second half of the split
  release pipeline.

## [1.3.0] - 2026-06-17

### Added
- `VERSION` file as single source of truth for the app version. `setup.py`
  and `scripts/build_dmg.sh` read it; `scripts/bump.sh` writes it.
- `scripts/bump.sh` — bumps the version, rewrites CHANGELOG, commits and
  tags in one step.
- `.github/workflows/release.yml` — tag-driven macOS build, signing,
  notarization, and GitHub Release publishing.
- `docs/RELEASING.md` — one-time signing setup and per-release flow.

### Changed
- Repository renamed Photo Culler → **Keepers**.
- Relicensed MIT → AGPL-3.0.
- Models are downloaded on first launch instead of bundled inside the
  `.app`. Cuts the `.dmg` from ~2 GB to ~200 MB.
- LAION and MediaPipe downloads are now pinned to SHA-256; mismatches
  raise `ModelIntegrityError` and the partial file is deleted.

### Fixed
- Path traversal in seven `/api/...` endpoints (any route taking a
  `<filename>`). New `_safe_filename()` guard rejects anything that
  isn't a plain basename.
- Flask `debug=True` is no longer the default in the dev launcher.
  Opt in with `KEEPERS_DEBUG=1`.

## [1.2.0] - 2026-02-18

### Added
- **Onboarding Wizard**: Step-by-step flow with progressive disclosure
  - Step 1: Select Photos - Directory browser with real-time photo count preview
  - Step 2: Configure - Quality threshold presets (Strict/Balanced/Lenient/Custom)
  - Step 3: Review - Summary of photos found, estimated time, previous session detection
- **Directory Preview API**: `/api/preview` endpoint returning photo count by format, estimated processing time
- **Resume Detection**: Shows count of previously scored photos, reminds user about "Force Re-score" option
- **Threshold Presets**: Quick-select buttons with descriptive labels instead of raw slider only
  - Strict (0.8): "Top 20%" - Only best photos
  - Balanced (0.7): "Recommended" - Default selection
  - Lenient (0.5): "Keep More" - Inclusive selection
  - Custom: Reveals manual slider
- **Organization Persistence**: Manual folder placements saved to `organization.json`
  - Resume session preserves manual moves (photos stay in user-selected folders)
  - "Continue Session" option restores previous organization
  - "Start Fresh" clears all manual overrides and re-classifies from scores

### Changed
- Onboarding UX improved with 3-step wizard instead of single form
- Header simplified: "Start" button moved to Review step, "New Session" only shown after processing
- Mobile responsiveness: Wizard steps collapse to numbered indicators on small screens
- Resume flow now explicitly asks "Continue or Start Fresh?" with clear choice cards

### Fixed
- Manual photo organization now persists across sessions (was lost on resume)
- Resuming no longer re-classifies manually moved photos

## [1.1.0] - 2025-02-18 **STABLE**

### Added
- **Scene-Dependent Scoring Profiles**: Automatic scene classification (Portrait, Group, Macro, Landscape, Action) via CLIP zero-shot classification
- **Dynamic Weight Profiles**: Each scene type has specialized scoring weights:
  - Portrait: 50% Face Sharp, 20% Emotion, 20% Composition, 10% Color (strict blink veto)
  - Group: 40% Group Joy, 30% Focus Consistency, 20% Exposure, 10% Composition
  - Macro: 60% Global Sharp, 30% Lighting/Texture, 10% Color (face detection disabled)
  - Landscape: 40% Dynamic Range, 40% Composition, 20% Global Sharp (emotion disabled)
  - Action: 35% Composition, 30% Exposure, 20% Motion Quality, 15% Color (blur tolerance)
- **Manual Scene Override**: Dropdown in UI sidebar to manually override scene classification with instant re-calculation
- **Multi-Face Analysis**:
  - Detects up to 5 faces per image using MediaPipe FaceLandmarker
  - Blink detection using Eye Aspect Ratio (EAR)
  - Depth priority weighting (faces closer to center/larger have higher weight)
  - Group emotion aggregation (social bonus +20% if everyone smiling with 3+ faces)
  - Quality anchor boost when primary subject is smiling deeply
- **Bokeh-Aware Sharpness Measurement**:
  - Top-K Percentile Laplacian: measures only top 5% strongest edges, ignores bokeh areas
  - Signal-to-noise refinement: applies `cv2.medianBlur(3)` before Laplacian to filter digital noise
  - Eye-micro sharpness: uses MediaPipe landmarks to extract tight crops around eyes and eyelashes
  - Shallow DOF detection: auto-lowers sharpness threshold when `mean_ratio > 3.0`
  - Resolution-independent normalization: peak values normalized relative to expected edge strength
- **API Endpoints**:
  - `/api/rescore/<filename>`: Re-score a single photo with optional scene override
  - `/api/facecrop/<filename>/<face_index>`: Get individual face crop thumbnail
- **UI Enhancements**:
  - Scene Classification section in sidebar showing detected scene, active profile, and override dropdown
  - Face Gallery showing all detected faces with thumbnails
  - Group Analysis panel for multi-face photos
  - "Force Re-score" checkbox to re-process all photos with new algorithms
  - AI reasoning now includes scene-specific and bokeh-related justifications

### Changed
- Sharpness measurement refactored from global Laplacian variance to top-K percentile approach
- Face sharpness now weighted 85% eye-micro sharpness + 15% face sharpness
- `detect_bokeh_presence()` now returns 3 values: `bokeh_score`, `variance_ratio`, `mean_ratio`
- Score breakdown now includes: `bokeh_score`, `variance_ratio`, `mean_ratio`, `group_boost_factor`, `detected_scene`, `scoring_profile`
- Threshold relaxation applied for bokeh/shallow DOF shots when faces detected

### Fixed
- Face detection now works correctly (was returning no faces due to outdated scores.json)
- Scene classification improved to use face detection as primary signal (3+ faces → Group, 1-2 faces → Portrait)

## [1.0.0] - 2025-02-17

### Added
- Initial release
- Multi-model scoring combining CLIP (45%), LAION Aesthetics (25%), Technical Quality (30%)
- Face detection with MediaPipe FaceLandmarker (468-point landmarks)
- Emotion bonus for smiling/laughing faces (up to +10%)
- Eye contact detection and bonus (up to +8%)
- Interactive Workspace with gallery grid and keyboard navigation
- Folder management with symlink organization (Top Picks, Moments, Review, Trash)
- RAW file support: ORF, NEF, DNG, CR2, CR3, ARW, RW2, RAF
- Standard format support: JPG, JPEG, PNG, WebP, BMP, TIFF, GIF
- Parallel processing with ThreadPoolExecutor
- Web interface with Flask
- Emotion rescue: relaxes sharpness penalty when emotion_score > 0.9
