from __future__ import annotations

import copy
import json
import os
import shutil
import tempfile
from collections.abc import Mapping
from pathlib import Path
from typing import Any


MANIFEST_VERSION = "1.0"

IMAGE_STATUS_OK = "ok"
IMAGE_STATUS_EMPTY = "empty"
IMAGE_STATUS_NONE_PRODUCED = "none_produced"
IMAGE_STATUS_FAILED = "failed"

RAW_STATUS_ARCHIVED = "archived"
RAW_STATUS_SKIPPED = "skipped"
RAW_STATUS_FAILED = "failed"
RAW_STATUS_PATH_TOO_LONG = "path_too_long"

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".jp2", ".webp", ".gif", ".bmp"}

CONVERSION_STATUSES = {"success", "failed", "skipped"}

PER_FILE_MANIFEST_FIELDS = [
    "manifest_version",
    "batch_id",
    "source_path",
    "relative_source_path",
    "allocated_stem",
    "route",
    "model",
    "conversion_status",
    "output_md",
    "output_json_dir",
    "output_images_dir",
    "per_file_manifest",
    "raw_archive_path",
    "raw_archive_status",
    "image_status",
    "image_count",
    "json_status",
    "quality_gate",
    "errors",
    "warnings",
]

BATCH_MANIFEST_FIELDS = PER_FILE_MANIFEST_FIELDS.copy()

_PATH_FIELDS = {
    "source_path",
    "relative_source_path",
    "output_md",
    "output_json_dir",
    "output_images_dir",
    "per_file_manifest",
    "raw_archive_path",
}


def to_posix(path: Path | str | None) -> str | None:
    if path is None:
        return None
    return str(path).replace("\\", "/")


def _write_json_atomic(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temp_file:
            temp_name = temp_file.name
            json.dump(payload, temp_file, ensure_ascii=False, indent=2)
            temp_file.flush()
            os.fsync(temp_file.fileno())
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name is not None:
            try:
                Path(temp_name).unlink()
            except FileNotFoundError:
                pass


def write_per_file_manifest(path: Path, entry: dict) -> None:
    _write_json_atomic(path, entry)


def read_per_file_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as manifest_file:
        return json.load(manifest_file)


def _deep_merge(base: dict, updates: Mapping[str, Any]) -> dict:
    merged = copy.deepcopy(base)
    for key, value in updates.items():
        if isinstance(merged.get(key), dict) and isinstance(value, Mapping):
            merged[key] = _deep_merge(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def update_per_file_manifest(path: Path, updates: dict) -> dict:
    existing = read_per_file_manifest(path)
    merged = _deep_merge(existing, updates)
    write_per_file_manifest(path, merged)
    return merged


def _corrupt_path(path: Path) -> Path:
    candidate = path.with_name(f"{path.name}.corrupt")
    if not candidate.exists():
        return candidate
    index = 2
    while True:
        candidate = path.with_name(f"{path.name}.corrupt.{index}")
        if not candidate.exists():
            return candidate
        index += 1


def read_batch_manifest(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as manifest_file:
            data = json.load(manifest_file)
    except json.JSONDecodeError:
        path.rename(_corrupt_path(path))
        return {}
    if not isinstance(data, dict):
        return {}
    return data


def upsert_batch_manifest(path: Path, key: str, entry: dict) -> dict:
    data = read_batch_manifest(path)
    data[key] = entry
    _write_json_atomic(path, data)
    return data


def build_manifest_entry(
    *,
    source_path,
    relative_source_path,
    allocated_stem,
    route,
    model,
    output_md,
    output_images_dir,
    output_json_dir,
    raw_archive_path,
    raw_archive_status,
    image_status,
    image_count,
    conversion_status,
    quality_gate,
    errors,
    warnings,
    batch_id,
    manifest_version=MANIFEST_VERSION,
) -> dict:
    if conversion_status not in CONVERSION_STATUSES:
        raise ValueError(f"conversion_status must be one of {sorted(CONVERSION_STATUSES)}")

    normalized_quality_gate = copy.deepcopy(quality_gate)
    if conversion_status == "failed":
        normalized_quality_gate["status"] = "not_applicable"

    output_json_dir_posix = to_posix(output_json_dir)
    entry = {
        "manifest_version": manifest_version,
        "batch_id": batch_id,
        "source_path": source_path,
        "relative_source_path": relative_source_path,
        "allocated_stem": allocated_stem,
        "route": route,
        "model": model,
        "conversion_status": conversion_status,
        "output_md": output_md,
        "output_json_dir": output_json_dir,
        "output_images_dir": output_images_dir,
        "per_file_manifest": None,
        "raw_archive_path": raw_archive_path,
        "raw_archive_status": raw_archive_status,
        "image_status": image_status,
        "image_count": int(image_count),
        "json_status": "ok" if output_json_dir_posix is not None else "none",
        "quality_gate": normalized_quality_gate,
        "errors": copy.deepcopy(errors),
        "warnings": copy.deepcopy(warnings),
    }

    for field in _PATH_FIELDS:
        entry[field] = to_posix(entry[field])

    return entry


def detect_image_status(staging_images_dir: Path | None) -> tuple[str, int]:
    if staging_images_dir is None or not staging_images_dir.exists():
        print("warning: no images directory produced")
        return (IMAGE_STATUS_NONE_PRODUCED, 0)

    image_count = sum(
        1
        for path in staging_images_dir.rglob("*")
        if path.is_file() and path.suffix.lower() in IMAGE_EXTENSIONS
    )
    if image_count == 0:
        print("warning: images directory contains no image files")
        return (IMAGE_STATUS_EMPTY, 0)
    return (IMAGE_STATUS_OK, image_count)


def copy_images_with_status(src: Path, dst: Path) -> tuple[str, int]:
    if not src.exists():
        return (IMAGE_STATUS_NONE_PRODUCED, 0)

    try:
        if dst.exists():
            shutil.rmtree(dst)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst)
    except (OSError, PermissionError):
        return (IMAGE_STATUS_FAILED, 0)

    return detect_image_status(dst)


def archive_raw_tree(src: Path, dst: Path) -> tuple[str, str | None]:
    if not src.exists():
        print(f"warning: raw archive source does not exist: {to_posix(src)}")
        return (RAW_STATUS_SKIPPED, None)

    if os.name == "nt" and len(str(dst)) > 260:
        print(f"warning: raw archive path too long: {to_posix(dst)}")
        return (RAW_STATUS_PATH_TOO_LONG, None)

    try:
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst)
    except (OSError, PermissionError):
        return (RAW_STATUS_FAILED, None)

    return (RAW_STATUS_ARCHIVED, to_posix(dst))
