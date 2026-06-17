# Scoring system

Keepers ranks each photo with a composite score in `[0, 1]`. The score blends what's in the picture (CLIP semantics), how it looks (LAION aesthetics), how it was captured (technical metrics), and — when people are present — how the faces look (sharpness, eyes, emotion). A scene-aware profile re-weights everything depending on whether the shot is a portrait, group, macro, landscape, or action frame.

## Final score formula

```
base_weighted_score = (clip_score × 0.45)
                    + (aesthetic_score × 0.25)
                    + (technical_score × 0.30)

combined_score = (base_weighted_score
                 + emotion_bonus × 1.5
                 + eye_contact_bonus) × adjusted_sharpness_penalty
```

### Veto logic

| Condition | Effect |
|-----------|--------|
| `sharpness < 0.25` | `sharpness_penalty = sharpness / 0.25` |
| `emotion_score > 0.9` | Sharpness penalty relaxed by 50% |
| `overexposed_prob > 0.4` or `underexposed_prob > 0.4` | `final_score = min(final_score, 0.3)` |

## Scene-dependent profiles

The scene classifier picks one of five profiles per photo. Each rebalances the weights and tweaks the veto rules.

| Scene Type   | Detection                       | Priority Weights                                                | Special Handling                |
|--------------|---------------------------------|-----------------------------------------------------------------|---------------------------------|
| **Portrait** | Single person, close-up         | 50% Face Sharp · 20% Emotion · 20% Composition · 10% Color      | Strict blink veto               |
| **Group**    | 3+ people, events               | 40% Group Joy · 30% Focus Consistency · 20% Exposure · 10% Comp | Relaxed sharpness on joy        |
| **Macro**    | Small objects, textures         | 60% Global Sharp · 30% Lighting/Texture · 10% Color             | Full-frame focus detection      |
| **Landscape**| Wide shots, no people           | 40% Dynamic Range · 40% Composition · 20% Global Sharp          | Face/emotion disabled           |
| **Action**   | Motion, sports                  | 35% Composition · 30% Exposure · 20% Motion Quality · 15% Color | Motion blur tolerance           |

### Contextual veto adjustments

- **Portrait**: Harsh blink detection — images with the subject blinking are heavily penalized.
- **Action**: Sharpness penalty reduced by 60% to allow artistic motion blur.
- **Group**: Sharpness threshold relaxed by 30% when everyone is smiling.
- **Macro**: Sharpness measured across the entire frame to find the focus point.

Users can override the detected scene in the inspection sidebar; the score recomputes instantly.

## CLIP score (45%)

Contrastive pairs of positive and negative prompts, one pair per quality category:

| Category    | Positive                            | Negative                       | Weight |
|-------------|-------------------------------------|--------------------------------|--------|
| Focus       | "tack sharp image"                  | "out of focus blurry photo"    | 25%    |
| Exposure    | "perfectly exposed photograph"      | "overexposed", "underexposed"  | 25%    |
| Composition | "rule of thirds composition"        | "poorly composed snapshot"     | 15%    |
| Lighting    | "photograph with perfect lighting"  | "dark muddy unclear"           | 15%    |
| Color       | "vibrant colors and contrast"       | "washed out faded"             | 10%    |
| Quality     | "masterpiece with detail"           | "grainy noisy low quality"     | 10%    |

Per-category score = `positive_prob / (positive_prob + negative_prob)`.

## Aesthetic score (25%)

LAION Aesthetics Predictor — CLIP ViT-L/14 features fed into a small MLP trained on human aesthetic ratings.

## Technical score (30%)

| Metric         | How it's computed                                                              |
|----------------|--------------------------------------------------------------------------------|
| Sharpness      | **Top-K percentile Laplacian** — only the top 5% strongest edges contribute.   |
| Face sharpness | **Eye-micro weighted** — 85% eye sharpness + 15% face sharpness.               |
| Exposure       | RAW: histogram analysis. JPEG: brightness deviation.                            |
| Contrast       | Standard deviation of luminance.                                                |
| Color richness | Variance across RGB channels.                                                   |
| Composition    | Rule of thirds analysis.                                                        |

