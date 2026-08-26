from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import sys
from pathlib import Path

from .mineru_config import load_settings
from .mineru_handwriting import TaskPackageInfo, build_task_package
from .mineru_inputs import discover_inputs, split_routed_inputs
from .mineru_manifest import (
    build_manifest_entry,
    update_per_file_manifest,
    upsert_batch_manifest,
)
from .mineru_outputs import OutputTargets
from .mineru_pages import IMAGE_SOURCE_EXTENSIONS
from .mineru_precision import convert_files
from .mineru_quality import check_quality_gates, quality_gate_payload


UNSUPPORTED_HINTS = {
    ".csv": "本 skill 不支持 CSV。请使用 xlsx skill 或 pandas 手动转换。",
    ".tsv": "本 skill 不支持 TSV。请使用 xlsx skill 或 pandas 手动转换。",
    ".json": "本 skill 不支持 JSON 文件。",
    ".xml": "本 skill 不支持 XML 文件。",
    ".epub": "本 skill 不支持 EPUB。",
    ".zip": "本 skill 不支持 ZIP 文件。",
}

# --prefer-multimodal 下进入手写校对管道的源类型（PDF 与图片）
HANDWRITING_SOURCE_SUFFIXES = {".pdf"} | IMAGE_SOURCE_EXTENSIONS


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Convert local files with MinerU.")
    parser.add_argument("inputs", nargs="+", help="Input files or directories")
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("--require-json", action="store_true")
    parser.add_argument("--output-root", default=None)
    parser.add_argument("--config", default=None)
    parser.add_argument("--prefer-multimodal", action="store_true")
    parser.add_argument("--audit-dir", default=None)
    return parser


def _new_batch_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


def default_output_root(
    raw_inputs: list[str], supported: list[Path], configured: str
) -> Path:
    if configured:
        return Path(configured)
    if len(raw_inputs) == 1:
        requested = Path(raw_inputs[0])
        if requested.is_dir():
            return requested / "_mineru"
    if len(supported) == 1:
        return supported[0].parent / "_mineru"
    return Path.cwd() / "_mineru"


def print_unsupported_guidance(paths: list[Path]) -> None:
    if not paths:
        return
    print("以下文件格式明确不支持：", file=sys.stderr)
    for path in paths:
        hint = UNSUPPORTED_HINTS.get(path.suffix.lower(), "本 skill 不支持该格式。")
        print(f"  - {path}: {hint}", file=sys.stderr)


def print_invalid_input_guidance(paths: list[Path]) -> None:
    if not paths:
        return
    print("以下文件无法处理（不存在/不可读/空文件）：", file=sys.stderr)
    for path in paths:
        print(f"  - {path}", file=sys.stderr)


def print_handwriting_guidance(infos: list[TaskPackageInfo]) -> None:
    if not infos:
        return
    print("手写校对任务包已生成，请完成视觉校对与语义修订后 finalize：")
    for info in infos:
        print(f"  任务包: {info.task_dir}（{info.page_count} 页）")
        for warning in info.warnings:
            print(f"    预检: {warning}")
        if info.degraded_reason:
            print(f"    降级: {info.degraded_reason}")
    print(
        "  1) 视觉校对：multimodal-looker subagent / omp vision role"
        "（基准 gpt-5.6-terra:xhigh 或 kimi-k3:max，禁止 glm 系列），按 TASK.md 写 supplement.md"
    )
    print("  2) 语义修订：主 agent 或任意强文本角色写 revised.md")
    print("  3) 收尾：python -m scripts.mineru_handwriting finalize <任务包目录>")


