---
name: convert-with-mineru
description: Use when converting local document directories or files with MinerU precision batch mode, preserving source-based filenames for Markdown and images output with quality gating.
---

# Convert With MinerU

## Overview

把 MinerU Precision API 作为本地文档批量转换主路径，覆盖所有官方支持格式。

核心原则：
- 统一走精准模式（Precision API），非 HTML 使用 `vlm` 模型，HTML/HTM 使用 `MinerU-HTML` 模型。
- 官方支持格式（`pdf/doc/docx/ppt/pptx/xls/xlsx/html/htm/png/jpg/jpeg/jp2/webp/gif/bmp`）全部走 MinerU。
- `csv/tsv/json/xml/epub/zip` 明确不支持（`unsupported`），不委托其他 skill。
- 不存在、不可读、0-byte 的官方支持格式路由到 `invalid_input`。
- 正式输出只有 `source.md` + `source.images/`，不产出 JSON。
- `multimodal_looker` 保留为显式 opt-in 的 LLM 图像识别理解路由（通过 `--prefer-multimodal`）。

## When To Use

在这些场景使用本技能：
- 需要把本地 `pdf/doc/docx/ppt/pptx/xls/xlsx/html/htm` 或图片目录批量转成 Markdown。
- 需要按源文件名保存结果，例如 `report.md`、`report.images/`。
- 需要确定性路由与质量门控。

在这些场景不要使用本技能：
- `csv/tsv/json/xml/epub/zip`：本 skill 明确不支持这些格式。
- 需要高保真处理 Word、PPT：优先 `docx`、`pptx` skill。
- 需要多格式输出（docx/html/latex）或 URL 网页抓取：参考"排障/底层参考"章节。

## Quick Reference

| 场景 | 使用方式 | 说明 |
| --- | --- | --- |
| 目录批量转换 | `python -m scripts.mineru_convert --recursive <folder>` | 非 HTML 使用 `vlm`，HTML/HTM 使用 `MinerU-HTML` |
| 单文件 | `python -m scripts.mineru_convert <file>` | 同上，无 `--recursive` |
| 启用审计归档 | 追加 `--audit-dir <path>` | 生成 raw archive、batch manifest、per-file manifest |
| 手写/低质/重复灌词 PDF 或图片 | 追加 `--prefer-multimodal` | 显式 opt-in，走 `multimodal_looker` 路由 |
| 外置配置文件 | 追加 `--config <path>` | 参考 `examples/mineru.env` |
| `csv/tsv/json/xml/epub/zip` | **不支持** | 不委托其他 skill |

## Routes

本 skill 的确定性路由结果为以下五个 canonical route 之一：

| Route | 含义 | 触发条件 |
| --- | --- | --- |
| `mineru` | MinerU Precision API `vlm` 模型 | 非 HTML 的官方支持格式 |
| `mineru_html` | MinerU Precision API `MinerU-HTML` 模型 | `.html` `.htm` |
| `multimodal_looker` | 输出 LLM 图像识别 guidance（不调用外部 API） | `--prefer-multimodal` 时的 PDF/图片 |
| `unsupported` | 明确不支持的格式 | `.csv` `.tsv` `.json` `.xml` `.epub` `.zip` 等 |
| `invalid_input` | 文件不存在、不可读或 0-byte | 任何官方支持格式但无法读取 |

## Output Rules

正式输出仅包含以下产物，**不产出任何 JSON**：

- `source.md`：Markdown 正文，图片路径已重写为 `source.images/` 前缀
- `source.images/`：MinerU 提取的图片资源

不保留 `source.json/`、`content_list*.json`、`layout.json`、`model.json`。

- 重名冲突使用 `__2`、`__3` 后缀。
- Per-file manifest（`source.manifest.json`）仅在启用 `--audit-dir` 时生成，是审计元数据而非 MinerU 原生 JSON。
- Raw 归档仅存入外部审计目录 `_review/mineru/<batch_id>/raw/`，不放入正式输出目录。

## Commands

日常入口唯一：

```powershell
python -m scripts.mineru_convert --recursive <folder>
```

启用审计归档：

```powershell
python -m scripts.mineru_convert --audit-dir "C:\audit\mineru" --recursive <folder>
```

