---
name: convert-with-mineru
description: Use when converting local documents or directories with MineU, especially when choosing between precision parsing and fallback routing, preserving source-based filenames, or routing scanned PDFs and images away from MineU into multimodal OCR.
---

# Convert With MineU

## Overview

把 MineU 作为本地文档转换主路径，但不要把它当成扫描件识别的默认入口。

核心原则：
- MineU 统一走精准模式（Precision API），不再有轻量模式。
- `xls/xlsx` 不被精准 API 支持，自动路由到 fallback。
- `.docx` 和数字导出 PDF 才是 MineU 的稳定主路径；扫描 PDF 与图片默认改走 `multimodal-looker`。
- MineU 不支持、超限、或 OCR 结果不可信时，立即切到 fallback，而不是硬跑。
- 最终输出必须按源文件名写出，不把 `full.md` 直接暴露给用户。

## When To Use

在这些场景使用本技能：
- 需要把本地 `pdf/doc/docx/ppt/pptx/html/htm` 或目录转换成 Markdown。
- 需要按源文件名保存结果，例如 `report.md`、`report.images/`、`report.json/report.content_list.json`。
- 需要识别数字导出 PDF、扫描 PDF、图片、MineU 不支持类型、超限类型，或 OCR 质量异常并切换正确路径。

在这些场景不要直接用 MineU 主路径：
- 只需要快速把 `csv/tsv/json/xml/epub/zip` 转成 Markdown：优先 `markdown-converter`。
- 需要高保真处理 Word、PPT、Excel：优先 `docx`、`pptx`、`xlsx`。
- `xls/xlsx` 文件：精准 API 不支持 Excel，脚本会自动路由到 fallback。
- 扫描 PDF、中文手写扫描件、潦草手写图像、或 MineU 出现重复灌词：如果本机已安装 `multimodal-looker`，优先切过去。

## Quick Reference

| 场景 | 路径 |
| --- | --- |
| `.docx` / 数字导出 PDF / `doc` / `ppt` / `pptx` / `html` / `htm` | MineU 精准模式 |
| 目录批量、需要 JSON | MineU 精准模式 |
| `xls/xlsx` | fallback（`xlsx` 技能或 `markdown-converter`） |
| 扫描 PDF / `png` / `jpg` / `jpeg` | `multimodal-looker` |
| `csv/tsv/json/xml/epub/zip` | `markdown-converter` |
| MineU 不支持或超限 | fallback |

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

MineU 支持矩阵与分流说明见：
- `references/fallback-routing.md`

中文手写扫描件转写流程见：
- `references/handwriting-transcription.md`

脚本级强制分流规则：
- `.docx` -> MineU
- 数字导出 PDF -> MineU
- `xls/xlsx` -> fallback（精准 API 不支持 Excel）
- 扫描 PDF / `png` / `jpg` / `jpeg` -> `multimodal-looker`
- `csv/tsv/json/xml/epub/zip` -> fallback
- 其余非扫描类格式维持现有 MineU / fallback 约束，不伪装成多模态 OCR

## Known Issues

- SDK 超时：部分大文件转换可能触发 MinerU SDK 超时（benchmark 中 3/12 案例），重试通常有效
- 乱码 (mojibake)：个别文件出现编码乱码（benchmark 中 3/9 案例），根因待排查
- PPTX 双路径：当前 PPTX 走 MineU 精准模式，未来可能增加本地解析路径

## Common Mistakes

- 直接把 ZIP 里的 `full.md` 当最终产物
- 让 `.md` 继续引用 `images/...`，却把图片目录改名成 `source.images/`
- 把所有结构化结果压成单个 `source.json`
- 漏写 `source.content_list_v2.json` 这类 MineU 实际产出的 JSON 类型
- 把 `source.json/` 误说成官方完整 JSON 全量输出
- 在示例里写入真实 token
- 明知是扫描 PDF、图片或中文手写扫描件还继续强压给 MineU
- MineU 已经出现重复灌词，却没有切到已安装的 `multimodal-looker`
- 把 `xls/xlsx` 送进 MineU（精准 API 不支持，应走 fallback）

## Red Flags

- "MineU 不支持也许也能跑"
- "没有 JSON 我就生成一个空 JSON"
- "把 token 写进配置示例里更方便"
- "多模态转写出来的东西也算 MineU JSON"
- "Excel 也走 MineU 试试"

这些都表示路径选错了，应立即改回正确路径或 fallback。
