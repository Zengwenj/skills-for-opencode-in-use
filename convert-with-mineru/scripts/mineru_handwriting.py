from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from .mineru_manifest import to_posix, update_per_file_manifest
from .mineru_outputs import write_json_file
from .mineru_pages import collect_page_images
from .mineru_quality import check_quality_gates, quality_gate_payload


TASK_PACKAGE_SUFFIX = ".handwriting-task"
TASK_SCHEMA = "handwriting-task/1"
REPORT_SCHEMA = "handwriting-report/1"

SINGLE_BATCH_MAX_PAGES = 10
MULTI_BATCH_SIZE = 5

PAGE_MARKER_PATTERN = re.compile(r"<!--\s*page:\s*(\d+)\s*-->")
LOW_CONFIDENCE_PATTERN = re.compile(r"<!--\s*low-confidence:\s*(.*?)\s*-->", re.DOTALL)
UNCERTAIN_PATTERN = re.compile(r"<!--\s*uncertain:\s*(.*?)\s*-->", re.DOTALL)
IMAGE_REF_PATTERN = re.compile(r"!\[[^\]]*\]\([^)]+\)")


TASK_MD_TEMPLATE = """# 手写文档校对任务：{stem}

本任务包由 convert-with-mineru prepare 阶段生成。MinerU 已完成高精度转写（draft.md），
手写内容中难以辨认的部分需要视觉角色对照页图补充识别，再做保守的语义修订。共 {page_count} 页。

## 阶段一 · 视觉补充识别 → 写入 supplement.md

执行者：multimodal-looker subagent 或 omp vision role
（模型基准 gpt-5.6-terra:xhigh 或 kimi-k3:max；禁止使用 glm 系列模型）。

输入：本目录 pages/ 下按页码编号的页图 + draft.md。输出：本目录 supplement.md，要求：

1. 每页内容以 `<!-- page: N -->` 行开头（N 与 pages/page-NNN 编号一致）。
2. 忠实抄录：只修正 draft 中与页图不符的转写；不补写、不润色、不猜测。
3. 看不清的字：禁止猜测，原样保留草稿该处并紧随其后写 `<!-- low-confidence: 该处无法辨认 -->`。
4. 图片引用行 `![...](...)` 原样保留。缺失引用会被 finalize 机械补录到文末，破坏图片位置。
5. 表格按 Markdown 表格逐格转写；公式用 $...$ 包裹保留。
6. 分批校对，批次划分：{batches_display}（详见 task.json `batches` 字段）。
   每批处理本批全部页，包括与上一批重叠的页；重叠页以后批输出为准，
   前批的重复输出会被 finalize 自动去重。
7. 手写原文的语病、口语化、残句一律原样保留，不要在本阶段修改。

## 阶段二 · 语义修订 → 写入 revised.md

执行者：主 agent 或任意强文本角色（不绑定模型）。

输入：supplement.md。输出：revised.md（保留全部 `<!-- page: N -->` 页标记），按分级原则修订：

1. 明确疑似识别错误导致的错字/串行/重复 → 修正。
2. 明确是原文风格（口语化、语病、残句）→ 保留原样。
3. 中间地带（拿不准是识别错误还是原文如此）→ 保留原文并紧随其后写
   `<!-- uncertain: 原文X，疑为Y -->`。
4. 遇 `<!-- low-confidence: ... -->`：上下文能定夺则修正；不能定夺则保留原样，
   并把该标记改写为 uncertain 标记留人工裁决。
5. 禁止：增删段落、改变结构、修改图片引用、把人名/地名/数字"纠正"为常见词。
6. 目标是尽可能还原原始手写内容，不是润色成文。

## 阶段三 · finalize（脚本自动收尾）

运行：`python -m scripts.mineru_handwriting finalize <本任务包目录>`

校验页标记齐全 → 重叠去重（后批为准）→ 剥离 low-confidence / uncertain 标记入报告 →
图片引用机械回填 → 终稿质量门控 → 写 source.md。
终稿门控失败会 exit 2 交人工裁决，不会静默回退。

## 验收

终稿门控全绿 + 人工抽查三稿 diff（draft.md / supplement.md / revised.md 的首、中、末页）。

## 已知限制

多栏/竖排/批注穿插导致的阅读顺序错乱、印刷+手写混排表单不在本管道处理范围。
"""


def plan_batches(page_count: int) -> list[list[int]]:
    if page_count <= 0:
        return []
    if page_count <= SINGLE_BATCH_MAX_PAGES:
        return [list(range(1, page_count + 1))]
    batches: list[list[int]] = []
    start = 1
    while start <= page_count:
        end = min(start + MULTI_BATCH_SIZE - 1, page_count)
        batches.append(list(range(start, end + 1)))
        if end >= page_count:
            break
        start = end
    return batches


def _format_batches(batches: list[list[int]]) -> str:
    if not batches:
        return "无页图（prepare 阶段已降级）"
    parts = []
    for batch in batches:
        parts.append(f"[{batch[0]}-{batch[-1]}]" if len(batch) > 1 else f"[{batch[0]}]")
    if len(batches) == 1:
        return f"{parts[0]}（单批处理全部页）"
    return "、".join(parts) + "（相邻批次重叠一页，重叠页后批为准）"


