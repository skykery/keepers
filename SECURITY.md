# Security policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue. Email the maintainer at the address listed in the GitHub profile, or use GitHub's private "Report a vulnerability" form on the [Security tab](https://github.com/skykery/keepers/security). I aim to acknowledge reports within 7 days and to ship a fix within 30 days for confirmed issues.

## Threat model

Keepers is a **single-user, local-only Mac app**. The threat model assumes:

- The user runs the app on their own machine.
- The user's photos are not malicious — they're shots from the user's own camera or trusted sources.

Keepers has no server, no local HTTP API, and no network code. It reads the folder the user chooses and writes only inside it (the four output folders and `.keepers/`).

## Hardened runtime

The app is signed with the hardened runtime and **no entitlements**: no JIT, no unsigned executable memory, no disabled library validation, no DYLD environment variables. (The Python version needed all four for PyTorch and MediaPipe; the Swift rewrite dropped them.)

The app is not sandboxed. Sandboxing would require security-scoped bookmarks to write symlinks next to the user's photos; it may come later.

## Image parsing

Images are decoded by Apple's ImageIO and Core Image, including RAW formats, and analyzed by Apple's Vision framework. These are system frameworks and receive security fixes through macOS updates. Keepers bundles no third-party image or ML libraries.

## Models

On macOS 15+ every model is built into macOS. On macOS 13–14 an optional aesthetics model can be installed by hand into `~/Library/Application Support/Keepers/Models/` (see `docs/SCORING.md`); the app never downloads anything.

## Files the app writes

- Symlinks in `Top Picks/`, `Moments/`, `Review/`, `Trash/` inside the chosen folder. The organizer only removes symlinks it finds in those four folders, and never touches regular files there or the originals.
- `.keepers/analysis.json` and `.keepers/placements.json`, written atomically.

## Reviewing the code

The smallest interesting surfaces are:

- `KeepersCore/Sources/KeepersCore/FolderOrganizer.swift` — symlink creation and removal.
- `KeepersCore/Sources/KeepersCore/SessionStore.swift` — what gets written to disk.
- `KeepersCore/Sources/KeepersCore/ImageDecoder.swift` — the entry point for untrusted files.

Independent review is welcome.
