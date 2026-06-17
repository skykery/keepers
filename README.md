# Keepers

**Find your best shots, automatically.**

Keepers is a Mac app that ranks every photo in a folder using on-device AI — CLIP, LAION Aesthetics, sharpness, exposure, face detection, and emotion — then helps you pick the keepers with a few keystrokes.

Built for photographers who come back from a shoot with 400 frames and need to find the 20 worth showing.

- **100% local.** Nothing uploads. Your photos never leave your Mac.
- **Apple Silicon accelerated** via PyTorch MPS.
- **RAW-aware**: ORF, NEF, DNG, CR2, CR3, ARW, RW2, RAF, plus JPG/PNG/WebP/TIFF/BMP/GIF.
- **Originals are never modified.** Output folders are symlinks back to your source files.

## Install

### Homebrew (coming soon)

```bash
brew install --cask skykery/keepers/keepers
```

### From source

```bash
git clone https://github.com/skykery/keepers.git
cd keepers
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
./venv/bin/python app.py
```

On first launch, Keepers downloads ~1 GB of AI models into `~/Library/Application Support/Keepers/models/`. This happens once.

## Quick start

1. Click **Browse…** to pick a folder of photos.
2. Pick a threshold preset — *Strict*, *Balanced*, or *Lenient*.
3. Click **Start culling**. Wait while scores are computed.
4. Walk through the gallery and tag each photo with one keystroke.

Photos land in four sibling folders next to your source folder:

```
Top Picks/   — your keepers
Moments/     — photos rescued by emotion/eye-contact (great expressions, technically softer)
Review/      — borderline; worth a second look
Trash/       — technical failures
```

Each folder contains symlinks back to the originals. Drag a symlink out (to Lightroom, iCloud, a thumb drive) and macOS gives you the real file, not the shortcut.

## Keyboard shortcuts

| Key            | Action                       |
|----------------|------------------------------|
| `←` `→`        | Previous / next photo        |
| `Enter`        | Open inspection sidebar      |
| `P` or `1`     | Move to **Top Picks**        |
| `M` or `3`     | Move to **Moments**          |
| `R` or `2`     | Move to **Review**           |
| `X` or `Delete`| Move to **Trash**            |
| `Esc`          | Close sidebar                |

## How the scoring works

Short answer: a weighted blend of CLIP semantic scores (45%), LAION aesthetics (25%), and technical metrics (30%) — adjusted by face detection, emotion, and the detected scene type (portrait / group / macro / landscape / action).

Long answer with formulas, weights, and the bokeh / group-photo special cases: [`docs/SCORING.md`](docs/SCORING.md).

## Development

```bash
./venv/bin/python -m unittest discover -s tests -v  # run tests
./venv/bin/python webapp.py                      # run as a browser app on :5000
./venv/bin/python app.py                         # run as the native window
```

Build a signed .dmg (requires an Apple Developer account):

```bash
scripts/build_dmg.sh
```

See [`CHANGELOG.md`](CHANGELOG.md) for release history.

## Privacy

- No telemetry. No analytics. No accounts.
- Models are downloaded from HuggingFace and GitHub on first launch, then run entirely offline.
- The app never reads, copies, or transmits image data anywhere outside your machine.

## License

[AGPL-3.0](LICENSE) © 2026 Alin Banuta
