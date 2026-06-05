---
name: convert-with-mineru
description: Use when converting local documents or directories with MinerU, especially when choosing between precision parsing and multimodal OCR routing, preserving source-based filenames, or routing scanned PDFs and images for quality-gated output.
---

# Convert With MinerU

## Overview

把 MinerU 作为本地文档转换主路径，覆盖所有官方支持格式。

核心原则：
- MinerU 统一走精准模式（Precision API）。
- 官方支持格式（`pdf/doc/docx/ppt/pptx/xls/xlsx/html/htm/png/jpg/jpeg/jp2/webp/gif/bmp`）全部走 MinerU。
- `csv/tsv/json/xml/epub/zip` 明确不支持，路由到 `unsupported`。
- 不存在、不可读、0-byte 的官方支持格式路由到 `invalid_input`。
- 最终输出必须按源文件名写出，不把 `full.md` 直接暴露给用户。

## When To Use

在这些场景使用本技能：
- 需要把本地 `pdf/doc/docx/ppt/pptx/xls/xlsx/html/htm` 或目录转换成 Markdown。
- 需要处理官方图片格式 `png/jpg/jpeg/jp2/webp/gif/bmp`。
- 需要按源文件名保存结果，例如 `report.md`、`report.images/`、`report.json/report.content_list.json`。
- 需要确定性路由、质量门控与结构化 JSON 输出。

在这些场景不要使用本技能：
- `csv/tsv/json/xml/epub/zip`：本 skill 明确不支持这些格式。
- 需要高保真处理 Word、PPT：优先 `docx`、`pptx` skill。
- 少量文件只需 Markdown：优先官方 MCP `mineru_parse_documents`。

## Quick Reference

| 场景 | 首选 | 备选/说明 |
| --- | --- | --- |
| `.docx`/`.doc`/`.ppt`/`.pptx`/数字导出 PDF | 本 skill (MinerU 精准模式) | 官方 MCP（少量只需 Markdown 时优先 MCP） |
| `.xls`/`.xlsx` | 本 skill (MinerU 精准模式) | 官方 API 已支持 Excel |
| `.html`/`.htm` | 本 skill (`mineru_html` 路由) | MinerU-HTML 模型 |
| `.png`/`.jpg`/`.jpeg`/`.jp2`/`.webp`/`.gif`/`.bmp` | 本 skill (MinerU 精准模式) | 图片 OCR |
| 目录批量、需要 `source.json/` 结构化 JSON | 本 skill (MinerU 精准模式) | 无 |
| 少量文件、只需 Markdown、对话内读取 | 官方 MCP `mineru_parse_documents` | 本 skill |
| 多格式输出 (docx/html/latex/json) | 官方 MinerU Document Extractor | 无 |
| URL 网页 crawl | 官方 MinerU Document Extractor `crawl` | 无 |
| 手写/低质/重复灌词 PDF 或图片 | `multimodal-looker`（通过 `--prefer-multimodal`） | 本 skill 输出 guidance |
| `csv/tsv/json/xml/epub/zip` | **不支持** | 不委托其他 skill |

## Agent 路由决策

根据需求选择合适的 MinerU 入口，避免所有场景都走同一个工具。

### 路由矩阵（Phase 1）

本 skill 的确定性路由结果为以下五个 canonical route 之一：

| Route | 含义 | 典型文件 |
| --- | --- | --- |
| `mineru` | MinerU 精准模式处理 | `.pdf` `.doc` `.docx` `.ppt` `.pptx` `.xls` `.xlsx` `.png` `.jpg` `.jpeg` `.jp2` `.webp` `.gif` `.bmp` |
| `mineru_html` | MinerU HTML 模型（`model_version="MinerU-HTML"`） | `.html` `.htm` |
| `multimodal_looker` | 输出多模态 OCR/vision guidance（Phase 1 不真实调用） | 仅 `--prefer-multimodal` 时的 PDF/图片 |
| `unsupported` | 明确不支持的格式 | `.csv` `.tsv` `.json` `.xml` `.epub` `.zip` 及其他未知扩展名 |
| `invalid_input` | 文件不存在、不可读或 0-byte | 任何官方支持格式但无法读取 |

### 三路径概览

