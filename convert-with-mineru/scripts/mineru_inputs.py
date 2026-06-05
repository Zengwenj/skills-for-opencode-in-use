from __future__ import annotations

from pathlib import Path


MINERU_EXTENSIONS = {
    ".pdf",
    ".doc",
    ".docx",
    ".ppt",
    ".pptx",
    ".xls",
    ".xlsx",
    ".htm",
    ".html",
    ".png",
    ".jpg",
    ".jpeg",
    ".jp2",
    ".webp",
    ".gif",
    ".bmp",
}

UNSUPPORTED_EXTENSIONS = {
    ".csv",
    ".tsv",
    ".json",
    ".xml",
    ".epub",
    ".zip",
}

PDF_TEXT_MARKERS = (b"/Font", b"BT", b"Tj", b"TJ", b"Tf", b"/ToUnicode")
PDF_IMAGE_MARKERS = (b"/Subtype /Image", b"/Image", b"/XObject", b" Do")

KNOWN_EXTENSIONS = MINERU_EXTENSIONS | UNSUPPORTED_EXTENSIONS
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


def route_file(path: Path, prefer_multimodal: bool = False) -> str:
    suffix = path.suffix.lower()

    if suffix in UNSUPPORTED_EXTENSIONS:
        return "unsupported"

    if suffix not in MINERU_EXTENSIONS:
        return "unsupported"

    if not path.exists() or not path.is_file():
        return "invalid_input"

    try:
        if path.stat().st_size == 0:
            return "invalid_input"
    except OSError:
        return "invalid_input"

    if suffix in {".htm", ".html"}:
        return "mineru_html"

    if prefer_multimodal and suffix in {".pdf", ".png", ".jpg", ".jpeg", ".jp2", ".webp", ".gif", ".bmp"}:
        return "multimodal_looker"

    return "mineru"


def split_routed_inputs(
    paths: list[Path], prefer_multimodal: bool = False
) -> dict[str, list[Path]]:
    routed: dict[str, list[Path]] = {}
    for path in paths:
        route = route_file(path, prefer_multimodal=prefer_multimodal)
        routed.setdefault(route, []).append(path)
    return routed
