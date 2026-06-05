from pathlib import Path

import pytest

from scripts.mineru_inputs import route_file, split_routed_inputs


ROUTING_MATRIX_CASES = [
    ("report.pdf", b"%PDF-1.7\nBT /F1 12 Tf (Hello world) Tj ET\n/Font", "mineru"),
    ("scan.pdf", b"%PDF-1.7\n/XObject /Image Do", "mineru"),
    ("report.docx", b"docx", "mineru"),
    ("memo.doc", b"doc", "mineru"),
    ("slides.pptx", b"PK\x03\x04", "mineru"),
    ("deck.ppt", b"ppt", "mineru"),
    ("page.html", b"<html></html>", "mineru_html"),
    ("page.htm", b"<html></html>", "mineru_html"),
    ("sheet.xlsx", b"PK\x03\x04", "mineru"),
    ("sheet.xls", b"\xd0\xcf\x11\xe0", "mineru"),
    ("photo.png", b"png", "mineru"),
    ("photo.jpg", b"jpg", "mineru"),
    ("photo.jpeg", b"jpeg", "mineru"),
    ("photo.jp2", b"jp2", "mineru"),
    ("photo.webp", b"webp", "mineru"),
    ("photo.gif", b"gif", "mineru"),
    ("photo.bmp", b"bmp", "mineru"),
    ("data.csv", b"a,b", "unsupported"),
    ("data.tsv", b"a\tb", "unsupported"),
    ("data.json", b"{}", "unsupported"),
    ("data.xml", b"<x/>", "unsupported"),
    ("book.epub", b"epub", "unsupported"),
    ("archive.zip", b"PK\x03\x04", "unsupported"),
]


@pytest.mark.parametrize(
    "filename,content,expected_route",
    ROUTING_MATRIX_CASES,
    ids=[c[0] for c in ROUTING_MATRIX_CASES],
)
def test_routing_matrix(tmp_path, filename, content, expected_route):
    source = tmp_path / filename
    source.write_bytes(content)
    assert route_file(source) == expected_route


def test_routing_matrix_nonexistent_file(tmp_path):
    source = tmp_path / "missing.pdf"
    assert route_file(source) == "invalid_input"


def test_routing_matrix_zero_byte_pdf(tmp_path):
    source = tmp_path / "empty.pdf"
    source.write_bytes(b"")
    assert route_file(source) == "invalid_input"


def test_routing_matrix_zero_byte_image(tmp_path):
    source = tmp_path / "empty.png"
    source.write_bytes(b"")
    assert route_file(source) == "invalid_input"


def test_routing_matrix_unknown_extension(tmp_path):
    source = tmp_path / "readme.md"
    source.write_text("hello", encoding="utf-8")
    assert route_file(source) == "unsupported"


CANONICAL_ROUTES = {"mineru", "mineru_html", "multimodal_looker", "unsupported", "invalid_input"}


def test_route_file_returns_canonical_value(tmp_path):
    source = tmp_path / "report.docx"
    source.write_bytes(b"docx")
    result = route_file(source)
    assert result in CANONICAL_ROUTES


def test_split_routed_inputs_uses_canonical_keys(tmp_path):
    docx = tmp_path / "report.docx"
    html = tmp_path / "page.html"
    csv = tmp_path / "data.csv"
    docx.write_bytes(b"docx")
    html.write_bytes(b"<html></html>")
    csv.write_bytes(b"a,b")

    routed = split_routed_inputs([docx, html, csv])

    for key in routed:
        assert key in CANONICAL_ROUTES, f"non-canonical route key: {key}"


def test_split_routed_inputs_no_legacy_keys(tmp_path):
    docx = tmp_path / "report.docx"
    docx.write_bytes(b"docx")

    routed = split_routed_inputs([docx])

    assert "mineu" not in routed
    assert "fallback" not in routed


def test_split_routed_inputs_groups_html_separately(tmp_path):
    docx = tmp_path / "report.docx"
    html = tmp_path / "page.html"
    docx.write_bytes(b"docx")
    html.write_bytes(b"<html></html>")

    routed = split_routed_inputs([docx, html])

    assert routed["mineru"] == [docx]
    assert routed["mineru_html"] == [html]