- **官方 MCP**（`mineru_parse_documents`）：少量文件、只需 Markdown、对话内快速读取。使用 `MINERU_API_TOKEN` 认证。非 HTML 文档省略 `model` 参数，SDK 自动推断为 VLM。
- **官方 MinerU Document Extractor**（`mineru-open-api` CLI）：多格式输出（docx/html/latex/json）、网页 crawl。使用 `MINERU_TOKEN` 认证。支持 `--model vlm/pipeline/html`。
- **本 skill（convert-with-mineru）**：本地目录批量、确定性路由（5 canonical routes）、质量门控、稳定源文件名输出、结构化 JSON（`source.md`/`source.json/`/`source.images/`）。使用 `MINERU_TOKEN` 认证。HTML 文件使用 `model_version="MinerU-HTML"`。

### 决策矩阵

| 场景 | 首选工具 | 备选/说明 |
| --- | --- | --- |
| 少量 PDF/DOCX/PPTX/XLSX，只需 Markdown | 官方 MCP | 备选: 本 skill（本地批量时） |
| 本地目录批量转换，需稳定 source.md/source.json 输出 | 本 skill (convert-with-mineru) | 备选: MCP（少量时） |
| 需要 docx/html/latex/json 多格式输出 | 官方 MinerU Document Extractor / `mineru-open-api extract -f` | 无 |
| URL 网页解析/crawl | 官方 MinerU Document Extractor / `mineru-open-api crawl` | 无 |
| 手写/低质/重复灌词 PDF 或图片 | `multimodal-looker`（通过 `--prefer-multimodal`） | 本 skill 输出 guidance |
| HTML 文件 | 本 skill（`mineru_html` 路由） | MCP（少量时） |
| 图片 OCR | 本 skill（`mineru` 路由） | MCP（少量时） |
| CSV/TSV/JSON/XML/EPUB/ZIP | **不支持** | 不委托其他 skill |

### 何时不要调用本 skill

以下场景应优先选择其他工具，而不是本 skill：

- 少量文件 + 只需 Markdown + 对话内读取 → 优先用官方 MCP
- 需要多格式输出（docx/html/latex）或网页 crawl → 优先用官方 MinerU Document Extractor / CLI
- `csv/tsv/json/xml/epub/zip` → 本 skill 明确不支持

### Token 认证规则

- **MCP Server** 使用 `MINERU_API_TOKEN`，不是 `MINERU_TOKEN`
- **CLI/SDK/本 skill** 使用 `MINERU_TOKEN`，不是 `MINERU_API_TOKEN`
- MCP Precision/VLM 路径必须有 `MINERU_API_TOKEN`；只有 `MINERU_TOKEN` 时不能走 MCP 认证路径
- MCP 没有 `MINERU_MODEL` 或 `DEFAULT_MODEL` 全局环境变量；不要给 MCP 配置这些不存在的变量

### 模型选择规则

- 非 HTML 文档调用 MCP 时省略 `model` 参数，SDK 默认推断为 VLM
- HTML/网页 URL 才显式传 `model="html"`
- 强制 pipeline 模式才显式传 `model="pipeline"`

## Output Rules

- `source.pdf` -> `source.md`
- 精准模式 JSON 可用时 -> `source.json/`
  - `source.content_list.json`
  - `source.content_list_v2.json`
  - `source.layout.json`
  - `source.model.json`
  - 仅保存本次解析实际产出的类型
- 图片资源 -> `source.images/`
- 不再保留 `source.raw/`，也不保留解析阶段生成的源文件副本
- 发生重名冲突时使用 `__2`、`__3`
- 上述命名是本技能对外承诺的稳定 contract，不等于 MinerU 官方原生产物全集；官方可能还有额外中间文件，但默认不直接暴露给用户

## Config

优先使用环境变量 `MINERU_TOKEN`。

### Token 变量差异

本 skill 使用 `MINERU_TOKEN`（CLI/SDK 共用）。官方 MCP Server 使用不同的 `MINERU_API_TOKEN`。

- 只用本 skill 或 CLI：配置 `MINERU_TOKEN` 即可。
- 同时使用 MCP 和本 skill：需要分别配置 `MINERU_API_TOKEN`（MCP）和 `MINERU_TOKEN`（本 skill/CLI）。
- 不要把 `MINERU_TOKEN` 当作 MCP 的认证变量，反之亦然。
- MCP 没有 `MINERU_MODEL` 或 `DEFAULT_MODEL` 环境变量；不要尝试配置这些不存在的变量。