也可通过环境变量 `MINERU_AUDIT_DIR` 或配置文件的 `AUDIT_DIR` 键设置。默认归档路径为 `<output_root>/../_review/mineru/<batch_id>/`。

显式 opt-in LLM 图像识别理解路由：

```powershell
python -m scripts.mineru_convert --recursive <folder> --prefer-multimodal
```

`--prefer-multimodal` 将匹配的 PDF/图片路由到 `multimodal_looker`，只输出 guidance（建议使用多模态 LLM 进行图像识别理解），不实际调用外部视觉 API。

`--require-json` 已弃用，仅打印 warning。

## Config

使用环境变量 `MINERU_TOKEN`（CLI/SDK 共用认证 token）。

Token 变量差异：
- 本 skill 和 CLI 使用 `MINERU_TOKEN`。
- 官方 MCP Server 使用 `MINERU_API_TOKEN`（不同认证体系）。
- 两者**不能互换**，不要混用。

配置写法、外置 `mineru.env` / `mineru.json` 示例，见：
- `references/configuration.md`
- `examples/mineru.env`
- `examples/mineru.json`

本地验证时如果目录里临时留有 `mineru..env` 这类真实配置文件，把它视为隔离对象。

## 排障 / 底层参考

以下工具不在日常推荐路径中，仅在特殊场景参考：

| 场景 | 工具 | 说明 |
| --- | --- | --- |
| 少量文件 + 对话内快速读取 | 官方 MCP `mineru_parse_documents` | 使用 `MINERU_API_TOKEN`；非 HTML 省略 `model` |
| 需要 docx/html/latex 等多格式输出 | 官方 MinerU Document Extractor CLI | `mineru-open-api extract -f` |
| URL 网页解析/crawl | 官方 MinerU Document Extractor `crawl` | 本 skill 只支持本地 `.html/.htm` |

## Fallback

MinerU 路由矩阵与分流说明见：
- `references/fallback-routing.md`

质量门控结果记录在 per-file manifest 的 `warnings` 字段（需 `--audit-dir`），不改变路由阈值。

脚本级路由规则：
- `.pdf`/`.doc`/`.docx`/`.ppt`/`.pptx`/`.xls`/`.xlsx` → `mineru`（`vlm` 模型）
- `.html`/`.htm` → `mineru_html`（`MinerU-HTML` 模型）
- `.png`/`.jpg`/`.jpeg`/`.jp2`/`.webp`/`.gif`/`.bmp` → `mineru`（`vlm` 模型）
- `.csv`/`.tsv`/`.json`/`.xml`/`.epub`/`.zip` → `unsupported`
- 不存在/不可读/0-byte → `invalid_input`
- `--prefer-multimodal` 时的 PDF/图片 → `multimodal_looker`（guidance-only）

## Known Issues

- SDK 超时：大文件可能触发 MinerU SDK 超时，重试通常有效
- 乱码 (mojibake)：个别文件编码问题，根因待排查

## Common Mistakes

- 期望 JSON 输出（本 skill 正式输出不含 JSON，`--require-json` 已弃用）
- 把 `MINERU_API_TOKEN` 和 `MINERU_TOKEN` 混用（MCP 用前者，本 skill/CLI 用后者，不能互换）
- 把 `xls/xlsx` 当作不支持（官方 API 已支持 Excel）
- 尝试用本 skill 处理 `csv/tsv/json/xml/epub/zip`（明确不支持）
- 手写/低质/重复灌词场景不使用 `--prefer-multimodal` 导致输出质量差
- 直接把 ZIP 里的 `full.md` 当最终产物
- 让 `.md` 继续引用 `images/...`，却把图片目录改名成 `source.images/`
- 通过 `$env:MINERU_API_TOKEN` 检查 opencode MCP 是否已配置 token（MCP environment 在 `opencode.json` 中，与 shell 环境变量独立）
- 把 raw 审计归档当成正式输出的一部分（raw 只在 `_review` 审计目录）
- 期望 `source.manifest.json` 是 MinerU 原生 JSON（manifest 是本 skill 生成的审计元数据，仅 `--audit-dir` 时存在）

## Red Flags

- "MineU 不支持也许也能跑"
- "没有 JSON 我就生成一个空 JSON"
- "Excel 不支持所以跳过"
- "图片应该走 multimodal-looker 默认"

这些都表示路径选错了，应立即改回正确路径。
