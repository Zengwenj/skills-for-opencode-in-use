from dataclasses import dataclass
from pathlib import Path

import scripts.mineru_convert as mineru_convert
from scripts.mineru_config import Settings


def test_main_routes_image_to_mineru(tmp_path: Path, monkeypatch, capsys):
    source = tmp_path / "photo.png"
    source.write_bytes(b"png")

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token="test-token")
    )
    monkeypatch.setattr(
        mineru_convert, "convert_files", lambda *a, **kw: []
    )
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(source)])

    result = mineru_convert.main()

    assert result == 0


def test_main_routes_image_prefer_multimodal(tmp_path: Path, monkeypatch, capsys):
    source = tmp_path / "photo.png"
    source.write_bytes(b"png")

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings())
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--prefer-multimodal", str(source)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 2
    assert "multimodal-looker" in captured.out
    assert str(source) in captured.out


def test_main_requires_token_for_supported_files(tmp_path: Path, monkeypatch, capsys):
    pdf = tmp_path / "digital.pdf"
    pdf.write_bytes(b"%PDF-1.7\nBT /F1 12 Tf (Hello world) Tj ET\n/Font")

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token=None)
    )
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(pdf)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 2
    assert "MINERU_TOKEN" in captured.err


def test_main_routes_xlsx_to_mineru(tmp_path: Path, monkeypatch, capsys):
    xlsx = tmp_path / "sheet.xlsx"
    xlsx.write_bytes(b"PK\x03\x04")

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token="test-token")
    )
    monkeypatch.setattr(
        mineru_convert, "convert_files", lambda *a, **kw: []
    )
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(xlsx)])

    result = mineru_convert.main()

    assert result == 0


def test_main_unsupported_only_exits_2(tmp_path: Path, monkeypatch, capsys):
    csv = tmp_path / "data.csv"
    csv.write_bytes(b"a,b")

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings())
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(csv)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 2
    assert "不支持" in captured.err


def test_main_mixed_supported_unsupported(tmp_path: Path, monkeypatch, capsys):
    pdf = tmp_path / "report.pdf"
    pdf.write_bytes(b"%PDF-1.7\nBT /F1 12 Tf (Hello world) Tj ET\n/Font")
    csv = tmp_path / "data.csv"
    csv.write_bytes(b"a,b")

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token="test-token")
    )
    monkeypatch.setattr(
        mineru_convert, "convert_files", lambda *a, **kw: []
    )
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(pdf), str(csv)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 0
    assert "不支持" in captured.err


def test_main_nonexistent_pdf_exits_2(tmp_path: Path, monkeypatch, capsys):
    missing = tmp_path / "missing.pdf"

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings())
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(missing)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 2


def test_main_no_legacy_route_names_in_output(tmp_path: Path, monkeypatch, capsys):
    csv = tmp_path / "data.csv"
    csv.write_bytes(b"a,b")

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings())
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(csv)])

    mineru_convert.main()
    captured = capsys.readouterr()

    assert "fallback" not in captured.out
    assert "fallback" not in captured.err
    assert "markdown-converter" not in captured.out
    assert "markdown-converter" not in captured.err


def _make_fake_rendered(tmp_path: Path, name: str, *, has_json: bool):
    from scripts.mineru_outputs import OutputTargets

    md = tmp_path / "_mineru" / f"{name}.md"
    md.parent.mkdir(parents=True, exist_ok=True)
    md.write_text("这是足够长的正常文档内容，长度超过二十个字符以满足空输出门控。", encoding="utf-8")

    json_dir = tmp_path / "_mineru" / f"{name}.json"
    json_files: dict[str, Path] = {}
    if has_json:
        json_dir.mkdir(exist_ok=True)
        cl = json_dir / f"{name}.content_list.json"
        cl.write_text("[]", encoding="utf-8")
        json_files["content_list"] = cl
    else:
        json_files = {}

    return OutputTargets(
        markdown=md,
        json_dir=json_dir if has_json else None,
        json_files=json_files,
        images_dir=tmp_path / "_mineru" / f"{name}.images",
        manifest=tmp_path / "_mineru" / f"{name}.manifest.json",
        stem=name,
    )


def test_main_require_json_missing_exits_2(tmp_path: Path, monkeypatch, capsys):
    pdf = tmp_path / "report.pdf"
    pdf.write_bytes(b"%PDF-1.7")

    rendered = [_make_fake_rendered(tmp_path, "report", has_json=False)]

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token="tok")
    )
    monkeypatch.setattr(mineru_convert, "convert_files", lambda *a, **kw: rendered)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--require-json", str(pdf)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 2
    assert "missing_required_json" in captured.err
    assert "content_list" in captured.err


def test_main_require_json_present_exits_0(tmp_path: Path, monkeypatch, capsys):
    pdf = tmp_path / "report.pdf"
    pdf.write_bytes(b"%PDF-1.7")

    rendered = [_make_fake_rendered(tmp_path, "report", has_json=True)]

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token="tok")
    )
    monkeypatch.setattr(mineru_convert, "convert_files", lambda *a, **kw: rendered)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--require-json", str(pdf)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 0


def test_main_no_require_json_missing_warns_but_exits_0(tmp_path: Path, monkeypatch, capsys):
    pdf = tmp_path / "report.pdf"
    pdf.write_bytes(b"%PDF-1.7")

    rendered = [_make_fake_rendered(tmp_path, "report", has_json=False)]

    monkeypatch.setattr(
        mineru_convert, "load_settings", lambda config: Settings(token="tok")
    )
    monkeypatch.setattr(mineru_convert, "convert_files", lambda *a, **kw: rendered)
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(pdf)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 0
    assert "content_list" in captured.err or "JSON" in captured.err