配置写法、PowerShell/CMD 设置方式、外置 `mineru.env` / `mineru.json` 示例，见：
- `references/configuration.md`
- `examples/mineru.env`
- `examples/mineru.json`

本地验证时如果目录里临时留有 `mineru..env` 这类真实配置文件，把它视为隔离对象，而不是示例文件或分发内容。

## Commands

单文件：

```powershell
$env:MINERU_TOKEN = "<在这里填写你的 MineU Token>"
python -m scripts.mineru_convert "C:\docs\report.pdf"
```

目录批量：

```powershell
$env:MINERU_TOKEN = "<在这里填写你的 MineU Token>"
python -m scripts.mineru_convert --recursive "C:\docs\folder"
```

外置配置文件：

```powershell
python -m scripts.mineru_convert --config "C:\Users\zengw\.config\opencode\local\mineru.env" "C:\docs\report.pdf"
```

生成可分发的过滤副本：

```powershell
python -m scripts.stage_distribution ".\dist\convert-with-mineru"
```

## Fallback

MinerU 路由矩阵与分流说明见：
- `references/fallback-routing.md`

质量门控说明见：
- `references/quality-gates.md`（Task 4 实现）

脚本级路由规则：
- `.pdf`/`.doc`/`.docx`/`.ppt`/`.pptx` → `mineru`
- `.xls`/`.xlsx` → `mineru`（官方 API 已支持）
- `.html`/`.htm` → `mineru_html`（`model_version="MinerU-HTML"`）
- `.png`/`.jpg`/`.jpeg`/`.jp2`/`.webp`/`.gif`/`.bmp` → `mineru`
- `.csv`/`.tsv`/`.json`/`.xml`/`.epub`/`.zip` → `unsupported`
- 不存在/不可读/0-byte → `invalid_input`
- `--prefer-multimodal` 时的 PDF/图片 → `multimodal_looker`（guidance-only）

## Known Issues

- SDK 超时：部分大文件转换可能触发 MinerU SDK 超时（benchmark 中 3/12 案例），重试通常有效
- 乱码 (mojibake)：个别文件出现编码乱码（benchmark 中 3/9 案例），根因待排查
- PPTX 双路径：当前 PPTX 走 MinerU 精准模式，未来可能增加本地解析路径

## Common Mistakes

- 直接把 ZIP 里的 `full.md` 当最终产物
- 让 `.md` 继续引用 `images/...`，却把图片目录改名成 `source.images/`
- 把所有结构化结果压成单个 `source.json`
- 漏写 `source.content_list_v2.json` 这类 MinerU 实际产出的 JSON 类型
- 把 `source.json/` 误说成官方完整 JSON 全量输出
- 在示例里写入真实 token
- 把 `xls/xlsx` 当作不支持（官方 API 已支持 Excel）
- 把 `MINERU_API_TOKEN` 和 `MINERU_TOKEN` 混用（MCP 用前者，本 skill/CLI 用后者，不能互换）
- 给 MCP 配置 `MINERU_MODEL` 或 `DEFAULT_MODEL`（这些变量不存在，MCP 通过 `model` 参数控制模型）
- URL 网页解析走本 skill（应走官方 MinerU Document Extractor 的 `crawl`）
- 需要多格式输出却走本 skill（本 skill 只输出 Markdown + JSON + 图片；多格式用官方 CLI `extract -f`）
- 少量文件只需 Markdown 却走本 skill（优先用官方 MCP，更简单直接）
- 尝试用本 skill 处理 `csv/tsv/json/xml/epub/zip`（明确不支持）
- 手写/低质/重复灌词场景不使用 `--prefer-multimodal` 导致输出质量差

## Red Flags

- "MineU 不支持也许也能跑"
- "没有 JSON 我就生成一个空 JSON"
- "把 token 写进配置示例里更方便"
- "多模态转写出来的东西也算 MinerU JSON"
- "Excel 不支持所以跳过"
- "图片应该走 multimodal-looker 默认"

这些都表示路径选错了，应立即改回正确路径。
