from pathlib import Path

from scripts.mineru_inputs import discover_inputs, split_supported_and_fallback


ROOT = Path(__file__).resolve().parents[1]


def test_discover_inputs_filters_supported_files(tmp_path: Path):
    (tmp_path / "a.pdf").write_text("x", encoding="utf-8")
    (tmp_path / "b.csv").write_text("x", encoding="utf-8")
    (tmp_path / "c.txt").write_text("x", encoding="utf-8")

    discovered = discover_inputs([tmp_path], recursive=False)
    assert [path.name for path in discovered] == ["a.pdf", "b.csv"]


def test_discover_inputs_respects_recursive_flag(tmp_path: Path):
    nested = tmp_path / "nested"
    nested.mkdir()
    (nested / "a.pdf").write_text("x", encoding="utf-8")

    non_recursive = discover_inputs([tmp_path], recursive=False)
    recursive = discover_inputs([tmp_path], recursive=True)

    assert non_recursive == []
    assert [path.name for path in recursive] == ["a.pdf"]


def test_discover_inputs_excludes_output_root(tmp_path: Path):
    output_root = tmp_path / "_mineru_output"
    nested = output_root / "report.images"
    nested.mkdir(parents=True)
    (tmp_path / "report.pdf").write_text("x", encoding="utf-8")
    (nested / "img1.jpg").write_text("x", encoding="utf-8")

    discovered = discover_inputs(
        [tmp_path], recursive=True, exclude_roots=[output_root]
    )

    assert [path.name for path in discovered] == ["report.pdf"]


def test_discover_inputs_skips_existing_mineru_output_trees(tmp_path: Path):
    mineu_output = tmp_path / "_mineru_validation"
    (mineu_output / "report.images").mkdir(parents=True)
    (mineu_output / "report.json").mkdir(parents=True)
    (tmp_path / "report.pdf").write_text("x", encoding="utf-8")
    (mineu_output / "report.images" / "img1.jpg").write_text("x", encoding="utf-8")
    (mineu_output / "report.json" / "report.content_list.json").write_text(
        "{}", encoding="utf-8"
    )

    discovered = discover_inputs([tmp_path], recursive=True)

    assert [path.name for path in discovered] == ["report.pdf"]


def test_split_supported_and_fallback(tmp_path: Path):
    pdf = tmp_path / "a.pdf"
    csv = tmp_path / "b.csv"
    pdf.write_text("x", encoding="utf-8")
    csv.write_text("x", encoding="utf-8")

    supported, fallback = split_supported_and_fallback([pdf, csv])
    assert supported == [pdf]
    assert fallback == [csv]


def test_skill_markdown_has_no_utf8_bom():
    raw = (ROOT / "SKILL.md").read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf")


def test_skill_markdown_documents_module_entrypoint():
    content = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    assert "python -m scripts.mineru_convert" in content
    assert "uv run scripts/mineru_convert.py" not in content


def test_skill_markdown_references_existing_example_files():
    content = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    assert "examples/mineru.env" in content
    assert "examples/mineru.json" in content
    assert "examples/mineru.env.example" not in content
    assert "examples/mineru.json.example" not in content
