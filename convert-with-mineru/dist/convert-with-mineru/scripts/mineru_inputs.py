from __future__ import annotations

from pathlib import Path


MINEU_EXTENSIONS = {
    ".pdf",
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".htm",
    ".html",
}

# Excel 不被 MineU precision API 支持，路由到 fallback
EXCEL_EXTENSIONS = {".xls", ".xlsx"}

FALLBACK_EXTENSIONS = {
    ".csv",
    ".tsv",
    ".json",
    ".xml",
    ".epub",
    ".zip",
} | EXCEL_EXTENSIONS

MULTIMODAL_EXTENSIONS = {".png", ".jpg", ".jpeg"}

PDF_TEXT_MARKERS = (b"/Font", b"BT", b"Tj", b"TJ", b"Tf", b"/ToUnicode")
PDF_IMAGE_MARKERS = (b"/Subtype /Image", b"/Image", b"/XObject", b" Do")

KNOWN_EXTENSIONS = MINEU_EXTENSIONS | FALLBACK_EXTENSIONS | MULTIMODAL_EXTENSIONS
OUTPUT_DIRECTORY_SUFFIXES = {".images", ".json", ".raw"}


def _is_excluded(path: Path, excluded_roots: list[Path]) -> bool:
    resolved = path.resolve()
    if any(resolved.is_relative_to(root) for root in excluded_roots):
        return True
    for parent in resolved.parents:
        if parent.suffix.lower() in OUTPUT_DIRECTORY_SUFFIXES:
            return True
        if parent.name.lower().startswith("_mineru"):
            return True
    return False


def discover_inputs(
    inputs: list[str | Path],
    recursive: bool = False,
    exclude_roots: list[str | Path] | None = None,
) -> list[Path]:
    discovered: list[Path] = []
    excluded = [Path(root).resolve() for root in (exclude_roots or [])]
    for item in inputs:
        path = Path(item)
        if path.is_file():
            if path.suffix.lower() in KNOWN_EXTENSIONS and not _is_excluded(
                path, excluded
            ):
                discovered.append(path)
            continue
        if path.is_dir():
            iterator = path.rglob("*") if recursive else path.glob("*")
            for candidate in iterator:
                if (
                    candidate.is_file()
                    and candidate.suffix.lower() in KNOWN_EXTENSIONS
                    and not _is_excluded(candidate, excluded)
                ):
                    discovered.append(candidate)
    return sorted(discovered, key=lambda value: str(value).lower())


def split_supported_and_fallback(paths: list[Path]) -> tuple[list[Path], list[Path]]:
    supported = [path for path in paths if path.suffix.lower() in MINEU_EXTENSIONS]
    fallback = [path for path in paths if path.suffix.lower() in FALLBACK_EXTENSIONS]
    return supported, fallback


def is_probably_digital_pdf(path: Path, sniff_bytes: int = 512_000) -> bool:
    if path.suffix.lower() != ".pdf":
        return False
    try:
        payload = path.read_bytes()[:sniff_bytes]
    except OSError:
        return False
    if not payload.startswith(b"%PDF"):
        return False

    text_hits = sum(marker in payload for marker in PDF_TEXT_MARKERS)
    image_hits = sum(marker in payload for marker in PDF_IMAGE_MARKERS)
    if text_hits >= 2:
        return True
    if text_hits == 1 and image_hits == 0:
        return True
    return False


def route_file(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in FALLBACK_EXTENSIONS:
        return "fallback"
    if suffix in MULTIMODAL_EXTENSIONS:
        return "multimodal_looker"
    if suffix == ".pdf":
        return "mineu" if is_probably_digital_pdf(path) else "multimodal_looker"
    if suffix in MINEU_EXTENSIONS:
        return "mineu"
    return "fallback"


def split_routed_inputs(paths: list[Path]) -> dict[str, list[Path]]:
    routed = {"mineu": [], "multimodal_looker": [], "fallback": []}
    for path in paths:
        routed[route_file(path)].append(path)
    return routed
