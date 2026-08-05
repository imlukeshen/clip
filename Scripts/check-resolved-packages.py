#!/usr/bin/env python3
"""Verify the canonical Xcode lock and every tracked Swift dependency pin."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "Scripts" / "allowed-resolved-packages.txt"
CANONICAL_LOCK = ROOT / "App" / "Clip.Package.resolved"


def packages_in(paths: list[Path]) -> set[str]:
    packages: set[str] = set()
    for path in paths:
        document = json.loads(path.read_text(encoding="utf-8"))
        for pin in document.get("pins", []):
            state = pin["state"]
            version = state.get("version", "")
            revision = state.get("revision", "")
            if not revision:
                raise RuntimeError(f"{path} has an unresolved pin for {pin['identity']}")
            packages.add(
                f"{pin['identity']}|{pin['location']}|{version}|{revision}"
            )
    return packages


def tracked_lockfiles() -> list[Path]:
    output = subprocess.check_output(
        ["git", "ls-files", "*Package.resolved"],
        cwd=ROOT,
        text=True,
    )
    paths = [ROOT / line for line in output.splitlines() if line]
    if not paths:
        raise RuntimeError("No tracked Package.resolved files were found")
    return paths


def allowed_packages() -> set[str]:
    return {
        line.strip()
        for line in ALLOWLIST.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def report(title: str, packages: set[str]) -> None:
    if packages:
        print(title, file=sys.stderr)
        for package in sorted(packages):
            print(package, file=sys.stderr)


def main() -> int:
    if not CANONICAL_LOCK.is_file():
        raise RuntimeError(f"Canonical Xcode lockfile is missing: {CANONICAL_LOCK}")

    actual = packages_in(tracked_lockfiles())
    canonical = packages_in([CANONICAL_LOCK])
    allowed = allowed_packages()
    unexpected = (actual | canonical) - allowed
    missing = allowed - canonical
    report("Unreviewed resolved Swift packages:", unexpected)
    report("Approved packages missing from the canonical Xcode lockfile:", missing)
    return 1 if unexpected or missing else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, KeyError, ValueError, RuntimeError) as error:
        print(f"Could not audit Swift lockfiles: {error}", file=sys.stderr)
        raise SystemExit(1) from error
