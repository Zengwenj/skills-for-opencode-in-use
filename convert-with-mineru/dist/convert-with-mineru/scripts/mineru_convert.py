from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .mineru_config import load_settings
from .mineru_inputs import discover_inputs, split_routed_inputs
from .mineru_precision import convert_files


FALLBACK_HINTS = {
    ".csv": "markdown-converter 或 xlsx",
    ".tsv": "markdown-converter 或 xlsx",
    ".json": "markdown-converter",
    ".xml": "markdown-converter",
    ".epub": "markdown-converter",
    ".zip": "markdown-converter",
    ".xls": "markdown-converter 或 xlsx skill",
    ".xlsx": "markdown-converter 或 xlsx skill",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Convert local files with MineU.")
    parser.add_argument("inputs", nargs="+", help="Input files or directories")
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("--require-json", action="store_true")
    parser.add_argument("--output-root", default=None)
    parser.add_argument("--config", default=None)
    return parser


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


def print_fallback_guidance(paths: list[Path]) -> None:
    if not paths:
        return
    print("以下文件不走 MineU 主路径，请改走 fallback：")
    for path in paths:
        hint = FALLBACK_HINTS.get(path.suffix.lower(), "markdown-converter")
        print(f"- {path} -> {hint}")


def print_multimodal_guidance(paths: list[Path]) -> None:
    if not paths:
        return
    print("以下文件已强制改走 OCR 多模态识别，请分配给 multimodal-looker subagent：")
    for path in paths:
        print(f"- {path} -> multimodal-looker")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    settings = load_settings(args.config)
    output_root = default_output_root(
        args.inputs, [], args.output_root or settings.default_output_root
    )
    discovered = discover_inputs(
        args.inputs, recursive=args.recursive, exclude_roots=[output_root]
    )
    if not discovered:
        print("未发现可处理的输入文件", file=sys.stderr)
        return 2

    routed = split_routed_inputs(discovered)
    supported = routed["mineu"]
    multimodal = routed["multimodal_looker"]
    fallback = routed["fallback"]

    output_root = default_output_root(
        args.inputs, supported, args.output_root or settings.default_output_root
    )
    print_multimodal_guidance(multimodal)
    print_fallback_guidance(fallback)
    if not supported:
        return 2

    token = settings.token
    if not token:
        print(
            "MineU 需要 MINERU_TOKEN，可通过环境变量或 --config 提供",
            file=sys.stderr,
        )
        return 2

    rendered = convert_files(
        supported, output_root, token=token, keep_raw_tree=settings.keep_raw_tree
    )
    for target in rendered:
        print(target.markdown)
        for json_path in sorted(target.json_files.values()):
            if json_path.exists():
                print(json_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