def render_task_md(stem: str, page_count: int, batches: list[list[int]]) -> str:
    return TASK_MD_TEMPLATE.format(
        stem=stem,
        page_count=page_count,
        batches_display=_format_batches(batches),
    )


@dataclass
class TaskPackageInfo:
    task_dir: Path
    page_count: int
    warnings: list[str]
    degraded_reason: str | None


def build_task_package(
    *,
    source: Path,
    stem: str,
    output_markdown: Path,
    output_images_dir: Path,
    output_manifest: Path,
    draft_markdown: Path,
    task_root: Path,
    gates_before: dict | None = None,
) -> TaskPackageInfo:
    """prepare 阶段：页图证据 + 草稿 + TASK.md 指令 + 机器可读清单。"""
    task_dir = task_root / f"{stem}{TASK_PACKAGE_SUFFIX}"
    pages_dir = task_dir / "pages"
    collection = collect_page_images(source, pages_dir)

    draft_text = draft_markdown.read_text(encoding="utf-8")
    (task_dir / "draft.md").write_text(draft_text, encoding="utf-8")

    page_count = len(collection.pages)
    batches = plan_batches(page_count)
    (task_dir / "TASK.md").write_text(
        render_task_md(stem, page_count, batches), encoding="utf-8"
    )

    status = "prepared" if collection.degraded_reason is None else "degraded_pages"
    task = {
        "schema": TASK_SCHEMA,
        "status": status,
        "source": str(source),
        "stem": stem,
        "page_count": page_count,
        "batches": batches,
        "preflight_warnings": collection.warnings,
        "degraded_reason": collection.degraded_reason,
        "gates_before": gates_before,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "paths": {
            "draft": "draft.md",
            "supplement": "supplement.md",
            "revised": "revised.md",
            "task_md": "TASK.md",
            "pages": [str(page.path.relative_to(task_dir)) for page in collection.pages],
            "output_markdown": str(output_markdown.resolve()),
            "output_images_dir": str(output_images_dir.resolve()),
            "output_manifest": str(output_manifest.resolve()),
        },
    }
    write_json_file(task_dir / "task.json", task)
    return TaskPackageInfo(
        task_dir=task_dir,
        page_count=page_count,
        warnings=collection.warnings,
        degraded_reason=collection.degraded_reason,
    )


def _split_page_sections(text: str) -> tuple[dict[int, str], str, list[str]]:
    """按页标记切段。重复页码后出现者覆盖先出现者（后批为准）。"""
    sections: dict[int, str] = {}
    duplicates: list[int] = []
    warnings: list[str] = []
    matches = list(PAGE_MARKER_PATTERN.finditer(text))
    if not matches:
        return ({}, "", ["未找到任何 <!-- page: N --> 页标记"])
    preamble = text[: matches[0].start()]
    if preamble.strip():
        warnings.append("首个页标记前存在内容，已保留在终稿开头")
    for index, match in enumerate(matches):
        page_number = int(match.group(1))
        if page_number in sections:
            duplicates.append(page_number)
        section_end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections[page_number] = text[match.end() : section_end]
    if duplicates:
        warnings.append(f"重复页标记（后批覆盖前批）: {sorted(set(duplicates))}")
    return (sections, preamble, warnings)


def _strip_blank_noise(text: str) -> str:
    return re.sub(r"\n{3,}", "\n\n", text).strip() + "\n"


