import json
from pathlib import Path

import pymupdf
import pytest

from scripts.mineru_handwriting import (
    build_task_package,
    finalize_task_package,
    main,
    plan_batches,
    render_task_md,
)


def _make_pdf(path: Path, pages: int = 2) -> Path:
    doc = pymupdf.open()
    for _ in range(pages):
        page = doc.new_page(width=595, height=842)
        page.insert_text((72, 120), "手写测试内容")
    doc.save(str(path))
    doc.close()
    return path


def _make_png(path: Path, width: int = 2480, height: int = 3508) -> Path:
    pixmap = pymupdf.Pixmap(pymupdf.csRGB, pymupdf.IRect(0, 0, width, height))
    pixmap.clear_with(255)
    pixmap.save(str(path))
    return path


def _prepare_task(
    tmp_path: Path,
    *,
    source: Path,
    stem: str = "notes",
    draft_text: str = "第一页手写草稿内容，长度超过二十个字符以满足空输出门控要求。",
    images: list[str] | None = None,
) -> Path:
    output_root = tmp_path / "_mineru"
    output_root.mkdir(exist_ok=True)
    markdown = output_root / f"{stem}.md"
    markdown.write_text(draft_text, encoding="utf-8")
    images_dir = output_root / f"{stem}.images"
    if images:
        images_dir.mkdir(exist_ok=True)
        for name in images:
            (images_dir / name).write_bytes(b"png")
    manifest = output_root / f"{stem}.manifest.json"
    build_task_package(
        source=source,
        stem=stem,
        output_markdown=markdown,
        output_images_dir=images_dir,
        output_manifest=manifest,
        draft_markdown=markdown,
        task_root=output_root,
    )
    return output_root / f"{stem}.handwriting-task"


class TestPlanBatches:
    def test_zero_pages(self):
        assert plan_batches(0) == []

    def test_single_page(self):
        assert plan_batches(1) == [[1]]

    def test_ten_pages_single_batch(self):
        assert plan_batches(10) == [list(range(1, 11))]

    def test_eleven_pages_overlapping_batches(self):
        assert plan_batches(11) == [[1, 2, 3, 4, 5], [5, 6, 7, 8, 9], [9, 10, 11]]

    def test_twelve_pages_overlapping_batches(self):
        assert plan_batches(12) == [[1, 2, 3, 4, 5], [5, 6, 7, 8, 9], [9, 10, 11, 12]]

    def test_batches_cover_all_pages_with_one_page_overlap(self):
        batches = plan_batches(23)
        for previous, following in zip(batches, batches[1:]):
            assert following[0] == previous[-1]
        assert batches[-1][-1] == 23


class TestRenderTaskMd:
    def test_template_contains_core_principles(self):
        content = render_task_md("notes", 12, plan_batches(12))

        assert "手写文档校对任务：notes" in content
        assert "忠实抄录" in content
        assert "low-confidence" in content
        assert "uncertain" in content
        assert "gpt-5.6-terra:xhigh" in content
        assert "kimi-k3:max" in content
        assert "禁止使用 glm 系列模型" in content
        assert "$...$" in content
        assert "后批为准" in content

    def test_template_marks_single_batch(self):
        content = render_task_md("notes", 3, plan_batches(3))

        assert "单批处理全部页" in content


class TestPrepare:
    def test_image_input_creates_self_contained_package(self, tmp_path: Path):
        source = _make_png(tmp_path / "scan.png")

        task_dir = _prepare_task(tmp_path, source=source)

        task = json.loads((task_dir / "task.json").read_text(encoding="utf-8"))
        assert task["status"] == "prepared"
        assert task["page_count"] == 1
        assert task["batches"] == [[1]]
        assert (task_dir / "draft.md").exists()
        assert (task_dir / "TASK.md").exists()
        assert (task_dir / "pages" / "page-001.png").exists()

    def test_pdf_input_records_page_count(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=3)

        task_dir = _prepare_task(tmp_path, source=source)

        task = json.loads((task_dir / "task.json").read_text(encoding="utf-8"))
        assert task["page_count"] == 3
        assert task["batches"] == [[1, 2, 3]]
        assert len(task["paths"]["pages"]) == 3

    def test_degraded_pdf_marks_status(self, tmp_path: Path):
        source = tmp_path / "broken.pdf"
        source.write_bytes(b"not a pdf")

        task_dir = _prepare_task(tmp_path, source=source)

        task = json.loads((task_dir / "task.json").read_text(encoding="utf-8"))
        assert task["status"] == "degraded_pages"
        assert task["page_count"] == 0
        assert task["degraded_reason"]

    def test_gates_before_recorded(self, tmp_path: Path):
        source = _make_png(tmp_path / "scan.png")

        output_root = tmp_path / "_mineru"
        output_root.mkdir()
        markdown = output_root / "notes.md"
        markdown.write_text("草稿", encoding="utf-8")
        build_task_package(
            source=source,
            stem="notes",
            output_markdown=markdown,
            output_images_dir=output_root / "notes.images",
            output_manifest=output_root / "notes.manifest.json",
            draft_markdown=markdown,
            task_root=output_root,
            gates_before={"status": "failed", "passed": False, "failed_gates": []},
        )

        task = json.loads(
            (output_root / "notes.handwriting-task" / "task.json").read_text(
                encoding="utf-8"
            )
        )
        assert task["gates_before"]["status"] == "failed"


