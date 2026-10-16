# Roadmap

Ideas for Keepers after 2.0, grouped by theme and roughly ordered by value within each group. Size is a rough effort guess: **S** a day or less, **M** a few days, **L** a week or more.

When an item ships, move it to `CHANGELOG.md` and delete it here.

## Distribution and polish

| Feature | Why | Size |
|---|---|---|
| Publish the Homebrew tap | `packaging/homebrew/keepers.rb` is ready; it needs a `skykery/homebrew-keepers` repo, and its version and checksum updated after each release. | S |
| Aesthetics on macOS 13–14 | Those systems score without aesthetics. Either host the Core ML model (`scripts/convert_aesthetics_model.py`) as a release asset with a checksummed download, or raise the minimum to macOS 15. Needs a decision. | M |
| Translations | View text is in `App/Localizable.xcstrings` (sync with `scripts/update_strings.py`). Decision reasons and alerts are built in code and need to become localizable strings first. | M |
| Sandbox and Mac App Store | Needs security-scoped bookmarks for writing next to originals, and an App Store Connect setup. Opens the App Store channel and stronger isolation. | L |
| Keyboard focus | VoiceOver labels are done; full keyboard focus navigation (Tab through controls) isn't. | S |
