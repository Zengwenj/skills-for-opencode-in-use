from dataclasses import dataclass
from pathlib import Path

import scripts.mineru_convert as mineru_convert
from scripts.mineru_config import Settings


def test_main_routes_image_input_to_multimodal_guidance(
    tmp_path: Path, monkeypatch, capsys
):
    source = tmp_path / "scan.png"
    source.write_bytes(b"png")

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings())
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(source)])

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


def test_main_routes_xlsx_to_fallback_guidance(tmp_path: Path, monkeypatch, capsys):
    xlsx = tmp_path / "sheet.xlsx"
    xlsx.write_bytes(b"PK\x03\x04")

    monkeypatch.setattr(mineru_convert, "load_settings", lambda config: Settings())
    monkeypatch.setattr("sys.argv", ["mineru_convert", str(xlsx)])

    result = mineru_convert.main()
    captured = capsys.readouterr()

    assert result == 2
    assert "fallback" in captured.out
    assert "xlsx" in captured.out.lower()
