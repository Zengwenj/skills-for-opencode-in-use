from __future__ import annotations

import argparse
from datetime import datetime, timezone
import sys
from pathlib import Path

from .mineru_config import load_settings
from .mineru_inputs import discover_inputs, split_routed_inputs
from .mineru_manifest import (
    build_manifest_entry,
    to_posix,
    update_per_file_manifest,
    upsert_batch_manifest,
)
from .mineru_precision import convert_files
from .mineru_quality import check_quality_gates


UNSUPPORTED_HINTS = {
    ".csv": "本 skill 不支持 CSV。请使用 xlsx skill 或 pandas 手动转换。",
    ".tsv": "本 skill 不支持 TSV。请使用 xlsx skill 或 pandas 手动转换。",
    ".json": "本 skill 不支持 JSON 文件。",
    ".xml": "本 skill 不支持 XML 文件。",
    ".epub": "本 skill 不支持 EPUB。",
    ".zip": "本 skill 不支持 ZIP 文件。",
}


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


def print_multimodal_guidance(paths: list[Path]) -> None:
    if not paths:
        return
    print("以下文件已强制改走多模态 OCR 识别，请分配给 multimodal-looker：")
    for path in paths:
        print(f"  - {path} -> multimodal-looker")


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
    return {
        "status": "passed" if qr.passed else "failed",
        "passed": qr.passed,
        "failed_gates": [
            {
                "source": gate.source,
                "gate_id": gate.gate_id,
                "reason": gate.reason,
                "suggested_route": gate.suggested_route,
            }
            for gate in qr.failed_gates
        ],
    }


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
    upsert_batch_manifest(
        audit_dir / "mineru_manifest.json", to_posix(relative_source_path) or source.name, entry
    )


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
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

    routed = split_routed_inputs(
        discovered, prefer_multimodal=args.prefer_multimodal
    )

    mineru_files = routed.get("mineru", [])
    mineru_html_files = routed.get("mineru_html", [])
    multimodal_files = routed.get("multimodal_looker", [])
    unsupported_files = routed.get("unsupported", [])
    invalid_files = routed.get("invalid_input", [])

    supported = mineru_files + mineru_html_files

    output_root = default_output_root(
        args.inputs, supported, args.output_root or settings.default_output_root
    )

    print_unsupported_guidance(unsupported_files)
    print_invalid_input_guidance(invalid_files)
    print_multimodal_guidance(multimodal_files)

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
                model="default",
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
    for target in rendered:
        md_text = target.markdown.read_text(encoding="utf-8") if target.markdown.exists() else ""
        qr = check_quality_gates(
            markdown=md_text,
            json_files=target.json_files,
            images_dir=target.images_dir if target.images_dir.exists() else None,
            require_json=args.require_json,
            source=target.markdown,
        )
        if not qr.passed:
            quality_failed = True
            for gate in qr.failed_gates:
                print(
                    f"质量门控失败: {gate.source} | {gate.gate_id} | {gate.reason}"
                    + (f" | 建议: {gate.suggested_route}" if gate.suggested_route else ""),
                    file=sys.stderr,
                )
        if audit_dir is not None:
            _upsert_rendered_manifest(audit_dir, target, _quality_gate_payload(qr))
    if audit_dir is not None and batch_id is not None:
        for failure in failures:
            model = "MinerU-HTML" if failure.get("route") == "mineru_html" else "default"
            _upsert_failure_manifest(
                audit_dir,
                failure,
                relative_root=relative_root,
                batch_id=batch_id,
                model=model,
            )
    if quality_failed:
        return 2
    for target in rendered:
        print(target.markdown)
        if not args.require_json:
            cl = target.json_files.get("content_list")
            if cl is None or not cl.exists():
                missing = str(cl) if cl else "content_list"
                print(
                    f"警告: JSON 缺失（未使用 --require-json）: {missing}",
                    file=sys.stderr,
                )
        for json_path in sorted(target.json_files.values()):
            if json_path.exists():
                print(json_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
