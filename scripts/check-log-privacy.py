#!/usr/bin/env python3
"""Flags values that may carry personal data but are logged with
`privacy: .public` (docs/PRIVACY.md; audit 2026-10-23, M12·M13).

Personal data here: Mac paths (they contain the account name), file and folder
names, system error descriptions (they quote file names), and device IDs (they
contain the USB serial number). Such values belong in `.private` (or
`.private(mask: .hash)` for IDs); `error.publicSummary` and
`DeviceError.logDetail` are the public-safe forms.

A line whose public value is safe by design (for example a mount path under
/Volumes, which holds only the ASCII model name, D31) carries a
`log-privacy: public-ok` comment on that line or the line above.

Runs outside the app sandbox, like check-localization.py.
Usage: python3 scripts/check-log-privacy.py
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
targets = ["PhoneBridge", "PhoneBridgeFinder", "PhoneBridgeUnmounter", "Shared"]
# One interpolation: `\(value, privacy: .public)` with no other `\(` inside.
public_value = re.compile(r'\\\(((?:(?!\\\().)*?), privacy: \.public\)')
risky = re.compile(
    r'localizedDescription|technicalDetail|socketPath|homeDirectory'
    r'|\.path\b|\bpath\b|\burl\b|\bfolder\b|\bitem\b|\bdeviceID\b|\bid\b'
    r'|\bentry\.name\b|\bitem\.name\b|\bexisting\.')
marker = "log-privacy: public-ok"

problems = []
for target in targets:
    for path in sorted((root / target).rglob("*.swift")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for number, line in enumerate(lines, start=1):
            if marker in line or (number > 1 and marker in lines[number - 2]):
                continue
            for value in public_value.findall(line):
                if risky.search(value):
                    problems.append(f"{path.relative_to(root)}:{number}: public log value `{value}`")

if problems:
    print("Possibly personal data logged as public:")
    print("\n".join(problems))
    sys.exit(1)
print("OK")
