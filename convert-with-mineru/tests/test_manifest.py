import json
from pathlib import Path

import pytest

import scripts.mineru_manifest as mineru_manifest
from scripts.mineru_manifest import (
    BATCH_MANIFEST_FIELDS,
    IMAGE_EXTENSIONS,
    MANIFEST_VERSION,
    PER_FILE_MANIFEST_FIELDS,
    archive_raw_tree,
    build_manifest_entry,
    copy_images_with_status,
    detect_image_status,
    read_batch_manifest,
    read_per_file_manifest,
    to_posix,
    update_per_file_manifest,
    upsert_batch_manifest,
    write_per_file_manifest,
)


def _entry(**overrides):
    payload = {
        "source_path": "C:/docs/报告.pdf",
        "relative_source_path": "dept/报告.pdf",
        "allocated_stem": "报告",
        "route": "mineru",
        "model": "default",
        "conversion_status": "success",
        "output_md": "out/报告.md",
        "output_json_dir": "out/报告.json",
        "output_images_dir": "out/报告.images",
        "per_file_manifest": "out/报告.manifest.json",
        "raw_archive_path": "review/raw/dept/报告",
        "raw_archive_status": "archived",
        "image_status": "ok",
        "image_count": 2,
        "json_status": "ok",
        "quality_gate": {"status": "not_run", "passed": None, "failed_gates": []},
        "errors": [],
        "warnings": [],
        "batch_id": "batch-1",
        "manifest_version": MANIFEST_VERSION,
    }
    payload.update(overrides)
    return payload


def test_write_per_file_manifest_writes_valid_json_with_correct_fields(tmp_path: Path):
    manifest = tmp_path / "report.manifest.json"
    entry = _entry()

    write_per_file_manifest(manifest, entry)

    loaded = json.loads(manifest.read_text(encoding="utf-8"))
    assert loaded == entry
    assert "报告.pdf" in manifest.read_text(encoding="utf-8")
    assert set(PER_FILE_MANIFEST_FIELDS).issubset(loaded.keys())


def test_write_per_file_manifest_is_atomic(tmp_path: Path, monkeypatch):
    manifest = tmp_path / "report.manifest.json"
    calls = []
    original_replace = mineru_manifest.os.replace

    def recording_replace(src, dst):
        calls.append((Path(src), Path(dst)))
        original_replace(src, dst)

    monkeypatch.setattr(mineru_manifest.os, "replace", recording_replace)

    write_per_file_manifest(manifest, _entry())

    assert len(calls) == 1
    temp_path, target_path = calls[0]
    assert temp_path.parent == manifest.parent
    assert temp_path.name != manifest.name
    assert target_path == manifest
    assert not temp_path.exists()
    assert json.loads(manifest.read_text(encoding="utf-8"))["allocated_stem"] == "报告"


def test_update_per_file_manifest_deep_merges_nested_dicts(tmp_path: Path):
    manifest = tmp_path / "report.manifest.json"
    write_per_file_manifest(
        manifest,
        _entry(quality_gate={"status": "not_run", "passed": None, "failed_gates": ["missing_image_path"]}),
    )

    merged = update_per_file_manifest(manifest, {"quality_gate": {"status": "failed"}})

    assert merged["quality_gate"] == {
        "status": "failed",
        "passed": None,
        "failed_gates": ["missing_image_path"],
    }
    assert json.loads(manifest.read_text(encoding="utf-8")) == merged


def test_update_per_file_manifest_overwrites_scalar_values(tmp_path: Path):
    manifest = tmp_path / "report.manifest.json"
    write_per_file_manifest(manifest, _entry(conversion_status="success"))

    merged = update_per_file_manifest(manifest, {"conversion_status": "skipped", "image_count": 0})

    assert merged["conversion_status"] == "skipped"
    assert merged["image_count"] == 0


def test_update_per_file_manifest_raises_file_not_found_if_manifest_does_not_exist(tmp_path: Path):
    with pytest.raises(FileNotFoundError):
        update_per_file_manifest(tmp_path / "missing.manifest.json", {"conversion_status": "success"})


def test_read_batch_manifest_returns_empty_dict_for_nonexistent_file(tmp_path: Path):
    assert read_batch_manifest(tmp_path / "mineru_manifest.json") == {}


def test_read_batch_manifest_renames_corrupt_json_to_corrupt_and_returns_empty_dict(tmp_path: Path):
    batch = tmp_path / "mineru_manifest.json"
    batch.write_text("{not valid json", encoding="utf-8")

    assert read_batch_manifest(batch) == {}

    corrupt = tmp_path / "mineru_manifest.json.corrupt"
    assert corrupt.read_text(encoding="utf-8") == "{not valid json"
    assert not batch.exists()


