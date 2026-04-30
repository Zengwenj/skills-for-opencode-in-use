from __future__ import annotations

import json
import importlib
import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

from .mineru_outputs import (
    OutputTargets,
    build_output_targets,
    copy_directory,
    write_json_file,
)


def _load_mineru_client():
    try:
        module = importlib.import_module("mineru")
    except ImportError:
        return None
    return getattr(module, "MinerU", None)


MinerUClient = _load_mineru_client()


def _rewrite_markdown_image_paths(markdown: str, stem: str) -> str:
    return markdown.replace("(images/", f"({stem}.images/")


def _normalize_json_artifact_name(path: Path) -> str | None:
    name = path.name
    if name == "layout.json":
        return "layout"
    if name in {"content_list.json", "content_list_v2.json", "model.json"}:
        return name.removesuffix(".json")
    if name.endswith("_content_list.json"):
        return "content_list"
    if name.endswith("_content_list_v2.json"):
        return "content_list_v2"
    if name.endswith("_model.json"):
        return "model"
    return None


def _write_json_artifact(
    targets: OutputTargets, json_type: str, payload: object
) -> None:
    if targets.json_dir is None:
        return
    target = targets.json_files.get(json_type)
    if target is None:
        target = targets.json_dir / f"{targets.stem}.{json_type}.json"
        targets.json_files[json_type] = target
    write_json_file(target, payload)


def _reset_json_dir(path: Path, retries: int = 3, delay_seconds: float = 0.2) -> None:
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


def _persist_precision_json_files(
    result, staging: Path, targets: OutputTargets
) -> None:
    if targets.json_dir is not None and targets.json_dir.exists():
        _reset_json_dir(targets.json_dir)

    if getattr(result, "content_list", None) is not None:
        _write_json_artifact(targets, "content_list", result.content_list)

    json_stage = staging / "json"
    result.save_all(str(json_stage))
    for artifact in json_stage.rglob("*.json"):
        json_type = _normalize_json_artifact_name(artifact)
        if json_type is None or json_type == "content_list":
            continue
        _write_json_artifact(
            targets, json_type, json.loads(artifact.read_text(encoding="utf-8"))
        )


def persist_precision_result(
    source: Path,
    result,
    output_root: Path,
    keep_raw_tree: bool = False,
    used_stems: set[str] | None = None,
) -> OutputTargets:
    include_json = True
    targets = build_output_targets(
        source,
        output_root,
        include_json=include_json,
        keep_raw_tree=keep_raw_tree,
        used_stems=used_stems,
    )

    with tempfile.TemporaryDirectory() as temp_dir:
        staging = Path(temp_dir)
        markdown_stage = staging / "full.md"
        result.save_markdown(str(markdown_stage), with_images=True)
        markdown = markdown_stage.read_text(encoding="utf-8")
        targets.markdown.write_text(
            _rewrite_markdown_image_paths(markdown, targets.stem), encoding="utf-8"
        )

        images_stage = staging / "images"
        if images_stage.exists():
            copy_directory(images_stage, targets.images_dir)

        _persist_precision_json_files(result, staging, targets)

    return targets


def convert_files(
    sources: list[Path],
    output_root: Path,
    token: str,
    keep_raw_tree: bool = False,
) -> list[OutputTargets]:
    if not token:
        raise ValueError("precision mode requires MINERU_TOKEN")
    if MinerUClient is None:
        raise RuntimeError("mineru-open-sdk is required for precision mode")

    used_stems: set[str] = set()
    rendered: list[OutputTargets] = []

    with MinerUClient(token) as client:
        for source in sources:
            result = client.extract(str(source))
            rendered.append(
                persist_precision_result(
                    source,
                    result,
                    output_root,
                    keep_raw_tree=keep_raw_tree,
                    used_stems=used_stems,
                )
            )
    return rendered
