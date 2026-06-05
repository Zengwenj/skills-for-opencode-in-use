from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

from scripts.mineru_quality import (
    QualityGateResult,
    check_quality_gates,
)


def _result(
    markdown: str | None = None,
    page_count: int | None = None,
    json_files: dict[str, Path] | None = None,
    images_dir: Path | None = None,
    require_json: bool = False,
    source: Path | None = None,
) -> QualityGateResult:
    if markdown is None:
        markdown = "这是一段正常的文档内容，长度超过二十个字符以满足空输出门控的最低要求。"
    return check_quality_gates(
        markdown=markdown,
        page_count=page_count,
        json_files=json_files,
        images_dir=images_dir,
        require_json=require_json,
        source=source or Path("test.pdf"),
    )


class TestEmptyOutput:
    def test_short_content_fails(self):
        r = _result(markdown="  \n  \n")
        assert not r.passed
        assert any(g.gate_id == "empty_output" for g in r.failed_gates)

    def test_none_markdown_fails(self):
        r = _result(markdown="")
        assert not r.passed
        assert any(g.gate_id == "empty_output" for g in r.failed_gates)

    def test_adequate_content_passes(self):
        r = _result(markdown="这是一段正常内容，长度足够通过空输出检查。")
        assert r.passed


class TestRepetitionConsecutive:
    def test_three_same_lines_fails(self):
        line = "这是重复的一行内容，足够长度来触发检测。"
        md = f"{line}\n{line}\n{line}\n"
        r = _result(markdown=md)
        assert not r.passed
        assert any(g.gate_id == "repetition_consecutive" for g in r.failed_gates)

    def test_two_same_lines_passes(self):
        line = "这是重复的一行内容，足够长度来触发检测。"
        md = f"{line}\n{line}\n"
        r = _result(markdown=md)
        assert r.passed

    def test_separator_lines_excluded(self):
        md = "---\n---\n---\n正常内容，足够长度以避免空输出门控。"
        r = _result(markdown=md)
        assert r.passed


class TestRepetitionGlobal:
    def test_five_occurrences_fails(self):
        line = "这是全局重复的一行，足够长以触发全局检测门控。"
        parts = [f"第{i}段\n{line}\n" for i in range(5)]
        md = "\n".join(parts)
        r = _result(markdown=md)
        assert not r.passed
        assert any(g.gate_id == "repetition_global" for g in r.failed_gates)

    def test_four_occurrences_passes(self):
        line = "这是全局重复的一行，足够长以触发全局检测门控。"
        parts = [f"第{i}段\n{line}\n" for i in range(4)]
        md = "\n".join(parts)
        r = _result(markdown=md)
        assert r.passed


class TestGarbledText:
    def test_replacement_chars_fails(self):
        md = "正常内容开始\n\ufffd\ufffd\ufffd\ufffd\n" + "足够长度以避免空输出。" * 3
        r = _result(markdown=md)
        assert not r.passed
        assert any(g.gate_id == "garbled_text" for g in r.failed_gates)

    def test_control_chars_fails(self):
        md = "正常内容开始\n\x00\x01\x02\n" + "足够长度以避免空输出。" * 3
        r = _result(markdown=md)
        assert not r.passed
        assert any(g.gate_id == "garbled_text" for g in r.failed_gates)

    def test_clean_text_passes(self):
        md = "这是干净正常的文本内容，没有乱码字符。" * 5
        r = _result(markdown=md)
        assert r.passed

    def test_allowed_whitespace_passes(self):
        md = "正常内容\t有制表符\n\r\n换行\n\f换页\n" + "足够长度以避免空输出。" * 3
        r = _result(markdown=md)
        assert r.passed


class TestMissingImagePath:
    def test_missing_local_image_fails(self, tmp_path: Path):
        md = "![img](missing.png)\n" + "足够长度以避免空输出。" * 3
        r = _result(
            markdown=md,
            images_dir=tmp_path / "test.images",
            source=tmp_path / "test.md",
        )
        assert not r.passed
        assert any(g.gate_id == "missing_image_path" for g in r.failed_gates)

    def test_existing_local_image_passes(self, tmp_path: Path):
        img_dir = tmp_path / "test.images"
        img_dir.mkdir()
        (img_dir / "exists.png").write_bytes(b"\x89PNG")
        md = "![img](exists.png)\n" + "足够长度以避免空输出。" * 3
        r = _result(markdown=md, images_dir=img_dir, source=tmp_path / "test.md")
        assert r.passed

    def test_http_image_skips_check(self):
        md = "![img](https://example.com/img.png)\n" + "足够长度以避免空输出。" * 3
        r = _result(markdown=md)
        assert r.passed

    def test_data_uri_skips_check(self):
        md = "![img](data:image/png;base64,abc)\n" + "足够长度以避免空输出。" * 3
        r = _result(markdown=md)
        assert r.passed


class TestMissingRequiredJson:
    def test_require_json_missing_fails(self):
        r = _result(
            json_files={},
            require_json=True,
        )
        assert not r.passed
        assert any(g.gate_id == "missing_required_json" for g in r.failed_gates)

    def test_require_json_present_passes(self, tmp_path: Path):
        cl = tmp_path / "test.content_list.json"
        cl.write_text("[]", encoding="utf-8")
        r = _result(
            json_files={"content_list": cl},
            require_json=True,
        )
        assert r.passed

    def test_no_require_json_missing_passes(self):
        r = _result(json_files={}, require_json=False)
        assert r.passed


class TestInsufficientPageCoverage:
    def test_short_multi_page_fails(self):
        r = _result(markdown="短", page_count=5)
        assert not r.passed
        assert any(g.gate_id == "insufficient_page_coverage" for g in r.failed_gates)

    def test_adequate_multi_page_passes(self):
        md = "内容" * 200
        r = _result(markdown=md, page_count=5)
        assert r.passed

    def test_single_page_skips_check(self):
        r = _result(page_count=1)
        assert r.passed

    def test_none_page_count_skips_check(self):
        r = _result(page_count=None)
        assert r.passed


class TestGateResultStructure:
    def test_failed_gate_has_source_gate_reason(self):
        r = _result(markdown="")
        assert not r.passed
        gate = r.failed_gates[0]
        assert gate.source == "test.pdf"
        assert gate.gate_id
        assert gate.reason

    def test_passed_has_no_failed_gates(self):
        r = _result()
        assert r.passed
        assert r.failed_gates == []