def test_upsert_batch_manifest_creates_new_file_if_not_exists(tmp_path: Path):
    batch = tmp_path / "mineru_manifest.json"
    entry = _entry(relative_source_path="dept/report.pdf")

    result = upsert_batch_manifest(batch, "dept/report.pdf", entry)

    assert result == {"dept/report.pdf": entry}
    assert json.loads(batch.read_text(encoding="utf-8")) == result


def test_upsert_batch_manifest_upserts_by_key(tmp_path: Path):
    batch = tmp_path / "mineru_manifest.json"
    first = _entry(allocated_stem="report")
    replacement = _entry(allocated_stem="report-rerun", conversion_status="skipped")
    second = _entry(relative_source_path="dept/other.pdf", allocated_stem="other")

    upsert_batch_manifest(batch, "dept/report.pdf", first)
    upsert_batch_manifest(batch, "dept/report.pdf", replacement)
    result = upsert_batch_manifest(batch, "dept/other.pdf", second)

    assert result["dept/report.pdf"] == replacement
    assert result["dept/other.pdf"] == second


def test_upsert_batch_manifest_preserves_other_keys(tmp_path: Path):
    batch = tmp_path / "mineru_manifest.json"
    first = _entry(relative_source_path="dept/report.pdf", allocated_stem="report")
    second = _entry(relative_source_path="dept/other.pdf", allocated_stem="other")

    upsert_batch_manifest(batch, "dept/report.pdf", first)
    upsert_batch_manifest(batch, "dept/other.pdf", second)

    result = upsert_batch_manifest(batch, "dept/report.pdf", _entry(allocated_stem="report-new"))

    assert result["dept/other.pdf"] == second
    assert result["dept/report.pdf"]["allocated_stem"] == "report-new"


def test_upsert_batch_manifest_is_atomic(tmp_path: Path, monkeypatch):
    batch = tmp_path / "mineru_manifest.json"
    calls = []
    original_replace = mineru_manifest.os.replace

    def recording_replace(src, dst):
        calls.append((Path(src), Path(dst)))
        original_replace(src, dst)

    monkeypatch.setattr(mineru_manifest.os, "replace", recording_replace)

    upsert_batch_manifest(batch, "dept/report.pdf", _entry())

    assert len(calls) == 1
    temp_path, target_path = calls[0]
    assert temp_path.parent == batch.parent
    assert temp_path.name != batch.name
    assert target_path == batch
    assert not temp_path.exists()
    assert "dept/report.pdf" in json.loads(batch.read_text(encoding="utf-8"))


def test_build_manifest_entry_accepts_all_required_fields_as_keyword_args():
    entry = build_manifest_entry(
        source_path="C:/docs/report.pdf",
        relative_source_path="dept/report.pdf",
        allocated_stem="report",
        route="mineru",
        model="default",
        output_md="out/report.md",
        output_images_dir="out/report.images",
        output_json_dir="out/report.json",
        raw_archive_path="review/raw/dept/report",
        raw_archive_status="archived",
        image_status="ok",
        image_count=1,
        conversion_status="success",
        quality_gate={"status": "not_run", "passed": None, "failed_gates": []},
        errors=[],
        warnings=[],
        batch_id="batch-1",
    )

    assert entry["manifest_version"] == MANIFEST_VERSION
    assert set(PER_FILE_MANIFEST_FIELDS).issubset(entry.keys())
    assert set(BATCH_MANIFEST_FIELDS).issubset(entry.keys())


def test_build_manifest_entry_raises_type_error_if_required_field_is_missing():
    kwargs = {
        "source_path": "C:/docs/report.pdf",
        "relative_source_path": "dept/report.pdf",
        "allocated_stem": "report",
        "route": "mineru",
        "model": "default",
        "output_md": "out/report.md",
        "output_images_dir": "out/report.images",
        "output_json_dir": "out/report.json",
        "raw_archive_path": "review/raw/dept/report",
        "raw_archive_status": "archived",
        "image_status": "ok",
        "image_count": 1,
        "conversion_status": "success",
        "quality_gate": {"status": "not_run", "passed": None, "failed_gates": []},
        "errors": [],
        "warnings": [],
    }

    with pytest.raises(TypeError):
        build_manifest_entry(**kwargs)