def finalize_task_package(task_dir: Path) -> int:
    """finalize 阶段：校验 → 去重 → 剥离标记 → 图片回填 → 门控 → 写终稿与报告。"""
    task_path = task_dir / "task.json"
    if not task_path.exists():
        print(f"错误: 任务包缺少 task.json：{task_dir}", file=sys.stderr)
        return 2
    task = json.loads(task_path.read_text(encoding="utf-8"))
    paths = task.get("paths", {})
    page_count = int(task.get("page_count", 0))

    if page_count == 0:
        print(
            f"错误: 任务包页图为空（prepare 阶段已降级：{task.get('degraded_reason')}），无法 finalize",
            file=sys.stderr,
        )
        return 2

    draft_path = task_dir / paths.get("draft", "draft.md")
    supplement_path = task_dir / paths.get("supplement", "supplement.md")
    revised_path = task_dir / paths.get("revised", "revised.md")
    missing: list[str] = []
    for label, path in (
        ("draft.md（草稿）", draft_path),
        ("supplement.md（视觉校对稿）", supplement_path),
        ("revised.md（语义修订稿）", revised_path),
    ):
        if not path.exists():
            missing.append(f"缺少 {label}：{path}")
    if missing:
        for item in missing:
            print(f"错误: {item}", file=sys.stderr)
        print(
            "任务包未完成：请按 TASK.md 完成视觉校对与语义修订后重试；source.md 保持草稿版。",
            file=sys.stderr,
        )
        return 2

    revised_text = revised_path.read_text(encoding="utf-8")
    draft_text = draft_path.read_text(encoding="utf-8")

    sections, preamble, warnings = _split_page_sections(revised_text)
    missing_pages = [n for n in range(1, page_count + 1) if n not in sections]
    if missing_pages or not sections:
        print(
            f"错误: revised.md 页标记不齐全，缺少页: {missing_pages or '全部'}"
            "（要求每页以 <!-- page: N --> 行开头）",
            file=sys.stderr,
        )
        return 2

    parts = []
    if preamble.strip():
        parts.append(preamble.strip("\n"))
    for number in sorted(sections):
        parts.append(sections[number].strip("\n"))
    body = _strip_blank_noise("\n\n".join(part for part in parts if part.strip()))

    low_confidence_leftover = [
        item.strip() for item in LOW_CONFIDENCE_PATTERN.findall(body)
    ]
    uncertain_items = [
        f"低置信未裁决: {item}" for item in low_confidence_leftover
    ] + [item.strip() for item in UNCERTAIN_PATTERN.findall(body)]
    body = LOW_CONFIDENCE_PATTERN.sub("", body)
    body = UNCERTAIN_PATTERN.sub("", body)
    body = _strip_blank_noise(body)

    draft_refs = IMAGE_REF_PATTERN.findall(draft_text)
    final_refs = set(IMAGE_REF_PATTERN.findall(body))
    backfilled_refs = [ref for ref in draft_refs if ref not in final_refs]
    if backfilled_refs:
        body = (
            body.rstrip()
            + "\n\n## 图片引用补录\n\n"
            + "\n\n".join(backfilled_refs)
            + "\n"
        )

    output_markdown = Path(paths["output_markdown"])
    images_dir = Path(paths["output_images_dir"])
    manifest_output = Path(paths["output_manifest"])
    if not output_markdown.is_absolute():
        # 旧任务包可能存相对路径：输出物是任务包的同级文件（同在 output_root 下）
        output_markdown = task_dir.parent / output_markdown.name
    if not images_dir.is_absolute():
        images_dir = task_dir.parent / images_dir.name
    if not manifest_output.is_absolute():
        manifest_output = task_dir.parent / manifest_output.name
    images_dir_arg = images_dir if images_dir.exists() else None
    gate_result = check_quality_gates(
        body, page_count=page_count, images_dir=images_dir_arg, source=output_markdown
    )
    gates_after = quality_gate_payload(gate_result)

    output_markdown.write_text(body, encoding="utf-8")

    status = "finalized" if gate_result.passed else "finalized_gates_failed"
    report = {
        "schema": REPORT_SCHEMA,
        "status": status,
        "stem": task.get("stem"),
        "source": task.get("source"),
        "page_count": page_count,
        "batches": task.get("batches"),
        "prepared_at": task.get("created_at"),
        "finalized_at": datetime.now(timezone.utc).isoformat(),
        "split_warnings": warnings,
        "low_confidence": low_confidence_leftover,
        "uncertain": uncertain_items,
        "backfilled_image_refs": backfilled_refs,
        "preflight_warnings": task.get("preflight_warnings", []),
        "gates_before": task.get("gates_before"),
        "gates_after": gates_after,
    }
    write_json_file(task_dir / "handwriting-report.json", report)

    manifest_path = manifest_output
    try:
        update_per_file_manifest(
            manifest_path,
            {
                "handwriting_pipeline": {
                    "status": status,
                    "task_package": to_posix(task_dir),
                    "page_count": page_count,
                    "low_confidence_count": len(low_confidence_leftover),
                    "uncertain_count": len(uncertain_items),
                    "backfilled_image_refs": len(backfilled_refs),
                    "gates_before": task.get("gates_before"),
                    "gates_after": gates_after,
                }
            },
        )
    except FileNotFoundError:
        print(
            f"提示: 未找到 per-file manifest（转换时未启用 --audit-dir），跳过 manifest 更新: {manifest_path}",
            file=sys.stderr,
        )

    task["status"] = status
    task["finalized_at"] = report["finalized_at"]
    write_json_file(task_path, task)

    for item in low_confidence_leftover:
        print(f"低置信未裁决: {item}", file=sys.stderr)
    for item in uncertain_items:
        print(f"不确定标记: {item}", file=sys.stderr)
    if backfilled_refs:
        print(f"图片引用补录 {len(backfilled_refs)} 条（视觉校对阶段丢失，已机械补至文末）", file=sys.stderr)
    if not gate_result.passed:
        for gate in gate_result.failed_gates:
            print(f"终稿门控失败: {gate.gate_id} | {gate.reason}", file=sys.stderr)
        return 2
    print(f"已写入终稿: {output_markdown}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="手写任务包工具：prepare 由 mineru_convert 自动触发，此处提供 finalize。"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    finalize_parser = subparsers.add_parser(
        "finalize", help="校验任务包产物并落盘终稿 source.md"
    )
    finalize_parser.add_argument("task_dir", type=Path, help="任务包目录")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "finalize":
        return finalize_task_package(args.task_dir)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
