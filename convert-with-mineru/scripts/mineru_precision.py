from __future__ import annotations

import importlib
import tempfile
from pathlib import Path
from typing import Protocol

from .mineru_outputs import (
    OutputTargets,
    build_output_targets,
    copy_directory,
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


class MinerUBatchClient(Protocol):
    def extract_batch(self, sources: list[str], **kwargs): ...


def _rewrite_markdown_image_paths(markdown: str, stem: str) -> str:
    return markdown.replace("(images/", f"({stem}.images/")


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
    model: str = "vlm",
    allocated_stem: str | None = None,
) -> OutputTargets:
    targets = build_output_targets(
        source,
        output_root,
        include_json=False,
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
                output_json_dir=None,
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


def _is_html_source(source: Path) -> bool:
    return source.suffix.lower() in HTML_EXTENSIONS


def _extract_one(client, source: Path):
    if _is_html_source(source):
        return client.extract(str(source), model="html")
    return client.extract(str(source))


def _extract_batch(client, sources: list[Path], model_version: str):
    source_strings = [str(source) for source in sources]
    batch_extract = getattr(client, "extract_batch", None)
    if batch_extract is not None:
        return batch_extract(source_strings, model_version=model_version)
    return [_extract_one(client, source) for source in sources]


def _batch_groups(sources: list[Path]) -> list[tuple[list[Path], str]]:
    groups: list[tuple[list[Path], str]] = []
    for source in sources:
        model_version = "MinerU-HTML" if _is_html_source(source) else "vlm"
        for group_sources, group_model in groups:
            if group_model == model_version:
                group_sources.append(source)
                break
        else:
            groups.append(([source], model_version))
    return groups


def _single_source_groups(sources: list[Path]) -> list[tuple[list[Path], str]]:
    return [([source], "MinerU-HTML" if _is_html_source(source) else "vlm") for source in sources]


def convert_files(
    sources: list[Path],
    output_root: Path,
    token: str,
    keep_raw_tree: bool = False,
    relative_root: Path | None = None,
    audit_dir: Path | None = None,
    batch_id: str | None = None,
    route: str = "mineru",
    model: str = "vlm",
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
        groups = _batch_groups(sources) if getattr(client, "extract_batch", None) is not None else _single_source_groups(sources)
        for batch_sources, model_version in groups:
            try:
                results = _extract_batch(client, batch_sources, model_version)
            except Exception as exc:
                if failure_collector is None:
                    raise
                for source in batch_sources:
                    failure_collector.append(
                        {"source_path": source, "error": str(exc), "route": route}
                    )
                continue
            for source, result in zip(batch_sources, results):
                try:
                    relative_source_path = _manifest_relative_source_path(source, relative_root)
                    existing_entry = existing_manifest.get(to_posix(relative_source_path), {})
                    allocated_stem = existing_entry.get("allocated_stem") or None
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