def test_build_manifest_entry_converts_path_fields_to_posix_strings(tmp_path: Path):
    entry = build_manifest_entry(
        source_path=Path("C:/docs") / "report.pdf",
        relative_source_path=Path("dept") / "report.pdf",
        allocated_stem="report",
        route="mineru",
        model="default",
        output_md=tmp_path / "out" / "report.md",
        output_images_dir=tmp_path / "out" / "report.images",
        output_json_dir=tmp_path / "out" / "report.json",
        raw_archive_path=tmp_path / "review" / "raw" / "report",
        raw_archive_status="archived",
        image_status="ok",
        image_count=1,
        conversion_status="success",
        quality_gate={"status": "not_run", "passed": None, "failed_gates": []},
        errors=[],
        warnings=[],
        batch_id="batch-1",
    )

    for key in ("source_path", "relative_source_path", "output_md", "output_images_dir", "output_json_dir", "raw_archive_path"):
        assert isinstance(entry[key], str)
        assert "\\" not in entry[key]


def test_build_manifest_entry_handles_none_values_for_optional_path_fields():
    entry = build_manifest_entry(
        source_path="C:/docs/report.pdf",
        relative_source_path="dept/report.pdf",
        allocated_stem="report",
        route="mineru",
        model="default",
        output_md=None,
        output_images_dir=None,
        output_json_dir=None,
        raw_archive_path=None,
        raw_archive_status="skipped",
        image_status="none_produced",
        image_count=0,
        conversion_status="failed",
        quality_gate={"status": "not_run", "passed": None, "failed_gates": []},
        errors=["SDK failed"],
        warnings=[],
        batch_id="batch-1",
    )

    assert entry["output_md"] is None
    assert entry["output_images_dir"] is None
    assert entry["output_json_dir"] is None
    assert entry["raw_archive_path"] is None
    assert entry["quality_gate"]["status"] == "not_applicable"


def test_to_posix_converts_windows_backslash_paths_to_forward_slashes():
    assert to_posix(r"C:\docs\nested\report.pdf") == "C:/docs/nested/report.pdf"


def test_to_posix_returns_none_for_none_input():
    assert to_posix(None) is None


def test_image_extensions_match_mineru_supported_image_formats():
    assert IMAGE_EXTENSIONS == {".png", ".jpg", ".jpeg", ".jp2", ".webp", ".gif", ".bmp"}


def test_detect_image_status_returns_none_produced_for_none():
    assert detect_image_status(None) == ("none_produced", 0)


def test_detect_image_status_returns_none_produced_for_nonexistent_dir(tmp_path: Path):
    assert detect_image_status(tmp_path / "missing.images") == ("none_produced", 0)


def test_detect_image_status_returns_empty_for_empty_dir(tmp_path: Path):
    images_dir = tmp_path / "report.images"
    images_dir.mkdir()

    assert detect_image_status(images_dir) == ("empty", 0)


def test_detect_image_status_returns_empty_for_non_image_files(tmp_path: Path):
    images_dir = tmp_path / "report.images"
    images_dir.mkdir()
    (images_dir / "notes.txt").write_text("not an image", encoding="utf-8")

    assert detect_image_status(images_dir) == ("empty", 0)


def test_detect_image_status_counts_single_png(tmp_path: Path):
    images_dir = tmp_path / "report.images"
    images_dir.mkdir()
    (images_dir / "page.png").write_bytes(b"png")

    assert detect_image_status(images_dir) == ("ok", 1)


def test_detect_image_status_counts_multiple_images_and_ignores_non_images(tmp_path: Path):
    images_dir = tmp_path / "report.images"
    images_dir.mkdir()
    (images_dir / "page.PNG").write_bytes(b"png")
    (images_dir / "diagram.jpeg").write_bytes(b"jpeg")
    (images_dir / "scan.webp").write_bytes(b"webp")
    (images_dir / "notes.txt").write_text("skip", encoding="utf-8")
    (images_dir / "fake_png_dir.png").mkdir()

    assert detect_image_status(images_dir) == ("ok", 3)


def test_detect_image_status_counts_images_recursively(tmp_path: Path):
    images_dir = tmp_path / "report.images"
    nested = images_dir / "nested" / "deeper"
    nested.mkdir(parents=True)
    (nested / "page.jpg").write_bytes(b"jpg")

    assert detect_image_status(images_dir) == ("ok", 1)


def test_copy_images_with_status_copies_images_and_returns_detected_status(tmp_path: Path):
    src = tmp_path / "stage" / "images"
    nested = src / "nested"
    nested.mkdir(parents=True)
    (src / "page.png").write_bytes(b"png")
    (nested / "diagram.jpg").write_bytes(b"jpg")
    dst = tmp_path / "out" / "report.images"

    assert copy_images_with_status(src, dst) == ("ok", 2)
    assert (dst / "page.png").read_bytes() == b"png"
    assert (dst / "nested" / "diagram.jpg").read_bytes() == b"jpg"


