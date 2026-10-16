# Keepers

**Find your best shots, automatically.**

Keepers is a native Mac app that ranks every photo in a folder with Apple's on-device Vision framework (sharpness on the subject, exposure, aesthetics, faces, closed eyes, smiles, near-duplicates), then helps you pick the keepers with a few keystrokes.

Built for photographers who come back from a shoot with 400 frames and need to find the 20 worth showing.

- **100% local.** Nothing uploads, nothing downloads. Your photos never leave your Mac.
- **One universal app** for Apple Silicon and Intel, about 3 MB. No Python, no model downloads.
- **RAW-aware**: ORF, NEF, DNG, CR2, CR3, ARW, RW2, RAF, plus JPG/HEIC/PNG/WebP/TIFF/BMP/GIF. RAW+JPEG pairs count as one photo.
- **Bursts collapse.** Ten frames of the same moment yield one pick, and the rest are ranked next to it.
- **Originals are never modified.** Output folders contain symlinks back to your source files.

Requires macOS 13 or later. Aesthetics scoring uses Vision's built-in model on macOS 15+; on 13–14 Keepers scores without it unless the optional model is installed (see [`docs/SCORING.md`](docs/SCORING.md#aesthetics)).

## Install

Download the latest `.dmg` from [Releases](https://github.com/skykery/keepers/releases) and drag Keepers to Applications.

## Quick start

1. Choose (or drop) a folder of photos.
2. Pick how selective to be: *Strict* (top 5%), *Balanced* (top 10%), or *Lenient* (top 20%).
3. Click **Start Culling**. Analysis runs at a few photos per second.
4. Walk through the folders and move photos with one keystroke.

Photos land in four folders inside your source folder:

```
Top Picks/   — the best frame of the strongest moments
Moments/     — great expressions (smiling, eyes open) from moments that didn't make Top Picks
Review/      — everything else, with similar shots grouped and ranked
Trash/       — clear technical failures: out of focus, blown out, black
```

Each folder contains symlinks back to the originals. Drag one out (to Lightroom, iCloud, a thumb drive) and macOS gives you the real file, not the shortcut.

Changing the preset later re-sorts instantly, with no re-analysis. Photos you moved by hand stay where you put them.

## Keyboard shortcuts

| Key            | Action                          |
|----------------|---------------------------------|
| `←` `→`        | Previous / next photo           |
| `Return`       | Show / hide the details sidebar |
| `P` or `1`     | Move to **Top Picks**           |
| `R` or `2`     | Move to **Review**              |
| `M` or `3`     | Move to **Moments**             |
| `X` or `Delete`| Move to **Trash**               |
| `U` or `0`     | Back to the automatic folder    |
| `Esc`          | Close the sidebar               |
| `⌘O`           | Open another folder             |

## How the scoring works

Short version: clear failures go to Trash; everything else gets a quality score (subject sharpness 35%, exposure 20%, aesthetics 45%). Similar shots are grouped by capture time and visual similarity, and only the best frame of each group can be a Top Pick.

Full details: [`docs/SCORING.md`](docs/SCORING.md).

## Development

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen                                   # generate Keepers.xcodeproj
open Keepers.xcodeproj                     # run the app from Xcode
swift test --package-path KeepersCore      # run the engine tests
```

The engine lives in the `KeepersCore` Swift package; the SwiftUI app in `App/`. To see what the engine decides for a folder without the UI:

```bash
swift run -c release --package-path KeepersCore keepers-eval ~/Pictures/shoot --signals
```

It prints every signal and decision, and, if you've moved photos by hand in the app, how often the engine agrees with you.

Build a signed universal `.app` (requires an Apple Developer ID; use `-` for a local ad-hoc build):

```bash
DEVELOPER_ID=- scripts/build_and_sign.sh
```

Releases: [`docs/RELEASING.md`](docs/RELEASING.md). History: [`CHANGELOG.md`](CHANGELOG.md).

## Privacy

- No telemetry. No analytics. No accounts. No network access.
- All analysis runs on your Mac with Apple's Vision and Core Image frameworks.
- Keepers writes only inside the folder you choose: the four output folders and a `.keepers/` cache.

## License

[AGPL-3.0](LICENSE) © 2026 Alin Banuta
