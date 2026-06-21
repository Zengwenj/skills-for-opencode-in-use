from __future__ import annotations

import importlib
import json
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
from .mineru_manifest import (
    RAW_STATUS_ARCHIVED,
    RAW_STATUS_FAILED,
    archive_raw_tree,
    build_manifest_entry,
    detect_image_status,
    read_batch_manifest,
    to_posix,
    write_per_file_manifest,
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
    relative_root: Path | None = None,
    audit_dir: Path | None = None,
    batch_id: str | None = None,
    route: str = "mineru",
    model: str = "default",
    allocated_stem: str | None = None,
) -> OutputTargets:
    include_json = True
    targets = build_output_targets(
        source,
        output_root,
        include_json=include_json,
        keep_raw_tree=keep_raw_tree,
        used_stems=used_stems,
        relative_root=relative_root,
        allocated_stem=allocated_stem,
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
        image_status, image_count = detect_image_status(
            images_stage if images_stage.exists() else None
        )
        if images_stage.exists():
            copy_directory(images_stage, targets.images_dir)

        _persist_precision_json_files(result, staging, targets)

        if audit_dir is not None:
            errors: list[str] = []
            warnings: list[str] = []
            raw_archive_status = RAW_STATUS_FAILED
            raw_archive_path: str | None = None

            raw_stage = staging / "raw"
            relative_source_path = _manifest_relative_source_path(
                source, relative_root
            )
            raw_target = audit_dir / "raw" / relative_source_path.with_suffix("")
            try:
                result.save_all(str(raw_stage))
                raw_archive_status, raw_archive_path = archive_raw_tree(
                    raw_stage, raw_target
                )
            except Exception as exc:
                errors.append(str(exc))
                warnings.append("raw archive failed")

            if raw_archive_status != RAW_STATUS_ARCHIVED:
                warnings.append(f"raw archive status: {raw_archive_status}")
            if image_status != "ok":
                warnings.append(f"image status: {image_status}")

            entry = build_manifest_entry(
                source_path=source,
                relative_source_path=relative_source_path,
                allocated_stem=targets.stem,
                route=route,
                model=model,
                output_md=targets.markdown,
                output_images_dir=targets.images_dir,
                output_json_dir=targets.json_dir,
                raw_archive_path=raw_archive_path,
                raw_archive_status=raw_archive_status,
                image_status=image_status,
                image_count=image_count,
                conversion_status="success",
                quality_gate={
                    "status": "not_run",
                    "passed": None,
                    "failed_gates": [],
                },
                errors=errors,
                warnings=warnings,
                batch_id=batch_id or "default",
            )
            entry["per_file_manifest"] = to_posix(targets.manifest)
            write_per_file_manifest(targets.manifest, entry)

    return targets


def _manifest_relative_source_path(source: Path, relative_root: Path | None) -> Path:
    if relative_root is None:
        return Path(source.name)
    try:
        return source.relative_to(relative_root)
    except ValueError:
        return Path(source.name)


HTML_EXTENSIONS = {".html", ".htm"}


def _extract_one(client, source: Path):
    if source.suffix.lower() in HTML_EXTENSIONS:
        return client.extract(str(source), model="html")
    return client.extract(str(source))


def convert_files(
    sources: list[Path],
    output_root: Path,
    token: str,
    keep_raw_tree: bool = False,
    relative_root: Path | None = None,
    audit_dir: Path | None = None,
    batch_id: str | None = None,
    route: str = "mineru",
    model: str = "default",
    failure_collector: list[dict] | None = None,
) -> list[OutputTargets]:
    if not token:
        raise ValueError("precision mode requires MINERU_TOKEN")
    if MinerUClient is None:
        raise RuntimeError("mineru-open-sdk is required for precision mode")

    used_stems: set[str] = set()
    rendered: list[OutputTargets] = []
    existing_manifest = (
        read_batch_manifest(audit_dir / "mineru_manifest.json")
        if audit_dir is not None
        else {}
    )

    with MinerUClient(token) as client:
        for source in sources:
            try:
                relative_source_path = _manifest_relative_source_path(source, relative_root)
                existing_entry = existing_manifest.get(to_posix(relative_source_path), {})
                allocated_stem = existing_entry.get("allocated_stem") or None
                result = _extract_one(client, source)
                rendered.append(
                    persist_precision_result(
                        source,
                        result,
                        output_root,
                        keep_raw_tree=keep_raw_tree,
                        used_stems=used_stems,
                        relative_root=relative_root,
                        audit_dir=audit_dir,
                        batch_id=batch_id,
                        route=route,
                        model=model,
                        allocated_stem=allocated_stem,
                    )
                )
            except Exception as exc:
                if failure_collector is None:
                    raise
                failure_collector.append(
                    {"source_path": source, "error": str(exc), "route": route}
                )
    return rendered