class TestFinalize:
    def _write_agent_outputs(self, task_dir: Path, supplement: str, revised: str):
        (task_dir / "supplement.md").write_text(supplement, encoding="utf-8")
        (task_dir / "revised.md").write_text(revised, encoding="utf-8")

    def test_missing_agent_outputs_fails_without_touching_source(self, tmp_path: Path):
        source = _make_png(tmp_path / "scan.png")
        task_dir = _prepare_task(tmp_path, source=source)
        markdown = tmp_path / "_mineru" / "notes.md"
        original = markdown.read_text(encoding="utf-8")

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 2
        assert markdown.read_text(encoding="utf-8") == original

    def test_empty_page_count_fails(self, tmp_path: Path):
        source = tmp_path / "broken.pdf"
        source.write_bytes(b"not a pdf")
        task_dir = _prepare_task(tmp_path, source=source)

        assert finalize_task_package(task_dir) == 2

    def test_missing_task_json_fails(self, tmp_path: Path):
        assert finalize_task_package(tmp_path) == 2

    def test_revised_without_page_markers_fails(self, tmp_path: Path):
        source = _make_png(tmp_path / "scan.png")
        task_dir = _prepare_task(tmp_path, source=source)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n校对内容",
            revised="没有任何页标记的修订稿",
        )

        assert finalize_task_package(task_dir) == 2

    def test_incomplete_page_markers_fails(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=3)
        task_dir = _prepare_task(tmp_path, source=source)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n一",
            revised="<!-- page: 1 -->\n一\n<!-- page: 2 -->\n二",
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 2

    def test_happy_path_strips_markers_and_writes_final(
        self, tmp_path: Path, capsys
    ):
        source = _make_pdf(tmp_path / "notes.pdf", pages=2)
        draft = (
            "<!-- 第一页 -->\n第一页草稿内容，长度超过二十个字符以满足空输出门控要求。\n\n"
            "第二页草稿内容，长度同样超过二十个字符以满足空输出门控要求。"
        )
        task_dir = _prepare_task(tmp_path, source=source, draft_text=draft)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n第一页校对\n<!-- page: 2 -->\n第二页校对",
            revised=(
                "<!-- page: 1 -->\n第一页修订内容，长度超过二十个字符以满足空输出门控。\n"
                "<!-- uncertain: 原文'修订内客'，疑为'修订内容' -->\n"
                "<!-- page: 2 -->\n第二页修订内容，长度超过二十个字符以满足空输出门控。"
            ),
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        final = (tmp_path / "_mineru" / "notes.md").read_text(encoding="utf-8")
        assert "uncertain" not in final
        assert "page:" not in final
        assert "第一页修订内容" in final
        assert "第二页修订内容" in final

        report = json.loads(
            (task_dir / "handwriting-report.json").read_text(encoding="utf-8")
        )
        assert report["status"] == "finalized"
        assert len(report["uncertain"]) == 1
        assert "原文'修订内客'" in report["uncertain"][0]

    def test_leftover_low_confidence_recorded_as_unadjudicated(
        self, tmp_path: Path
    ):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        task_dir = _prepare_task(tmp_path, source=source)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n某处 <!-- low-confidence: 该处无法辨认 --> 草稿",
            revised=(
                "<!-- page: 1 -->\n某处 <!-- low-confidence: 该处无法辨认 --> 草稿，"
                "长度超过二十个字符以满足空输出门控要求。"
            ),
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        report = json.loads(
            (task_dir / "handwriting-report.json").read_text(encoding="utf-8")
        )
        assert report["low_confidence"] == ["该处无法辨认"]
        assert report["uncertain"] == ["低置信未裁决: 该处无法辨认"]
        final = (tmp_path / "_mineru" / "notes.md").read_text(encoding="utf-8")
        assert "low-confidence" not in final

    def test_duplicate_page_marker_later_batch_wins(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=2)
        task_dir = _prepare_task(tmp_path, source=source)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n旧\n<!-- page: 2 -->\n二\n<!-- page: 2 -->\n二后批",
            revised=(
                "<!-- page: 1 -->\n第一页内容长度超过二十个字符以满足空输出门控要求。\n"
                "<!-- page: 2 -->\n第二页前批输出内容长度超过二十个字符门控。\n"
                "<!-- page: 2 -->\n第二页后批输出内容长度超过二十个字符门控。"
            ),
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        final = (tmp_path / "_mineru" / "notes.md").read_text(encoding="utf-8")
        assert "后批输出" in final
        assert "前批输出" not in final

    def test_image_refs_backfilled_from_draft(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        draft = (
            "第一页有插图说明，长度超过二十个字符以满足空输出门控要求。\n\n"
            "![figure-1](notes.images/figure-1.jpg)"
        )
        task_dir = _prepare_task(
            tmp_path, source=source, draft_text=draft, images=["figure-1.jpg"]
        )
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n第一页有插图说明（无引用行）",
            revised="<!-- page: 1 -->\n第一页有插图说明，长度超过二十个字符以满足空输出门控要求。",
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        final = (tmp_path / "_mineru" / "notes.md").read_text(encoding="utf-8")
        assert "![figure-1](notes.images/figure-1.jpg)" in final
        assert "图片引用补录" in final
        report = json.loads(
            (task_dir / "handwriting-report.json").read_text(encoding="utf-8")
        )
        assert len(report["backfilled_image_refs"]) == 1

    def test_preamble_before_first_marker_preserved(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        task_dir = _prepare_task(tmp_path, source=source)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n一",
            revised=(
                "文档开头的引言段落，长度超过二十个字符以满足空输出门控要求。\n\n"
                "<!-- page: 1 -->\n第一页正文内容长度超过二十个字符以满足门控要求。"
            ),
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        final = (tmp_path / "_mineru" / "notes.md").read_text(encoding="utf-8")
        assert final.startswith("文档开头的引言段落")

    def test_manifest_updated_with_handwriting_pipeline(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        output_root = tmp_path / "_mineru"
        markdown = output_root / "notes.md"
        markdown.parent.mkdir(parents=True, exist_ok=True)
        markdown.write_text("草稿内容", encoding="utf-8")
        manifest = output_root / "notes.manifest.json"
        manifest.write_text(
            json.dumps({"source_path": str(source), "quality_gate": {"status": "failed"}}),
            encoding="utf-8",
        )
        build_task_package(
            source=source,
            stem="notes",
            output_markdown=markdown,
            output_images_dir=output_root / "notes.images",
            output_manifest=manifest,
            draft_markdown=markdown,
            task_root=output_root,
        )
        task_dir = output_root / "notes.handwriting-task"
        (task_dir / "supplement.md").write_text(
            "<!-- page: 1 -->\n校对", encoding="utf-8"
        )
        (task_dir / "revised.md").write_text(
            "<!-- page: 1 -->\n修订后的内容长度超过二十个字符以满足空输出门控要求。",
            encoding="utf-8",
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        entry = json.loads(manifest.read_text(encoding="utf-8"))
        assert entry["handwriting_pipeline"]["status"] == "finalized"
        assert entry["handwriting_pipeline"]["page_count"] == 1
        assert entry["quality_gate"]["status"] == "failed"  # 原字段未被破坏

    def test_missing_manifest_skips_update_gracefully(self, tmp_path: Path, capsys):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        task_dir = _prepare_task(tmp_path, source=source)
        (tmp_path / "_mineru" / "notes.manifest.json").unlink(missing_ok=True)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n校对",
            revised="<!-- page: 1 -->\n修订后的内容长度超过二十个字符以满足空输出门控要求。",
        )

        exit_code = finalize_task_package(task_dir)

        assert exit_code == 0
        captured = capsys.readouterr()
        assert "跳过 manifest 更新" in captured.err

    def test_task_json_status_updated_to_finalized(self, tmp_path: Path):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        task_dir = _prepare_task(tmp_path, source=source)
        self._write_agent_outputs(
            task_dir,
            supplement="<!-- page: 1 -->\n校对",
            revised="<!-- page: 1 -->\n修订后的内容长度超过二十个字符以满足空输出门控要求。",
        )

        finalize_task_package(task_dir)

        task = json.loads((task_dir / "task.json").read_text(encoding="utf-8"))
        assert task["status"] == "finalized"


class TestMain:
    def test_finalize_subcommand_dispatch(self, tmp_path: Path, monkeypatch):
        source = _make_pdf(tmp_path / "notes.pdf", pages=1)
        task_dir = _prepare_task(tmp_path, source=source)
        (task_dir / "supplement.md").write_text(
            "<!-- page: 1 -->\n校对", encoding="utf-8"
        )
        (task_dir / "revised.md").write_text(
            "<!-- page: 1 -->\n修订后的内容长度超过二十个字符以满足空输出门控要求。",
            encoding="utf-8",
        )

        assert main(["finalize", str(task_dir)]) == 0

    def test_missing_command_exits(self):
        with pytest.raises(SystemExit):
            main([])
