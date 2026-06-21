import json
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

    manifest = tmp_path / "_mineru" / f"{name}.manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "manifest_version": "1.0",
                "batch_id": "fixed-batch",
                "source_path": str(tmp_path / f"{name}.pdf"),
                "relative_source_path": f"{name}.pdf",
                "allocated_stem": name,
                "route": "mineru",
                "model": "default",
                "conversion_status": "success",
                "output_md": str(md),
                "output_json_dir": str(json_dir) if has_json else None,
                "output_images_dir": str(tmp_path / "_mineru" / f"{name}.images"),
                "per_file_manifest": str(manifest),
                "raw_archive_path": str(tmp_path / "_review" / "raw" / name),
                "raw_archive_status": "archived",
                "image_status": "none_produced",
                "image_count": 0,
                "json_status": "ok" if has_json else "none",
                "quality_gate": {"status": "not_run", "passed": None, "failed_gates": []},
                "errors": [],
                "warnings": [],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    return OutputTargets(
        markdown=md,
        json_dir=json_dir if has_json else None,
        json_files=json_files,
        images_dir=tmp_path / "_mineru" / f"{name}.images",
        manifest=manifest,
        stem=name,
    )


def test_main_audit_dir_overrides_settings_and_writes_batch_manifest(tmp_path: Path, monkeypatch):
    pdf = tmp_path / "report.pdf"
    pdf.write_bytes(b"%PDF-1.7")
    audit_dir = tmp_path / "custom-audit"
    rendered = [_make_fake_rendered(tmp_path, "report", has_json=True)]
    calls = []

    def fake_convert_files(sources, output_root, **kwargs):
        calls.append(kwargs)
        return rendered

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings(token="tok", audit_dir=str(tmp_path / "env-audit")))
    monkeypatch.setattr(mineru_convert, "_new_batch_id", lambda: "fixed-batch")
    monkeypatch.setattr(mineru_convert, "convert_files", fake_convert_files)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--audit-dir", str(audit_dir), str(pdf)])

    result = mineru_convert.main()

    assert result == 0
    assert calls[0]["audit_dir"] == audit_dir
    manifest = json.loads((audit_dir / "mineru_manifest.json").read_text(encoding="utf-8"))
    assert list(manifest) == ["report.pdf"]
    assert manifest["report.pdf"]["quality_gate"]["status"] == "passed"


def test_main_splits_mineru_and_html_routes_for_audit(tmp_path: Path, monkeypatch):
    pdf = tmp_path / "report.pdf"
    html = tmp_path / "page.html"
    pdf.write_bytes(b"%PDF-1.7")
    html.write_text("<html></html>", encoding="utf-8")
    audit_dir = tmp_path / "audit"
    calls = []

    def fake_convert_files(sources, output_root, **kwargs):
        calls.append((list(sources), kwargs))
        name = Path(sources[0]).stem
        return [_make_fake_rendered(tmp_path, name, has_json=True)]

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings(token="tok"))
    monkeypatch.setattr(mineru_convert, "_new_batch_id", lambda: "fixed-batch")
    monkeypatch.setattr(mineru_convert, "convert_files", fake_convert_files)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--audit-dir", str(audit_dir), str(pdf), str(html)])

    assert mineru_convert.main() == 0
    assert [call[1]["route"] for call in calls] == ["mineru", "mineru_html"]
    assert [call[1]["model"] for call in calls] == ["default", "MinerU-HTML"]


def test_main_unsupported_file_does_not_break_supported_batch_manifest(tmp_path: Path, monkeypatch):
    pdf = tmp_path / "report.pdf"
    csv = tmp_path / "data.csv"
    pdf.write_bytes(b"%PDF-1.7")
    csv.write_bytes(b"a,b")
    audit_dir = tmp_path / "audit"
    rendered = [_make_fake_rendered(tmp_path, "report", has_json=True)]

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings(token="tok"))
    monkeypatch.setattr(mineru_convert, "_new_batch_id", lambda: "fixed-batch")
    monkeypatch.setattr(mineru_convert, "convert_files", lambda *a, **kw: rendered)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--audit-dir", str(audit_dir), str(pdf), str(csv)])

    assert mineru_convert.main() == 0
    manifest = json.loads((audit_dir / "mineru_manifest.json").read_text(encoding="utf-8"))
    assert list(manifest) == ["report.pdf"]


def test_main_quality_failure_updates_per_file_and_batch_manifest(tmp_path: Path, monkeypatch):
    pdf = tmp_path / "report.pdf"
    pdf.write_bytes(b"%PDF-1.7")
    audit_dir = tmp_path / "audit"
    rendered = [_make_fake_rendered(tmp_path, "report", has_json=False)]

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings(token="tok"))
    monkeypatch.setattr(mineru_convert, "_new_batch_id", lambda: "fixed-batch")
    monkeypatch.setattr(mineru_convert, "convert_files", lambda *a, **kw: rendered)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--audit-dir", str(audit_dir), "--require-json", str(pdf)])

    assert mineru_convert.main() == 2
    per_file = json.loads(rendered[0].manifest.read_text(encoding="utf-8"))
    batch = json.loads((audit_dir / "mineru_manifest.json").read_text(encoding="utf-8"))
    assert per_file["quality_gate"]["status"] == "failed"
    assert batch["report.pdf"]["quality_gate"]["status"] == "failed"


def test_main_records_failure_collector_entry_and_continues(tmp_path: Path, monkeypatch):
    bad = tmp_path / "bad.pdf"
    good = tmp_path / "good.pdf"
    bad.write_bytes(b"%PDF-1.7")
    good.write_bytes(b"%PDF-1.7")
    audit_dir = tmp_path / "audit"
    rendered = [_make_fake_rendered(tmp_path, "good", has_json=True)]

    def fake_convert_files(sources, output_root, **kwargs):
        kwargs["failure_collector"].append({"source_path": bad, "error": "boom", "route": kwargs["route"]})
        return rendered

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings(token="tok"))
    monkeypatch.setattr(mineru_convert, "_new_batch_id", lambda: "fixed-batch")
    monkeypatch.setattr(mineru_convert, "convert_files", fake_convert_files)
    monkeypatch.setattr("sys.argv", ["mineru_convert", "--audit-dir", str(audit_dir), str(bad), str(good)])

    assert mineru_convert.main() == 0
    manifest = json.loads((audit_dir / "mineru_manifest.json").read_text(encoding="utf-8"))
    assert manifest["bad.pdf"]["conversion_status"] == "failed"
    assert manifest["bad.pdf"]["output_md"] is None
    assert manifest["bad.pdf"]["quality_gate"]["status"] == "not_applicable"
    assert manifest["good.pdf"]["conversion_status"] == "success"


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
