#!/usr/bin/env python3
"""Checks that every literal key passed to LocalizationManager.t(...) in the app
sources exists in Localizable.xcstrings with both Korean and English values.

Runs outside the app sandbox (the hosted unit tests cannot read source files).
Usage: python3 scripts/check-localization.py
"""
import json
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
catalog = json.loads((root / "PhoneBridge/Localization/Localizable.xcstrings").read_text(encoding="utf-8"))
strings = catalog["strings"]
pattern = re.compile(r'\bt\("([A-Za-z0-9_.]+)"')

used = {}
for path in sorted((root / "PhoneBridge").rglob("*.swift")):
    for key in pattern.findall(path.read_text(encoding="utf-8")):
        used.setdefault(key, path.relative_to(root))

problems = []
for key, path in sorted(used.items()):
    entry = strings.get(key)
    if entry is None:
        problems.append(f"missing key {key!r} (used in {path})")
        continue
    for language in ("ko", "en"):
        value = entry.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", "")
        if not value.strip():
            problems.append(f"{key!r} has no {language} value")

unused = sorted(set(strings) - set(used))
print(f"{len(used)} literal keys used in sources, {len(strings)} keys in catalog")
if unused:
    print("keys not referenced literally (dynamic or stale):")
    for key in unused:
        print(f"  {key}")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("OK")
