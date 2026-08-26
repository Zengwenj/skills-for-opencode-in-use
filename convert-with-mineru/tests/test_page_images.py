from pathlib import Path

import pymupdf

from scripts.mineru_pages import (
    collect_page_images,
    preflight_image,
)


def _make_pdf(path: Path, pages: int = 2, width: int = 595, height: int = 842) -> Path:
    doc = pymupdf.open()
    for _ in range(pages):
        page = doc.new_page(width=width, height=height)
        page.insert_text((72, 120), "手写测试内容")
    doc.save(str(path))
    doc.close()
    return path


def _make_png(path: Path, width: int, height: int) -> Path:
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, width, height))
    pixmap.clear_with(255)
    pixmap.save(str(path))
    return path


class TestPdfPageRendering:
    def test_pdf_renders_each_page_as_png(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=3)

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.degraded_reason is None
        assert [p.page_number for p in collection.pages] == [1, 2, 3]
        for page in collection.pages:
            assert page.path.name == f"page-{page.page_number:03d}.png"
            assert page.path.exists() and page.path.stat().st_size > 0

    def test_single_page_pdf_yields_one_page(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "one.pdf", pages=1)

        collection = collect_page_images(source, tmp_path / "pages")

        assert len(collection.pages) == 1
        assert collection.pages[0].path.name == "page-001.png"

    def test_corrupt_pdf_degrades_with_reason(self, tmp_path: Path):
        source = tmp_path / "broken.pdf"
        source.write_bytes(b"this is not a pdf")

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.pages == []
        assert collection.degraded_reason is not None
        assert "无法打开" in collection.degraded_reason

    def test_encrypted_pdf_degrades_with_reason(self, tmp_path: Path):
        source = tmp_path / "locked.pdf"
        doc = _make_pdf(tmp_path / "plain.pdf", pages=1)
        src_doc = pymupdf.open(str(doc))
        src_doc.save(
            str(source),
            encryption=pymupdf.PDF_ENCRYPT_AES_256,
            owner_pw="owner",
            user_pw="user",
        )
        src_doc.close()

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.pages == []
        assert collection.degraded_reason is not None
        assert "加密" in collection.degraded_reason

    def test_wide_pdf_page_warns_double_page_scan(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "wide.pdf", pages=1, width=1400, height=595)

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.degraded_reason is None
        assert any("双页粘连" in warning for warning in collection.warnings)


class TestImageInput:
    def test_image_input_copies_source_as_page_001(self, tmp_path: Path):
        source = _make_png(tmp_path / "scan.png", 2480, 3508)

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.degraded_reason is None
        assert len(collection.pages) == 1
        copied = collection.pages[0].path
        assert copied.name == "page-001.png"
        assert copied.read_bytes() == source.read_bytes()

    def test_jpeg_keeps_original_suffix(self, tmp_path: Path):
        source = tmp_path / "scan.jpg"
        pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, 2480, 3508))
        pixmap.clear_with(255)
        pixmap.save(str(source), jpg_quality=90)

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.pages[0].path.name == "page-001.jpg"

    def test_unreadable_image_copy_still_warns_preflight_skip(self, tmp_path: Path):
        source = tmp_path / "fake.png"
        source.write_bytes(b"not really a png")

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.degraded_reason is None
        assert collection.pages[0].path.exists()
        assert any("预检跳过" in warning for warning in collection.warnings)

    def test_unsupported_suffix_degrades(self, tmp_path: Path):
        source = tmp_path / "memo.docx"
        source.write_bytes(b"PK\x03\x04")

        collection = collect_page_images(source, tmp_path / "pages")

        assert collection.pages == []
        assert collection.degraded_reason is not None
        assert "不支持" in collection.degraded_reason


class TestPreflight:
    def test_low_resolution_image_warns(self, tmp_path: Path):
        source = _make_png(tmp_path / "small.png", 500, 700)

        warnings = preflight_image(source)

        assert any("分辨率偏低" in warning for warning in warnings)

    def test_double_page_aspect_warns(self, tmp_path: Path):
        source = _make_png(tmp_path / "wide.png", 2000, 700)

        warnings = preflight_image(source)

        assert any("双页粘连" in warning for warning in warnings)

    def test_normal_scan_has_no_warnings(self, tmp_path: Path):
        source = _make_png(tmp_path / "a4.png", 2480, 3508)

        warnings = preflight_image(source)

        assert warnings == []

    def test_preflight_uses_long_side_dpi_estimate_for_landscape(self, tmp_path: Path):
        # 横向 A4 扫描：长边 3508px ≈ 300 DPI，不应告警
        source = _make_png(tmp_path / "landscape.png", 3508, 2480)

        warnings = preflight_image(source)

        assert warnings == []
