from pathlib import Path

import pytest

from scripts.mineru_outputs import build_output_targets


def test_build_output_targets_uses_source_name(tmp_path: Path):
    source = tmp_path / "report.pdf"
    targets = build_output_targets(
        source, tmp_path / "out", include_json=True, keep_raw_tree=False
    )

    assert targets.json_dir is not None
    assert targets.markdown.name == "report.md"
    assert targets.json_dir.name == "report.json"
    assert targets.json_files["content_list"].name == "report.content_list.json"
    assert targets.json_files["content_list_v2"].name == "report.content_list_v2.json"
    assert targets.json_files["layout"].name == "report.layout.json"
    assert targets.json_files["model"].name == "report.model.json"
    assert targets.images_dir.name == "report.images"
    assert targets.manifest == tmp_path / "out" / "report.manifest.json"
    assert (tmp_path / "out" / "report.raw").exists() is False


def test_build_output_targets_manifest_collision_suffix(tmp_path: Path):
    source = tmp_path / "report.pdf"
    used_stems = {"report"}
    targets = build_output_targets(
        source,
        tmp_path / "out",
        include_json=False,
        keep_raw_tree=False,
        used_stems=used_stems,
    )

    assert targets.stem == "report__2"
    assert targets.markdown.name == "report__2.md"
    assert targets.images_dir.name == "report__2.images"
    assert targets.manifest.name == "report__2.manifest.json"
    assert targets.manifest == tmp_path / "out" / "report__2.manifest.json"


def test_build_output_targets_adds_collision_suffix(tmp_path: Path):
    source = tmp_path / "report.pdf"
    used_stems = {"report"}
    targets = build_output_targets(
        source,
        tmp_path / "out",
        include_json=False,
        keep_raw_tree=False,
        used_stems=used_stems,
    )

    assert targets.markdown.name == "report__2.md"
    assert targets.images_dir.name == "report__2.images"


class TestKeepRawTreeDirectoryInput:
    def test_case_a_directory_input_preserves_relative_path(self, tmp_path: Path):
        source = tmp_path / "docs" / "a" / "report.pdf"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("x", encoding="utf-8")
        input_dir = tmp_path / "docs"
        output_root = tmp_path / "_mineru"
        targets = build_output_targets(
            source,
            output_root,
            include_json=False,
            keep_raw_tree=True,
            relative_root=input_dir,
        )
        assert targets.markdown == output_root / "a" / "report.md"
        assert targets.images_dir == output_root / "a" / "report.images"
        assert targets.manifest == output_root / "a" / "report.manifest.json"

    def test_case_b_single_file_flattens(self, tmp_path: Path):
        source = tmp_path / "docs" / "a" / "report.pdf"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("x", encoding="utf-8")
        output_root = tmp_path / "_mineru"
        targets = build_output_targets(
            source,
            output_root,
            include_json=False,
            keep_raw_tree=True,
        )
        assert targets.markdown == output_root / "report.md"
        assert targets.images_dir == output_root / "report.images"

    def test_case_c_cwd_relative_root(self, tmp_path: Path):
        source = tmp_path / "docs" / "a" / "report.pdf"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("x", encoding="utf-8")
        output_root = tmp_path / "_mineru"
        targets = build_output_targets(
            source,
            output_root,
            include_json=False,
            keep_raw_tree=True,
            relative_root=tmp_path,
        )
        assert targets.markdown == output_root / "docs" / "a" / "report.md"

    def test_keep_raw_tree_false_always_flat(self, tmp_path: Path):
        source = tmp_path / "docs" / "a" / "report.pdf"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("x", encoding="utf-8")
        output_root = tmp_path / "_mineru"
        targets = build_output_targets(
            source,
            output_root,
            include_json=False,
            keep_raw_tree=False,
            relative_root=tmp_path / "docs",
        )
        assert targets.markdown == output_root / "report.md"

    def test_collision_with_keep_raw_tree(self, tmp_path: Path):
        source1 = tmp_path / "docs" / "report.pdf"
        source1.parent.mkdir(parents=True, exist_ok=True)
        source1.write_text("x", encoding="utf-8")
        source2 = tmp_path / "notes" / "report.pdf"
        source2.parent.mkdir(parents=True, exist_ok=True)
        source2.write_text("x", encoding="utf-8")
        output_root = tmp_path / "_mineru"
        used: set[str] = set()
        t1 = build_output_targets(
            source1, output_root, include_json=False, keep_raw_tree=True,
            relative_root=tmp_path, used_stems=used,
        )
        t2 = build_output_targets(
            source2, output_root, include_json=False, keep_raw_tree=True,
            relative_root=tmp_path, used_stems=used,
        )
        assert t1.stem == "report"
        assert t2.stem == "report__2"
        assert t1.manifest.parent == output_root / "docs"
        assert t2.manifest.parent == output_root / "notes"
        assert t1.manifest.name == "report.manifest.json"
        assert t2.manifest.name == "report__2.manifest.json"

    def test_json_dir_preserves_subdir(self, tmp_path: Path):
        source = tmp_path / "docs" / "a" / "report.pdf"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text("x", encoding="utf-8")
        output_root = tmp_path / "_mineru"
        targets = build_output_targets(
            source, output_root, include_json=True, keep_raw_tree=True,
            relative_root=tmp_path / "docs",
        )
        assert targets.json_dir == output_root / "a" / "report.json"
