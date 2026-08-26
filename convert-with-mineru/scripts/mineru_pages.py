from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import pymupdf


RENDER_DPI = 150
MIN_DPI_WARNING = 150
# A4 长边约 11.69 英寸，用最长边估算扫描 DPI
A4_LONG_SIDE_INCHES = 11.69
MAX_ASPECT_RATIO_WARNING = 2.0
MAX_PAGE_IMAGE_PATH_LENGTH = 240

IMAGE_SOURCE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".jp2", ".webp", ".gif", ".bmp"}


@dataclass
class PageImage:
    page_number: int
    path: Path


@dataclass
class PageCollection:
    pages: list[PageImage] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    degraded_reason: str | None = None


def _image_pixel_size(path: Path) -> tuple[int, int] | None:
    try:
        pixmap = pymupdf.Pixmap(str(path))
    except Exception:
        return None
    return (pixmap.width, pixmap.height)


def preflight_image(path: Path) -> list[str]:
    """提示级预检：分辨率不足、疑似双页粘连。只警告，不阻断。"""
    warnings: list[str] = []
    size = _image_pixel_size(path)
    if size is None:
        warnings.append(f"预检跳过：无法读取图像尺寸 {path.name}")
        return warnings
    width, height = size
    long_side = max(width, height)
    short_side = max(min(width, height), 1)
    dpi_estimate = long_side / A4_LONG_SIDE_INCHES
    if dpi_estimate < MIN_DPI_WARNING:
        warnings.append(
            f"分辨率偏低：估算 {dpi_estimate:.0f} DPI（阈值 {MIN_DPI_WARNING}），手写细节可能难以辨认"
        )
    aspect = long_side / short_side
    if aspect > MAX_ASPECT_RATIO_WARNING:
        warnings.append(
            f"宽高比 {aspect:.1f}:1 超过 {MAX_ASPECT_RATIO_WARNING}:1，疑似双页粘连扫描，请人工确认页切分"
        )
    return warnings


def _windows_path_too_long(path: Path) -> bool:
    return os.name == "nt" and len(str(path)) > MAX_PAGE_IMAGE_PATH_LENGTH


def _render_pdf_pages(
    source: Path, pages_dir: Path
) -> tuple[list[PageImage], list[str], str | None]:
    try:
        doc = pymupdf.open(str(source))
    except Exception as exc:
        return ([], [], f"PDF 无法打开（{exc}）")
    if doc.needs_pass:
        doc.close()
        return ([], [], "PDF 已加密，无法渲染页图")
    pages: list[PageImage] = []
    warnings: list[str] = []
    try:
        for index, page in enumerate(doc, start=1):
            rect = page.rect
            long_side = max(rect.width, rect.height)
            short_side = max(min(rect.width, rect.height), 1.0)
            if long_side / short_side > MAX_ASPECT_RATIO_WARNING:
                warnings.append(f"第 {index} 页宽高比异常，疑似双页粘连")
            target = pages_dir / f"page-{index:03d}.png"
            if _windows_path_too_long(target):
                return (pages, warnings, f"页图路径过长（>{MAX_PAGE_IMAGE_PATH_LENGTH} 字符）：{target}")
            try:
                pix = page.get_pixmap(dpi=RENDER_DPI)
                pix.save(str(target))
            except Exception as exc:
                return (pages, warnings, f"第 {index} 页渲染失败：{exc}")
            pages.append(PageImage(page_number=index, path=target))
    finally:
        doc.close()
    return (pages, warnings, None)


def collect_page_images(source: Path, pages_dir: Path) -> PageCollection:
    """收集页图证据：图片输入直接复制源文件；PDF 逐页渲染 PNG。"""
    suffix = source.suffix.lower()
    pages_dir.mkdir(parents=True, exist_ok=True)

    if suffix in IMAGE_SOURCE_EXTENSIONS:
        target = pages_dir / f"page-001{suffix}"
        if _windows_path_too_long(target):
            return PageCollection(
                [],
                [f"页图路径过长（>{MAX_PAGE_IMAGE_PATH_LENGTH} 字符）：{target}"],
                degraded_reason="path_too_long",
            )
        shutil.copyfile(source, target)
        return PageCollection(
            pages=[PageImage(page_number=1, path=target)],
            warnings=preflight_image(source),
        )

    if suffix == ".pdf":
        pages, warnings, degraded = _render_pdf_pages(source, pages_dir)
        return PageCollection(pages, warnings, degraded)

    return PageCollection([], [], degraded_reason=f"不支持的页图来源类型：{suffix}")
