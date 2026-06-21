import json
from pathlib import Path

import pytest

import scripts.mineru_manifest as mineru_manifest
from scripts.mineru_manifest import (
    BATCH_MANIFEST_FIELDS,
    MANIFEST_VERSION,
    PER_FILE_MANIFEST_FIELDS,
    build_manifest_entry,
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


def test_rerun_overwrite_writing_same_per_file_manifest_twice_produces_identical_output(tmp_path: Path):
    manifest = tmp_path / "report.manifest.json"
    entry = _entry()

    write_per_file_manifest(manifest, entry)
    first = manifest.read_text(encoding="utf-8")
    write_per_file_manifest(manifest, entry)
    second = manifest.read_text(encoding="utf-8")

    assert first == second
    assert json.loads(second) == entry
