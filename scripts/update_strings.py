#!/usr/bin/env python3
"""Sync App/Localizable.xcstrings with the strings the last build extracted.

Xcode's editor keeps the catalog in sync on its own; command-line builds only
write per-file .stringsdata. Run this after a build to add new strings and
mark ones no longer in the code as stale (translations are never deleted):

    xcodebuild -project Keepers.xcodeproj -scheme Keepers build -derivedDataPath build/DerivedData
    scripts/update_strings.py
"""
import glob
import json
import os
import sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
catalog_path = os.path.join(root, "App", "Localizable.xcstrings")
files = glob.glob(os.path.join(root, "build", "DerivedData", "**", "*.stringsdata"), recursive=True)
if not files:
    sys.exit("No .stringsdata found; build first (see the docstring).")

keys = set()
for path in files:
    with open(path) as f:
        for entry in json.load(f).get("tables", {}).get("Localizable", []):
            keys.add(entry["key"])

with open(catalog_path) as f:
    catalog = json.load(f)
strings = catalog.setdefault("strings", {})
added = [k for k in keys if k not in strings]
for k in added:
    strings[k] = {}
stale = 0
for k, v in strings.items():
    if k in keys:
        v.pop("extractionState", None)
    else:
        v["extractionState"] = "stale"
        stale += 1
catalog["strings"] = dict(sorted(strings.items()))
with open(catalog_path, "w") as f:
    json.dump(catalog, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"{len(keys)} strings in use, {len(added)} added, {stale} stale")
