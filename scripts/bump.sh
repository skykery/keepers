#!/usr/bin/env bash
# Bump the version, promote CHANGELOG [Unreleased] to a dated heading,
# commit, and tag. Push with `git push --follow-tags` to trigger release.
#
# Usage:
#   scripts/bump.sh patch     # 1.2.0 -> 1.2.1
#   scripts/bump.sh minor     # 1.2.0 -> 1.3.0
#   scripts/bump.sh major     # 1.2.0 -> 2.0.0
#   scripts/bump.sh 1.5.0     # explicit
#
# Refuses to run on a dirty working tree or off the main branch.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <patch|minor|major|X.Y.Z>" >&2
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "Refusing to bump: working tree is dirty." >&2
    git status --short >&2
    exit 1
fi

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" != "main" ]]; then
    echo "Refusing to bump: must run on main (currently on $branch)." >&2
    exit 1
fi

current="$(tr -d '[:space:]' < VERSION)"
IFS='.' read -r MAJ MIN PATCH <<< "$current"

case "$1" in
    patch) new="${MAJ}.${MIN}.$((PATCH + 1))" ;;
    minor) new="${MAJ}.$((MIN + 1)).0" ;;
    major) new="$((MAJ + 1)).0.0" ;;
    [0-9]*.[0-9]*.[0-9]*) new="$1" ;;
    *)
        echo "invalid bump kind: $1" >&2
        exit 1
        ;;
esac

if grep -q "^## \[${new}\]" CHANGELOG.md; then
    echo "CHANGELOG already has a [${new}] section. Aborting." >&2
    exit 1
fi

today="$(date -u +%Y-%m-%d)"

echo "Bumping ${current} -> ${new} (release date ${today})"
echo "$new" > VERSION

# Promote [Unreleased] -> [new] - today, then re-add an empty [Unreleased].
python3 - "$new" "$today" <<'PY'
import re, sys
new, today = sys.argv[1], sys.argv[2]
text = open("CHANGELOG.md").read()
if "## [Unreleased]" not in text:
    sys.exit("CHANGELOG.md is missing the [Unreleased] section")
empty_unreleased = (
    "## [Unreleased]\n"
    "\n"
    "### Added\n"
    "\n"
    "### Changed\n"
    "\n"
    "### Fixed\n"
    "\n"
)
text = text.replace(
    "## [Unreleased]",
    empty_unreleased + f"## [{new}] - {today}",
    1,
)
# Strip the three empty subheadings the user never wrote into.
text = re.sub(
    r"(## \[" + re.escape(new) + r"\] - " + today + r")\n+### Added\n+### Changed\n+### Fixed\n+",
    r"\1\n\n",
    text,
)
open("CHANGELOG.md", "w").write(text)
PY

git add VERSION CHANGELOG.md
git commit -m "Release v${new}"
git tag -a "v${new}" -m "Release v${new}"

echo ""
echo "Tagged v${new}. To trigger the release workflow:"
echo "  git push --follow-tags"
