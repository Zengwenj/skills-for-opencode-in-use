from __future__ import annotations

import json
import shutil
from dataclasses import dataclass
from pathlib import Path


@dataclass
class OutputTargets:
    markdown: Path
    json_dir: Path | None
    json_files: dict[str, Path]
    images_dir: Path
    stem: str


def _allocate_stem(source_stem: str, used_stems: set[str] | None) -> str:
    if used_stems is None:
        return source_stem
    if source_stem not in used_stems:
        used_stems.add(source_stem)
        return source_stem

    index = 2
    while f"{source_stem}__{index}" in used_stems:
        index += 1
    allocated = f"{source_stem}__{index}"
    used_stems.add(allocated)
    return allocated


def build_output_targets(
    source: Path,
    output_root: Path,
    include_json: bool,
    keep_raw_tree: bool,
    used_stems: set[str] | None = None,
) -> OutputTargets:
    output_root.mkdir(parents=True, exist_ok=True)
    stem = _allocate_stem(source.stem, used_stems)
    json_dir = output_root / f"{stem}.json" if include_json else None
    return OutputTargets(
        markdown=output_root / f"{stem}.md",
        json_dir=json_dir,
        json_files={
            json_type: json_dir / f"{stem}.{json_type}.json"
            for json_type in ("content_list", "content_list_v2", "layout", "model")
        }
        if json_dir is not None
        else {},
        images_dir=output_root / f"{stem}.images",
        stem=stem,
    )


def write_json_file(path: Path, payload: object) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return path


def copy_directory(source: Path, destination: Path) -> None:
    if not source.exists():
        return
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)
