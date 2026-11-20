#!/usr/bin/env python3
"""Reject required Wallet imports that can prevent an iOS app launching on Mac.

Usage: python3 dev/scripts/check-wallet-linkage.py path/to/Actuali.app
Run against a device build (Debug or Release), not a simulator build. This checks
both the executable and Debug's separate dylib, plus embedded app extensions.
"""

import argparse
from pathlib import Path
import plistlib
import subprocess
import sys


def check(app: Path) -> int:
    required = []
    checked = 0
    bundles = [app, *sorted(app.rglob("*.appex"))]
    for bundle in bundles:
        with (bundle / "Info.plist").open("rb") as info:
            executable = plistlib.load(info)["CFBundleExecutable"]
        for binary in [bundle / executable, *sorted(bundle.glob("*.debug.dylib"))]:
            output = subprocess.check_output(
                ["xcrun", "nm", "-m", str(binary)], text=True
            )
            for line in output.splitlines():
                if "(undefined)" not in line:
                    continue
                if not any(
                    f"(from {framework})" in line
                    for framework in ("FinanceKit", "FinanceKitUI")
                ):
                    continue
                checked += 1
                if "weak external" not in line:
                    required.append(f"{binary.relative_to(app)}: {line.strip()}")

    if required:
        print("FAIL: required Wallet imports can abort iOS-on-Mac startup:")
        print("\n".join(required))
        return 1
    if not checked:
        print("FAIL: no Wallet imports found; check the supplied build artifact.")
        return 1
    print(f"PASS: all {checked} Wallet imports are weak.")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    sys.exit(check(args.app.resolve()))
