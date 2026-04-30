from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import time
from pathlib import Path


EXCLUDED_TOP_LEVEL_NAMES = {
    ".pytest_cache",
    ".venv",
    "HANDOFF-2026-04-01.md",
    "dist",
    "live-repeat-output",
    "live-repeat-sample.html",
    "live-repeat-sample.png",
    "mineru..env",
}
EXCLUDED_ANYWHERE_NAMES = {"__pycache__"}
EXCLUDED_SUFFIXES = {".pyc", ".pyo"}
SAFE_IN_TREE_DESTINATIONS = {"dist"}


def should_exclude(path: Path, source_root: Path) -> bool:
    relative_parts = path.relative_to(source_root).parts
    if not relative_parts:
        return False
    if relative_parts[0] in EXCLUDED_TOP_LEVEL_NAMES:
        return True
    return (
        any(part in EXCLUDED_ANYWHERE_NAMES for part in relative_parts)
        or path.suffix in EXCLUDED_SUFFIXES
    )


def _reset_destination(
    path: Path, retries: int = 3, delay_seconds: float = 0.2
) -> None:
    if not path.exists():
        return
    last_error: PermissionError | None = None
    for attempt in range(retries):
        try:
            shutil.rmtree(path)
            return
        except PermissionError as exc:
            last_error = exc
            if attempt == retries - 1:
                break
            time.sleep(delay_seconds)
    if os.name == "nt" and path.exists():
        escaped = str(path).replace("'", "''")
        subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-Command",
                f"if (Test-Path -LiteralPath '{escaped}') {{ Remove-Item -LiteralPath '{escaped}' -Recurse -Force }}",
            ],
            check=True,
        )
        if not path.exists():
            return
    if last_error is not None:
        raise last_error


def build_distribution_tree(source_root: Path, destination: Path) -> Path:
    source_root = source_root.resolve()
    destination = destination.resolve()

    if destination == source_root:
        raise ValueError("destination must not be the source root")
    if destination in source_root.parents:
        raise ValueError("destination must not be an ancestor of the source root")

    try:
        relative_destination = destination.relative_to(source_root)
    except ValueError:
        relative_destination = None
    if relative_destination is not None:
        first_part = relative_destination.parts[0] if relative_destination.parts else ""
        if first_part not in SAFE_IN_TREE_DESTINATIONS:
            raise ValueError(
                "destination inside source root is only supported under safe staging directories"
            )

    if destination.exists():
        _reset_destination(destination)
    destination.mkdir(parents=True, exist_ok=True)

    for path in sorted(source_root.rglob("*")):
        if should_exclude(path, source_root):
            continue
        relative = path.relative_to(source_root)
        target = destination / relative
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)

    return destination


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a filtered staging copy for skill packaging."
    )
    parser.add_argument(
        "destination", help="Destination directory for the staged skill"
    )
    parser.add_argument(
        "--source-root",
        default=Path(__file__).resolve().parents[1],
        help="Skill root to stage (defaults to this script's parent skill directory)",
    )
    args = parser.parse_args()

    staged = build_distribution_tree(Path(args.source_root), Path(args.destination))
    print(staged)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
