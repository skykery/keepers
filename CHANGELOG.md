# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Add new entries under **[Unreleased]**. `scripts/bump.sh` promotes that
section to a dated version heading at release time — there is no manual
step for that.

## [Unreleased]

### Changed
- Test files moved from the repo root into `tests/`. Run with
  `python -m unittest discover -s tests`.

### Fixed
- `setup.py` now monkey-patches macholib's `synchronize_size` so MediaPipe's
  `libmediapipe.dylib` doesn't fail py2app with
  "New Mach-O header is too large to relocate ... delta=56". The overflow
  fits in page-alignment padding that the original check refuses to use.

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
