from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class GateFailure:
    source: str
    gate_id: str
    reason: str
    suggested_route: str = ""


@dataclass
class QualityGateResult:
    passed: bool
    failed_gates: list[GateFailure] = field(default_factory=list)


_META_SEPARATOR = re.compile(r"^[\s\-=_*#|>]+$")


def _strip_whitespace(text: str) -> str:
    return re.sub(r"\s+", "", text)


def _check_empty_output(markdown: str, source: str) -> GateFailure | None:
    stripped = _strip_whitespace(markdown)
    if len(stripped) < 20:
        return GateFailure(
            source=source,
            gate_id="empty_output",
            reason=f"去空白后内容长度 {len(stripped)} < 20",
            suggested_route="multimodal_looker",
        )
    return None


def _check_repetition_consecutive(markdown: str, source: str) -> GateFailure | None:
    lines = markdown.splitlines()
    normalized = []
    for line in lines:
        s = line.strip()
        if not s or _META_SEPARATOR.match(s):
            normalized.append(None)
        else:
            normalized.append(s)

    count = 1
    for i in range(1, len(normalized)):
        if normalized[i] is None or normalized[i - 1] is None:
            count = 1
            continue
        if normalized[i] == normalized[i - 1]:
            count += 1
            if count >= 3:
                return GateFailure(
                    source=source,
                    gate_id="repetition_consecutive",
                    reason=f"同一行连续重复 >=3 次: '{normalized[i][:50]}'",
                    suggested_route="multimodal_looker",
                )
        else:
            count = 1
    return None


def _check_repetition_global(markdown: str, source: str) -> GateFailure | None:
    from collections import Counter

    lines = markdown.splitlines()
    long_lines = [
        line.strip() for line in lines if len(line.strip()) >= 20
    ]
    counts = Counter(long_lines)
    for line, cnt in counts.items():
        if cnt >= 5:
            return GateFailure(
                source=source,
                gate_id="repetition_global",
                reason=f"长度>=20的行全文出现 >=5 次: '{line[:50]}'",
                suggested_route="multimodal_looker",
            )
    return None


def _check_garbled_text(markdown: str, source: str) -> GateFailure | None:
    replacement_count = markdown.count("\ufffd")
    control_chars = sum(
        1
        for ch in markdown
        if ord(ch) < 32 and ch not in "\n\r\t\f"
    )
    if replacement_count >= 3 or control_chars > 0:
        return GateFailure(
            source=source,
            gate_id="garbled_text",
            reason=f"替换符 {replacement_count} 个, 非法控制字符 {control_chars} 个",
            suggested_route="multimodal_looker",
        )

    total_chars = max(len(markdown), 1)
    if (replacement_count + control_chars) / total_chars > 0.02:
        return GateFailure(
            source=source,
            gate_id="garbled_text",
            reason=f"乱码比例 {(replacement_count + control_chars) / total_chars:.4f} > 0.02",
            suggested_route="multimodal_looker",
        )
    return None


def _check_missing_image_path(
    markdown: str,
    images_dir: Path | None,
    source_path: Path,
    source: str,
) -> GateFailure | None:
    pattern = re.compile(r"!\[([^\]]*)\]\(([^)]+)\)")
    matches = pattern.findall(markdown)
    for _, path_str in matches:
        if path_str.startswith(("http:", "https:", "data:")):
            continue
        if images_dir is None:
            return GateFailure(
                source=source,
                gate_id="missing_image_path",
                reason=f"引用本地图片 '{path_str}' 但无 images_dir",
                suggested_route="multimodal_looker",
            )
        resolved = images_dir / path_str
        if not resolved.exists():
            return GateFailure(
                source=source,
                gate_id="missing_image_path",
                reason=f"本地图片路径不存在: {resolved}",
                suggested_route="multimodal_looker",
            )
    return None


def _check_missing_required_json(
    json_files: dict[str, Path],
    require_json: bool,
    source: str,
) -> GateFailure | None:
    if not require_json:
        return None
    content_list = json_files.get("content_list")
    if content_list is None or not content_list.exists():
        missing = str(content_list) if content_list else "content_list (未定义)"
        return GateFailure(
            source=source,
            gate_id="missing_required_json",
            reason=f"--require-json 但 JSON 缺失: {missing}",
            suggested_route="retry_with_json",
        )
    return None


def _check_insufficient_page_coverage(
    markdown: str,
    page_count: int | None,
    source: str,
) -> GateFailure | None:
    if page_count is None or not isinstance(page_count, int) or page_count < 2:
        return None
    stripped_len = len(_strip_whitespace(markdown))
    threshold = max(20 * page_count, 40)
    if stripped_len < threshold:
        return GateFailure(
            source=source,
            gate_id="insufficient_page_coverage",
            reason=f"{page_count} 页但去空白长度 {stripped_len} < {threshold}",
            suggested_route="multimodal_looker",
        )
    return None


def check_quality_gates(
    markdown: str,
    page_count: int | None = None,
    json_files: dict[str, Path] | None = None,
    images_dir: Path | None = None,
    require_json: bool = False,
    source: Path | None = None,
) -> QualityGateResult:
    source_str = str(source) if source else "unknown"
    source_path = source or Path(".")
    if json_files is None:
        json_files = {}

    failed: list[GateFailure] = []

    gate = _check_empty_output(markdown, source_str)
    if gate:
        failed.append(gate)

    if not failed:
        gate = _check_repetition_consecutive(markdown, source_str)
        if gate:
            failed.append(gate)

    if not failed:
        gate = _check_repetition_global(markdown, source_str)
        if gate:
            failed.append(gate)

    if not failed:
        gate = _check_garbled_text(markdown, source_str)
        if gate:
            failed.append(gate)

    if not failed:
        gate = _check_missing_image_path(markdown, images_dir, source_path, source_str)
        if gate:
            failed.append(gate)

    gate = _check_missing_required_json(json_files, require_json, source_str)
    if gate:
        failed.append(gate)

    gate = _check_insufficient_page_coverage(markdown, page_count, source_str)
    if gate:
        failed.append(gate)

    return QualityGateResult(passed=len(failed) == 0, failed_gates=failed)
