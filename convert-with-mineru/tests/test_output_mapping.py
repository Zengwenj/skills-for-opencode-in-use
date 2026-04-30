from pathlib import Path

from scripts.mineru_outputs import build_output_targets


def test_build_output_targets_uses_source_name(tmp_path: Path):
    source = tmp_path / "report.pdf"
    targets = build_output_targets(
        source, tmp_path / "out", include_json=True, keep_raw_tree=True
    )

    assert targets.json_dir is not None
    assert targets.markdown.name == "report.md"
    assert targets.json_dir.name == "report.json"
    assert targets.json_files["content_list"].name == "report.content_list.json"
    assert targets.json_files["content_list_v2"].name == "report.content_list_v2.json"
    assert targets.json_files["layout"].name == "report.layout.json"
    assert targets.json_files["model"].name == "report.model.json"
    assert targets.images_dir.name == "report.images"
    assert (tmp_path / "out" / "report.raw").exists() is False


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