def _load_source_path(target: OutputTargets) -> Path | None:
    # 首选 OutputTargets 携带的源路径（无 --audit-dir 时 manifest 不存在）
    source = getattr(target, "source", None)
    if source is not None:
        return Path(source)
    try:
        entry = json.loads(target.manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    source_path = entry.get("source_path")
    return Path(source_path) if source_path else None


def _is_handwriting_source(target: OutputTargets) -> bool:
    source = _load_source_path(target)
    return source is not None and source.suffix.lower() in HANDWRITING_SOURCE_SUFFIXES


def _compute_relative_root(
    raw_inputs: list[str], supported: list[Path]
) -> Path | None:
    if len(raw_inputs) == 1:
        requested = Path(raw_inputs[0])
        if requested.is_dir():
            return requested.resolve()
    if len(raw_inputs) > 1 or (len(raw_inputs) == 1 and raw_inputs[0] == "."):
        return Path.cwd()
    return None


def _quality_gate_payload(qr) -> dict:
    return quality_gate_payload(qr)


def _relative_source_path(source: Path, relative_root: Path | None) -> Path:
    if relative_root is None:
        return Path(source.name)
    try:
        return source.relative_to(relative_root)
    except ValueError:
        return Path(source.name)


def _upsert_rendered_manifest(audit_dir: Path, target, quality_gate: dict) -> None:
    entry = update_per_file_manifest(target.manifest, {"quality_gate": quality_gate})
    upsert_batch_manifest(
        audit_dir / "mineru_manifest.json",
        str(entry["relative_source_path"]),
        entry,
    )


def _upsert_failure_manifest(
    audit_dir: Path,
    failure: dict,
    *,
    relative_root: Path | None,
    batch_id: str,
    model: str,
) -> None:
    source = Path(failure["source_path"])
    relative_source_path = _relative_source_path(source, relative_root)
    entry = build_manifest_entry(
        source_path=source,
        relative_source_path=relative_source_path,
        allocated_stem=source.stem,
        route=failure.get("route", "mineru"),
        model=model,
        output_md=None,
        output_images_dir=None,
        output_json_dir=None,
        raw_archive_path=None,
        raw_archive_status="failed",
        image_status="failed",
        image_count=0,
        conversion_status="failed",
        quality_gate={"status": "not_applicable", "passed": None, "failed_gates": []},
        errors=[str(failure.get("error", ""))],
        warnings=[],
        batch_id=batch_id,
    )
    upsert_batch_manifest(audit_dir / "mineru_manifest.json", relative_source_path.as_posix(), entry)


def main() -> int:
    args = build_parser().parse_args()
    if args.require_json:
        print("警告: --require-json is deprecated / 已弃用；JSON 缺失不再作为失败门控", file=sys.stderr)
    settings = load_settings(args.config)
    output_root = default_output_root(
        args.inputs, [], args.output_root or settings.default_output_root
    )
    requested_audit_dir = args.audit_dir or settings.audit_dir
    audit_dir = Path(requested_audit_dir) if requested_audit_dir else None
    exclude_roots: list[str | Path] = [output_root]
    if audit_dir is not None:
        exclude_roots.append(audit_dir)
    discovered = discover_inputs(
        args.inputs, recursive=args.recursive, exclude_roots=exclude_roots
    )
    if not discovered:
        print("未发现可处理的输入文件", file=sys.stderr)
        return 2

    routed = split_routed_inputs(discovered)

    mineru_files = routed.get("mineru", [])
    mineru_html_files = routed.get("mineru_html", [])
    unsupported_files = routed.get("unsupported", [])
    invalid_files = routed.get("invalid_input", [])

    supported = mineru_files + mineru_html_files

    output_root = default_output_root(
        args.inputs, supported, args.output_root or settings.default_output_root
    )

    print_unsupported_guidance(unsupported_files)
    print_invalid_input_guidance(invalid_files)

    if not supported:
        return 2

    token = settings.token
    if not token:
        print(
            "MinerU 需要 MINERU_TOKEN，可通过环境变量或 --config 提供",
            file=sys.stderr,
        )
        return 2

    relative_root = (
        _compute_relative_root(raw_inputs=args.inputs, supported=supported)
        if settings.keep_raw_tree
        else None
    )

    batch_id = _new_batch_id() if audit_dir is not None else None
    failures: list[dict] = []
    rendered = []
    if mineru_files:
        rendered.extend(
            convert_files(
                mineru_files,
                output_root,
                token=token,
                keep_raw_tree=settings.keep_raw_tree,
                relative_root=relative_root,
                audit_dir=audit_dir,
                batch_id=batch_id,
                route="mineru",
                model="vlm",
                failure_collector=failures if audit_dir is not None else None,
            )
        )
    if mineru_html_files:
        rendered.extend(
            convert_files(
                mineru_html_files,
                output_root,
                token=token,
                keep_raw_tree=settings.keep_raw_tree,
                relative_root=relative_root,
                audit_dir=audit_dir,
                batch_id=batch_id,
                route="mineru_html",
                model="MinerU-HTML",
                failure_collector=failures if audit_dir is not None else None,
            )
        )
    quality_failed = False
    handwriting_candidates: list[tuple[OutputTargets, dict]] = []
    for target in rendered:
        md_text = target.markdown.read_text(encoding="utf-8") if target.markdown.exists() else ""
        qr = check_quality_gates(
            markdown=md_text,
            images_dir=target.images_dir if target.images_dir.exists() else None,
            source=target.markdown,
        )
        is_handwriting = args.prefer_multimodal and _is_handwriting_source(target)
        if is_handwriting:
            handwriting_candidates.append((target, quality_gate_payload(qr)))
        elif not qr.passed:
            quality_failed = True
        if not qr.passed:
            for gate in qr.failed_gates:
                hint = ""
                if is_handwriting:
                    hint = " | 将进入手写校对管道"
                elif gate.suggested_route:
                    hint = f" | 建议: {gate.suggested_route}"
                print(
                    f"质量门控失败: {gate.source} | {gate.gate_id} | {gate.reason}{hint}",
                    file=sys.stderr,
                )
        if audit_dir is not None:
            _upsert_rendered_manifest(audit_dir, target, _quality_gate_payload(qr))
    if audit_dir is not None and batch_id is not None:
        for failure in failures:
            model = "MinerU-HTML" if failure.get("route") == "mineru_html" else "vlm"
            _upsert_failure_manifest(
                audit_dir,
                failure,
                relative_root=relative_root,
                batch_id=batch_id,
                model=model,
            )
    task_infos: list[TaskPackageInfo] = []
    if args.prefer_multimodal:
        candidate_stems = {target.stem for target, _ in handwriting_candidates}
        skipped_stems = [
            target.stem for target in rendered if target.stem not in candidate_stems
        ]
        if skipped_stems:
            print(
                "以下文件类型不支持手写校对管道，已按常规 MinerU 转换处理：",
                file=sys.stderr,
            )
            for stem in skipped_stems:
                print(f"  - {stem}", file=sys.stderr)
        for target, gates_before in handwriting_candidates:
            task_infos.append(
                build_task_package(
                    source=_load_source_path(target),
                    stem=target.stem,
                    output_markdown=target.markdown,
                    output_images_dir=target.images_dir,
                    output_manifest=target.manifest,
                    draft_markdown=target.markdown,
                    task_root=target.markdown.parent,
                    gates_before=gates_before,
                )
            )
    if quality_failed:
        print_handwriting_guidance(task_infos)
        return 2
    for target in rendered:
        print(target.markdown)
    print_handwriting_guidance(task_infos)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