### Wide-aperture (bokeh / DOF) handling

The sharpness algorithm is tuned for f/1.4–f/2.8 shots so background blur isn't mistaken for soft focus:

1. **Top-K percentile detection**: only the top 5% strongest Laplacian responses count, ignoring bokeh areas.
2. **Signal-to-noise refinement**: `cv2.medianBlur(3)` is applied before the Laplacian to filter sensor noise.
3. **Eye-micro sharpness**: MediaPipe landmarks crop tight regions around eyes and eyelashes for precise focus measurement.
4. **Contrast weighting**: the result is multiplied by local contrast ratio to distinguish edges from noise.
5. **Shallow-DOF detection**: when `mean_ratio > 3.0` (peak vs. global mean), the sharpness threshold auto-relaxes.
6. **Resolution-independent**: peak values are normalized against an expected edge strength (50.0 = perfect sharpness).

Breakdown fields exposed in the UI: `bokeh_score`, `variance_ratio`, `mean_ratio`, `bokeh_threshold_relaxed`.

## Face detection & emotion bonus

- MediaPipe FaceLandmarker provides 468-point landmarks.
- When faces are detected, `face_sharpness` replaces global `sharpness` in scoring.
- Emotion bonus: up to **+10%** for smiling/laughing faces, detected via the CLIP emotion category.
- Emotion rescue: if `emotion_score > 0.9`, sharpness penalty is relaxed by 50%.
- Eye-contact bonus: up to **+8%** when subjects look at the camera.

## Multi-face analysis (group photos)

- Up to **5 faces** detected per image.
- **Blink detection** via Eye Aspect Ratio (EAR = eye_height / eye_width). EAR < 0.35 indicates a blink; `blink_score = 1.0 - (EAR / 0.35)` per eye.
- **Depth-priority sharpness**: per-face weight = `center_proximity × 0.6 + min(1.0, relative_size × 50) × 0.4`. Faces nearer the center and larger weigh more.
- **Group emotion aggregation**:
  - +20% social bonus if everyone is smiling and `face_count ≥ 3`.
  - +15% social bonus if everyone is smiling and `face_count = 2`.

### Nonlinear social scaling

For group photos with strong emotional content, technical penalties soften:

1. **Social multiplier**: `face_count > 2` + everyone smiling → 1.2× multiplier on base score.
2. **Dynamic sharpness threshold**: `group_joy_score > 0.85` → sharpness threshold reduced by 30%.
3. **Quality anchor boost**: primary subject (largest/central face) smiling deeply (>0.7) → surrounding faces boosted.
4. **Technical penalty reduction**: `face_count ≥ 3` with high joy → technical penalties weighted at 70%.
5. **Group emotion rescue**: sharpness penalty relaxed by 40% for high-joy group photos.

The cumulative effect is reported in `breakdown.group_boost_factor`.

#### Example

A group photo with 3 smiling faces but soft focus:

- Old logic: score ~0.38 (heavily penalized for softness).
- New logic: score ~0.90 (emotion prioritized over technical perfection).

### Blink penalty and primary subjects

- Blink penalty applies when any face has `blink_score > 0.7`: `blink_penalty = 1.0 - (max_blink_risk - 0.7) × 0.5`.
- Primary subjects = top 1/3 of faces by center proximity. They must have `sharpness > 0.4` to avoid the blur penalty.
- The face gallery in the UI shows red borders for blink risk or look-away, green borders for high emotion.

## Models

| Model                  | Repo / file                                                                | Size    |
|------------------------|----------------------------------------------------------------------------|---------|
| CLIP ViT-B/32          | `openai/clip-vit-base-patch32`                                             | ~150 MB |
| CLIP ViT-L/14          | `openai/clip-vit-large-patch14`                                            | ~890 MB |
| LAION Aesthetics       | `sac+logos+ava1-l14-linearMSE.pth`                                         | ~4 MB   |
| MediaPipe FaceLandmark | `face_landmarker.task` (float16)                                           | ~4 MB   |

Downloaded once on first launch into `~/Library/Application Support/Keepers/models/`.