def test_copy_images_with_status_returns_none_produced_for_missing_src(tmp_path: Path):
    assert copy_images_with_status(tmp_path / "missing", tmp_path / "out.images") == ("none_produced", 0)


def test_copy_images_with_status_returns_failed_when_copytree_raises(tmp_path: Path, monkeypatch):
    src = tmp_path / "images"
    src.mkdir()
    (src / "page.png").write_bytes(b"png")

    def fail_copytree(source, target):
        raise OSError("copy failed")

    monkeypatch.setattr(mineru_manifest.shutil, "copytree", fail_copytree)

    assert copy_images_with_status(src, tmp_path / "out.images") == ("failed", 0)


def test_copy_images_with_status_overwrites_existing_dst(tmp_path: Path):
    src = tmp_path / "images"
    src.mkdir()
    (src / "new.png").write_bytes(b"new")
    dst = tmp_path / "out.images"
    dst.mkdir()
    (dst / "old.png").write_bytes(b"old")

    assert copy_images_with_status(src, dst) == ("ok", 1)
    assert (dst / "new.png").read_bytes() == b"new"
    assert not (dst / "old.png").exists()


def test_archive_raw_tree_returns_skipped_for_missing_src(tmp_path: Path):
    assert archive_raw_tree(tmp_path / "missing", tmp_path / "audit" / "raw") == ("skipped", None)


def test_archive_raw_tree_copies_raw_tree_and_returns_posix_path(tmp_path: Path):
    src = tmp_path / "raw-stage"
    nested = src / "nested"
    nested.mkdir(parents=True)
    (nested / "full.md").write_text("raw", encoding="utf-8")
    dst = tmp_path / "audit" / "report.raw"

    assert archive_raw_tree(src, dst) == ("archived", to_posix(dst))
    assert (dst / "nested" / "full.md").read_text(encoding="utf-8") == "raw"


def test_archive_raw_tree_auto_creates_parent_dirs(tmp_path: Path):
    src = tmp_path / "raw-stage"
    src.mkdir()
    (src / "full.md").write_text("raw", encoding="utf-8")
    dst = tmp_path / "missing" / "parents" / "report.raw"

    assert archive_raw_tree(src, dst) == ("archived", to_posix(dst))
    assert (dst / "full.md").read_text(encoding="utf-8") == "raw"


def test_archive_raw_tree_overwrites_existing_dst(tmp_path: Path):
    src = tmp_path / "raw-stage"
    src.mkdir()
    (src / "new.txt").write_text("new", encoding="utf-8")
    dst = tmp_path / "audit" / "report.raw"
    dst.mkdir(parents=True)
    (dst / "old.txt").write_text("old", encoding="utf-8")

    assert archive_raw_tree(src, dst) == ("archived", to_posix(dst))
    assert (dst / "new.txt").read_text(encoding="utf-8") == "new"
    assert not (dst / "old.txt").exists()


def test_archive_raw_tree_returns_failed_when_copytree_raises(tmp_path: Path, monkeypatch):
    src = tmp_path / "raw-stage"
    src.mkdir()

    def fail_copytree(source, target):
        raise PermissionError("denied")

    monkeypatch.setattr(mineru_manifest.shutil, "copytree", fail_copytree)

    assert archive_raw_tree(src, tmp_path / "audit" / "report.raw") == ("failed", None)


def test_archive_raw_tree_returns_path_too_long_before_copy_on_windows(tmp_path: Path, monkeypatch):
    src = tmp_path / "raw-stage"
    src.mkdir()
    too_long_dst = tmp_path / ("a" * 100) / ("b" * 100) / ("c" * 100) / "report.raw"
    copy_calls = []

    def record_copytree(source, target):
        copy_calls.append((source, target))

    monkeypatch.setattr(mineru_manifest.os, "name", "nt")
    monkeypatch.setattr(mineru_manifest.shutil, "copytree", record_copytree)

    assert archive_raw_tree(src, too_long_dst) == ("path_too_long", None)
    assert copy_calls == []
    assert not too_long_dst.parent.exists()


def test_rerun_overwrite_writing_same_per_file_manifest_twice_produces_identical_output(tmp_path: Path):
    manifest = tmp_path / "report.manifest.json"
    entry = _entry()

    write_per_file_manifest(manifest, entry)
    first = manifest.read_text(encoding="utf-8")
    write_per_file_manifest(manifest, entry)
    second = manifest.read_text(encoding="utf-8")

    assert first == second
    assert json.loads(second) == entry
