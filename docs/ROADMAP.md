# Roadmap

Ideas for Keepers after 2.0, grouped by theme and roughly ordered by value within each group. Size is a rough effort guess: **S** a day or less, **M** a few days, **L** a week or more.

When an item ships, move it to `CHANGELOG.md` and delete it here.

## Smarter culling

Situations the current engine handles wrongly or not at all.

| Feature | Why | Size |
|---|---|---|
| Exposure brackets | HDR brackets (same scene, ±2 EV) look like blown and black frames and get trashed. Detect them by EXIF exposure bias and timing, keep them together, and skip the exposure gate. | M |
| Pets and wildlife | Vision's animal recognizer finds cats and dogs; measure sharpness on them like on faces. Birds and other wildlife need more: saliency already finds them, but a dedicated detector (a small Core ML model) would locate the eye. | M |
| Camera focus point | Many RAW files record the autofocus point in their maker notes. Measuring sharpness where the camera focused beats guessing the subject. Coverage varies by brand; start with Nikon, Canon, Sony. | L |
| Intentional low-key / high-key | A deliberately dark or bright photo can fail the exposure gate. Use aesthetics to tell intent from mistake before trashing. | M |
| Panning and motion blur | A sharp subject on a streaked background is good technique, not a miss. Detect directional background blur and relax the gate when the subject is sharp. | M |
| Panorama sequences | Overlapping frames shot for stitching look like a burst and lose all but one frame. Detect the sideways overlap and keep the set together. | M |
| Group photo check | For group shots, list every face with eyes open/closed and pick the frame where everyone's eyes are open, rather than ranking on the main face alone. | M |

## Learning your taste

The engine's weights are hand-set and were calibrated on 33 photos.

| Feature | Why | Size |
|---|---|---|
| Learn from manual moves | Every move by hand is stored in `placements.json`. After a few shoots, fit the scoring weights to your choices (a small regression on signals already measured), with a switch to reset to defaults. | L |
| Custom share | Old 1.x had a custom slider. Add "Custom…" to the presets: a Top Picks percentage and frames kept per group. | S |
| Fix grouping by hand | Merge two groups or split one when the burst grouping gets it wrong (a fast pan, two scenes seconds apart). | M |
| Calibration suite | A labeled set of real shoots and a `keepers-eval` regression check in CI, so tuning changes are measured instead of eyeballed. | M |

## Working with other apps

Symlink folders work everywhere, but photographers live in Lightroom and Capture One.

| Feature | Why | Size |
|---|---|---|
| Ratings in XMP sidecars | Write star ratings, pick/reject flags, and color labels to `.xmp` sidecars (and embedded XMP for JPEG/HEIC). Lightroom, Capture One, and Bridge read them on import: cull in Keepers, edit there. | M |
| Export picks | Copy or move Top Picks (and optionally Moments) to a chosen folder, with RAW+JPEG pairs kept together. Symlinks don't survive every upload or sync tool. | S |
| Send Trash to the macOS Trash | After review, move the originals behind Trash to the macOS Trash, with a confirmation that lists counts and size. Recoverable from Finder. | S |
| Finder Quick Action | "Cull with Keepers" when right-clicking a folder. | S |
| Import from card | Detect an inserted SD card, copy the shoot to a chosen folder, and start analysis while copying. | L |

## Distribution and polish

| Feature | Why | Size |
|---|---|---|
| Update notifications | Nothing tells 2.0 users that 2.1 exists. Add an opt-in check against GitHub Releases (Keepers otherwise makes no network requests) or Sparkle. | M |
| Homebrew cask | The 1.x README promised `brew install --cask`; it was never published. | S |
| Aesthetics on macOS 13–14 | Those systems score without aesthetics. Either host the Core ML model (`scripts/convert_aesthetics_model.py`) as a release asset with a checksummed download, or raise the minimum to macOS 15. | M |
| Subfolder support | Scan a shoot's subfolders (one per card or per day) as one session. | M |
| VoiceOver and keyboard focus | Grid cells, badges, and signal bars have no accessibility labels. | M |
| Localization | Strings are English-only and inline. Move them to a String Catalog. | M |
| Sandbox and Mac App Store | Needs security-scoped bookmarks for writing next to originals. Opens the App Store channel and stronger isolation. | L |
| Migrate 1.x manual placements | 1.x `organization.json` mixes automatic and manual entries. Offer to import it once as manual placements, for users upgrading mid-project. | S |
