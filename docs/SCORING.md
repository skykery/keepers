# Scoring

Keepers decides folders in two stages. **Analysis** measures each photo once and caches the numbers in `<folder>/.keepers/analysis.json`. **Culling** turns those numbers into folders. Culling is pure arithmetic, so changing the preset re-sorts instantly.

Code: `KeepersCore/Sources/KeepersCore/` — `Analyzer.swift` (measurement), `Scoring.swift` (per-photo score), `Bursts.swift` (grouping), `Culler.swift` (folders).

## Analysis

Every photo is decoded once at 2048 px on the long edge. RAW files use the camera's embedded preview (about 0.3 s instead of about 9 s for a full RAW develop); a RAW+JPEG pair decodes the JPEG.

| Measurement | How |
|---|---|
| Faces | Vision face detection with *face capture quality* (Apple's combined blur / lighting / pose / expression score). Faces smaller than 6% of the frame height, or under 40% of the largest face, are bystanders and ignored. |
| Smile, closed eyes | Core Image face detector (`CIDetectorSmile`, `CIDetectorEyeBlink`), matched to Vision faces by overlap. |
| Subject | Faces if any; otherwise Vision's attention saliency region; otherwise the central 70%. |
| Focus energy | Gaussian-smoothed Laplacian, variance per tile, 90th-percentile tile (see below). Measured on the eye band of each subject face, else on the subject, and on the whole frame. |
| Exposure | Fraction of pixels with any channel ≥ 250 (blown), fraction ≤ 8 (black), mean luminance of the subject. |
| Aesthetics | macOS 15+: Vision `CalculateImageAestheticsScoresRequest`, `overallScore` mapped from −1…1 to 0…1. |
| Similarity | Vision image feature print, compared by cosine distance. |
| Capture time | EXIF `DateTimeOriginal` + `SubsecTimeOriginal`; file date if missing. |

### Focus energy

A sharp subject against a soft background is the normal case for portraits, so the metric looks for *the sharpest part* of a region rather than an average:

1. 3×3 Gaussian blur so sensor noise doesn't read as detail.
2. Laplacian (edge response).
3. Variance of the Laplacian per tile (tiles of max(16 px, region/8)).
4. The 90th-percentile tile is the region's focus energy.

Eye bands are downscaled to at most 256 px wide first. Without this, a face that fills the frame has its detail spread over more pixels and reads as soft. Regions are never upscaled.

Energy maps to sharpness with `1 − exp(−energy / 18)`: missed focus and motion blur sit under ~5 (sharpness < 0.25), in-focus eyes at 20–45 (0.67–0.92), busy textures like branches at 100+ (≈1). The curve saturates deliberately: past "in focus", more texture doesn't make a better photo.

## Per-photo score

```
quality = (0.35 × sharpness + 0.20 × exposure + 0.45 × aesthetics) / (sum of weights present)
```

Without an aesthetics score (macOS 13–14, no optional model), the remaining weights are renormalized instead of treating aesthetics as zero.

`exposure` is 1 for a well-exposed subject with little clipping. It ramps down as blown highlights go from 2% to 20% of the frame or black pixels from 10% to 50%, and loses up to half when the subject's mean luminance is outside 0.25–0.75.

**Flaws** keep a photo out of Top Picks but don't trash it:

| Flaw | Effect |
|---|---|
| Main subject's eyes closed | quality × 0.7 |
| Someone else in a group shot blinking | quality × 0.85 |

Face capture quality is **not** part of `quality`. Apple designed it for comparing shots of the same person, and it sits near 0.5 for most faces, so as an absolute signal it unfairly penalizes portraits against scenery. It is used to rank frames within a group (below).

## Hard gate → Trash

Only clear technical failures:

| Rule | Reason shown |
|---|---|
| Subject sharpness below the preset floor **and** nothing in the frame above 1.5× that floor | Out of focus |
| More than 25% of pixels blown | Blown highlights |
| More than 60% of pixels black | Severely underexposed |

Vision's `isUtility` flag (screenshots, documents) is recorded but not used: in testing it flagged ordinary still-life photos.

## Groups

Photos are sorted by capture time. Each photo joins the previous one's group when they are at most 1.5 s apart (a burst), or at most 30 s apart and their feature prints are within cosine distance 0.25 (a re-take of the same frame). Within a group, frames rank by `quality + 0.5 × face capture quality`.

## Folders

| Preset | Top Picks share | Pick quality floor | Out-of-focus floor (sharpness) | Frames kept per group | Duplicate gap |
|---|---|---|---|---|---|
| Strict | 5% | 0.50 | 0.30 | 2 | 0.03 |
| Balanced | 15% | 0.42 | 0.20 | 3 | 0.05 |
| Lenient | 25% | 0.35 | 0.12 | 5 | 0.08 |

1. **Trash**: anything failing the gate.
2. **Top Picks**: the best frame of each group, ranked by quality across groups; the top *share × usable photos* (at least 1) that clear the floor and have no flaws.
3. **Moments**: for groups without a pick, the frame with the best face quality where the main subject is smiling, eyes open, face quality ≥ 0.45. Capped at the same count as Top Picks.
4. **Trash, weaker duplicates**: a frame that scores lower than its group's best *and* either ranks beyond the preset's "frames kept per group" or trails the best by the "duplicate gap" or more. Reason: "Weaker duplicate: #5 of 10 similar shots". A frame that ranks lower only because of face quality, but scores at least as high, is never trashed.
5. **Review**: everything else. Reasons show the rank in the group ("#3 of 10 similar shots") or why a group leader missed ("Below the quality bar", "Outranked by other shots").

Folders you choose by hand are stored in `.keepers/placements.json` and always win. Press `U` to hand a photo back to the engine.

## Aesthetics

On macOS 15 and later, aesthetics come from Vision with nothing to install.

On macOS 13–14 the app loads `~/Library/Application Support/Keepers/Models/KeepersAesthetics.mlmodelc` if present: CLIP ViT-B/32 + the LAION aesthetic predictor v1 linear head, built by `scripts/convert_aesthetics_model.py`. Its 1–10 rating maps to 0–1 over the 3.5–7.5 band real photos fall in. Without the model, those systems score on sharpness and exposure only.

## Tuning

`keepers-eval` (see the README) prints every signal per photo. Once you have sorted a few shoots by hand in the app, it also reports how often the engine's folder matches yours, so weight and threshold changes can be judged on real decisions.
