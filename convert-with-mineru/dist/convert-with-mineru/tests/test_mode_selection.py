from pathlib import Path

from scripts.mineru_inputs import route_file, split_routed_inputs


def test_route_docx_to_mineu(tmp_path: Path):
    source = tmp_path / "report.docx"
    source.write_text("docx", encoding="utf-8")

    assert route_file(source) == "mineu"


def test_route_image_to_multimodal_looker(tmp_path: Path):
    source = tmp_path / "scan.png"
    source.write_bytes(b"png")

    assert route_file(source) == "multimodal_looker"


def test_route_digital_pdf_to_mineu(tmp_path: Path):
    source = tmp_path / "digital.pdf"
    source.write_bytes(
        b"%PDF-1.7\n1 0 obj\n<< /Type /Page /Resources << /Font << /F1 2 0 R >> >> >>\nstream\nBT /F1 12 Tf (Hello world) Tj ET\nendstream\n"
    )

    assert route_file(source) == "mineu"


def test_route_scanned_pdf_to_multimodal_looker(tmp_path: Path):
    source = tmp_path / "scan.pdf"
    source.write_bytes(
        b"%PDF-1.7\n1 0 obj\n<< /Type /Page /Resources << /XObject << /Im1 2 0 R >> >> >>\nstream\nq\n100 0 0 100 0 0 cm\n/Im1 Do\nQ\nendstream\n"
    )

    assert route_file(source) == "multimodal_looker"


def test_route_csv_to_fallback(tmp_path: Path):
    source = tmp_path / "data.csv"
    source.write_text("a,b", encoding="utf-8")

    assert route_file(source) == "fallback"


def test_route_xlsx_to_fallback(tmp_path: Path):
    source = tmp_path / "sheet.xlsx"
    source.write_bytes(b"PK\x03\x04")

    assert route_file(source) == "fallback"


def test_route_xls_to_fallback(tmp_path: Path):
    source = tmp_path / "sheet.xls"
    source.write_bytes(b"\xd0\xcf\x11\xe0")

    assert route_file(source) == "fallback"


def test_route_html_to_mineu(tmp_path: Path):
    source = tmp_path / "page.html"
    source.write_text("<html></html>", encoding="utf-8")

    assert route_file(source) == "mineu"


def test_route_pptx_to_mineu(tmp_path: Path):
    source = tmp_path / "slides.pptx"
    source.write_bytes(b"PK\x03\x04")

    assert route_file(source) == "mineu"


def test_split_routed_inputs_groups_files_by_target(tmp_path: Path):
    digital_pdf = tmp_path / "digital.pdf"
    image = tmp_path / "scan.jpg"
    fallback_json = tmp_path / "data.json"
    fallback_xlsx = tmp_path / "sheet.xlsx"
    digital_pdf.write_bytes(b"%PDF-1.7\nBT /F1 12 Tf (Hello world) Tj ET\n/Font")
    image.write_bytes(b"jpg")
    fallback_json.write_text("{}", encoding="utf-8")
    fallback_xlsx.write_bytes(b"PK\x03\x04")

    routed = split_routed_inputs([digital_pdf, image, fallback_json, fallback_xlsx])

    assert routed["mineu"] == [digital_pdf]
    assert routed["multimodal_looker"] == [image]
    assert sorted(routed["fallback"], key=str) == sorted(
        [fallback_json, fallback_xlsx], key=str
    )
