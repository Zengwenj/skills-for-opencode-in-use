---
name: convert-with-mineru
description: Use when converting local document directories or files with MinerU precision batch mode, preserving source-based filenames for Markdown and images output with quality gating. Handwriting enhancement routes PDFs/images through MinerU first, then a vision-corrected, conservatively-revised task package flow.
---

# Convert With MinerU

## Overview

把 MinerU Precision API 作为本地文档批量转换的唯一 MinerU 路径，覆盖所有官方支持格式。

**Canonical batch path**: 批量转换通过 lifecycle runner（`scripts/mineru_lifecycle_runner.py`）驱动完整 Precision API 批量生命周期（prepare/submit/upload/poll/download/remap/validate）。lifecycle runner 的定义和契约见 `llmwiki-inbox-ingest/references/mineru-bridge-contract.md`。

**Bounded single-file diagnostic**: CLI `python -m scripts.mineru_convert` 保留为 operator 手动诊断单个文件的工具，不作为批量默认路径。

核心原则：
- 本 skill 使用 MinerU 时**只允许**精准模式（Precision API，`/api/v4/*`）。
- 非 HTML 文件必须显式传递 `model_version: "vlm"`，不得依赖官方默认 `pipeline`。
- HTML/HTM 文件如由 MinerU 处理，必须显式传递 `model_version: "MinerU-HTML"`。
- Agent 轻量解析 API `/api/v1/agent/parse/*`、MCP `mineru_parse_documents`、flash/轻量路径都不是本 skill 的 MinerU 路径，也不得作为自动 fallback。
- 官方支持格式（`pdf/doc/docx/ppt/pptx/xls/xlsx/html/htm/png/jpg/jpeg/jp2/webp/gif/bmp`）全部走 MinerU。
- `csv/tsv/json/xml/epub/zip` 明确不支持（`unsupported`），不委托其他 skill。
- 不存在、不可读、0-byte 的官方支持格式路由到 `invalid_input`。
- 正式输出只有 `source.md` + `source.images/`，不产出 JSON。
- `--prefer-multimodal` 是**手写校对管道**的显式 opt-in：PDF/图片仍先经 MinerU Precision 转写，转换后生成手写校对任务包，由 agent 编排层（multimodal-looker subagent / omp vision role）做视觉补充识别与语义修订，脚本本身零 LLM API 调用。

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
| 批量转换（canonical） | Lifecycle runner: `scripts/mineru_lifecycle_runner.py` | Precision API 批量生命周期（prepare/submit/upload/poll/download/remap/validate）；契约见 `llmwiki-inbox-ingest/references/mineru-bridge-contract.md` |
| 单文件手动诊断 | `python -m scripts.mineru_convert <file>` | Bounded single-file diagnostic；非 HTML 显式 `model_version: "vlm"`，HTML/HTM 显式 `model_version: "MinerU-HTML"` |
| 单目录 CLI | `python -m scripts.mineru_convert --recursive <folder>` | 同上，循环调用单文件转换；不是批量默认路径 |
| 启用审计归档 | 追加 `--audit-dir <path>` | 生成 raw archive、batch manifest、per-file manifest |
| 手写/低质 PDF 或图片 | 追加 `--prefer-multimodal` | MinerU 先转 + 生成手写校对任务包，视觉补充识别与语义修订由 agent 编排层完成（见下文手写管道） |
| 外置配置文件 | 追加 `--config <path>` | 参考 `examples/mineru.env` |
| `csv/tsv/json/xml/epub/zip` | **不支持** | 不委托其他 skill |

## Routes

本 skill 的确定性路由结果为以下四个 canonical route 之一：

| Route | 含义 | 触发条件 |
| --- | --- | --- |
| `mineru` | MinerU Precision API `vlm` 模型 | 非 HTML 的官方支持格式 |
| `mineru_html` | MinerU Precision API `MinerU-HTML` 模型 | `.html` `.htm` |
| `unsupported` | 明确不支持的格式 | `.csv` `.tsv` `.json` `.xml` `.epub` `.zip` 等 |
| `invalid_input` | 文件不存在、不可读或 0-byte | 任何官方支持格式但无法读取 |

`multimodal_looker` 不再是前置路由值：`--prefer-multimodal` 不改变路由，PDF/图片仍走 `mineru` 先转写。质量门控失败时 manifest 中的 `suggested_route: "multimodal_looker"` 语义为"建议走手写校对管道"。

## Output Rules

正式输出仅包含以下产物，**不产出任何 JSON**：

- `source.md`：Markdown 正文，图片路径已重写为 `source.images/` 前缀
- `source.images/`：MinerU 提取的图片资源

不保留 `source.json/`、`content_list*.json`、`layout.json`、`model.json`。

- 重名冲突使用 `__2`、`__3` 后缀。
- Per-file manifest（`source.manifest.json`）仅在启用 `--audit-dir` 时生成，是审计元数据而非 MinerU 原生 JSON。
- Raw 归档仅存入外部审计目录 `_review/mineru/<batch_id>/raw/`，不放入正式输出目录。
- 手写校对任务包（`<stem>.handwriting-task/`）是流程中间产物而非正式输出；finalize 后 `source.md` 为修订终稿，三稿与报告留在任务包目录内供追溯。

## Commands

### Canonical Batch: Lifecycle Runner

批量转换的入口是 lifecycle runner（`scripts/mineru_lifecycle_runner.py`），它驱动完整 Precision API 批量生命周期。详细契约和调用方法见 `llmwiki-inbox-ingest/references/mineru-bridge-contract.md`。

### Bounded Single-File Diagnostic: CLI

以下 CLI 命令仅用于 operator 手动诊断单个或少量文件，不作为批量默认路径：

单文件手动诊断：

```powershell
python -m scripts.mineru_convert <file>
```

该入口只使用 MinerU Precision API：非 HTML 批次显式传 `model_version: "vlm"`，HTML/HTM 批次显式传 `model_version: "MinerU-HTML"`。

启用审计归档：

```powershell
python -m scripts.mineru_convert --audit-dir "C:\audit\mineru" --recursive <folder>
```

也可通过环境变量 `MINERU_AUDIT_DIR` 或配置文件的 `AUDIT_DIR` 键设置。默认归档路径为 `<output_root>/../_review/mineru/<batch_id>/`。

显式 opt-in 手写校对管道：

```powershell
python -m scripts.mineru_convert --prefer-multimodal <file>
```

`--prefer-multimodal` 下 PDF/图片**仍先经 MinerU Precision 转写**（不再前置绕过），转换后为每个 PDF/图片产物生成手写校对任务包（`<stem>.handwriting-task/`），并打印后续步骤 guidance。非 PDF/图片文件带此 flag 也按常规 MinerU 转换处理（打印跳过提示）。见下文"手写文档管道"。

任务包收尾：

```powershell
python -m scripts.mineru_handwriting finalize <任务包目录>
```

`--require-json` 已弃用，仅打印 warning。

## 手写文档管道（Handwriting Pipeline）

三段式分工——脚本做确定性工作，agent 编排层做识别与修订：

```
python -m scripts.mineru_convert <手写文件> --prefer-multimodal
  ① 输入预检（WARNING 不阻断）：DPI<150、宽高比>2:1 疑似双页粘连
  ② MinerU Precision vlm 高精度转写 → 草稿
  ③ prepare：生成自包含任务包 + guidance
        ↓ agent 编排层
  ④ 视觉补充识别 → supplement.md
  ⑤ 语义修订 → revised.md
        ↓
python -m scripts.mineru_handwriting finalize <任务包目录>
  ⑥ 校验产物与页标记 → 重叠去重（后批为准）→ 剥离两级标记入报告
  ⑦ 图片引用机械回填 → 终稿门控复跑 → source.md ← 终稿
```

**任务包结构**（`<output_root>/<stem>.handwriting-task/`）：`task.json`（机器可读清单）、`TASK.md`（自包含指令）、`draft.md`、`pages/page-NNN.png`、`supplement.md`（视觉角色写入）、`revised.md`（修订角色写入）。任务包被输入发现与 dist 分发排除。

**角色契约**：
- 视觉补充识别：multimodal-looker subagent 或 omp vision role（模型基准 `gpt-5.6-terra:xhigh` 或 `kimi-k3:max`，**禁止配置 glm 系列模型**）。忠实抄录，看不清打 `<!-- low-confidence -->` 禁止猜测，图片引用行原样保留，每页以 `<!-- page: N -->` 开头。
- 语义修订：主 agent 或任意强文本角色（不绑定模型）。分级修订：明确识别错误则修、明确原文风格则留、中间地带打 `<!-- uncertain -->`；禁止增删段落/改结构/改图片引用/人名地名数字归一化。
- 分批：≤10 页单批；>10 页按 ≤5 页/批且每批重叠上一批最后一页，重叠页后批为准（finalize 机械去重）。

**产物与验收**：source.md 为修订终稿；三稿（draft/supplement/revised）+ `handwriting-report.json` 留痕于任务包目录。验收 = 终稿门控全绿 + 人工抽查三稿 diff（首、中、末页）。

**降级**：页图渲染失败 → 任务包标记 degraded，草稿版 source.md 不受影响；agent 环节缺失 → finalize 报错列缺失项，source.md 保持草稿版可重试；终稿门控失败 → exit 2 人工裁决，不静默回退。

**已知限制**：多栏/竖排/批注穿插导致的阅读顺序错乱、印刷+手写混排表单不在本管道处理范围（表格逐格转写与公式 `$...$` 由 TASK.md 指令覆盖）。

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

以下工具不是本 skill 的 MinerU 路径，也不得作为自动 fallback：

| 场景 | 工具 | 说明 |
| --- | --- | --- |
| Agent/MCP 轻量或对话内解析 | 官方 MCP `mineru_parse_documents`、Agent 轻量解析 API `/api/v1/agent/parse/*`、flash/轻量路径 | 本 skill 不使用；不能替代 Precision API/VLM，也不能在失败后自动切换 |
| 需要 docx/html/latex 等多格式输出 | 官方 MinerU Document Extractor CLI | `mineru-open-api extract -f` |
| URL 网页解析/crawl | 官方 MinerU Document Extractor `crawl` | 本 skill 只支持本地 `.html/.htm` |

## Fallback

MinerU 路由矩阵与分流说明见：
- `references/fallback-routing.md`

质量门控结果记录在 per-file manifest 的 `warnings` 字段（需 `--audit-dir`），不改变路由阈值。

Fallback 在本 skill 中只表示：失败即失败并记录错误，或用户显式指定 `--prefer-multimodal` 时进入手写校对管道（MinerU 先转 + 任务包后置补充，不是绕过 MinerU）。不得自动切到 MCP、Agent 轻量解析 API、flash 或官方默认 `pipeline`。

脚本级路由规则：
- `.pdf`/`.doc`/`.docx`/`.ppt`/`.pptx`/`.xls`/`.xlsx` → `mineru`（`vlm` 模型）
- `.html`/`.htm` → `mineru_html`（`MinerU-HTML` 模型）
- `.png`/`.jpg`/`.jpeg`/`.jp2`/`.webp`/`.gif`/`.bmp` → `mineru`（`vlm` 模型）
- `.csv`/`.tsv`/`.json`/`.xml`/`.epub`/`.zip` → `unsupported`
- 不存在/不可读/0-byte → `invalid_input`
- `--prefer-multimodal` 不改变以上路由：PDF/图片照走 `mineru`，转换后进入手写校对管道

## Known Issues

- `_extract_one` fallback 路径（当 SDK 不提供 `extract_batch` 时）对非 HTML 调用 `client.extract(str(source))`，未显式传递 model，可能依赖 SDK 默认 `pipeline`。主路径在 `extract_batch` 可用时显式传 `model_version: "vlm"` 或 `"MinerU-HTML"`，因此风险较低。
- SDK 超时：大文件可能触发 MinerU SDK 超时，重试通常有效
- 乱码 (mojibake)：个别文件编码问题，根因待排查

## Common Mistakes

- 期望 JSON 输出（本 skill 正式输出不含 JSON，`--require-json` 已弃用）
- 把 `MINERU_API_TOKEN` 和 `MINERU_TOKEN` 混用（MCP 用前者，本 skill/CLI 用后者，不能互换）
- 把 `xls/xlsx` 当作不支持（官方 API 已支持 Excel）
- 尝试用本 skill 处理 `csv/tsv/json/xml/epub/zip`（明确不支持）
- 把 MCP `mineru_parse_documents`、Agent 轻量解析 API、flash 或默认 `pipeline` 当作本 skill fallback
- 手写/低质场景只加 `--prefer-multimodal` 却不做视觉校对/语义修订/finalize 三步，误以为转写即完成
- 直接把 ZIP 里的 `full.md` 当最终产物
- 让 `.md` 继续引用 `images/...`，却把图片目录改名成 `source.images/`
- 通过 `$env:MINERU_API_TOKEN` 检查 opencode MCP 是否已配置 token（MCP environment 在 `opencode.json` 中，与 shell 环境变量独立）
- 把 raw 审计归档当成正式输出的一部分（raw 只在 `_review` 审计目录）
- 期望 `source.manifest.json` 是 MinerU 原生 JSON（manifest 是本 skill 生成的审计元数据，仅 `--audit-dir` 时存在）

## Red Flags

- "MineU 不支持也许也能跑"
- "没有 JSON 我就生成一个空 JSON"
- "Excel 不支持所以跳过"
- "--prefer-multimodal 应该绕过 MinerU 直接交给视觉模型"
- "视觉校对环节用 glm 系列模型也行"
- "语义修订就是把文本润色通顺"（应分级保守修订，目标是还原原文）
- "Precision API 失败就自动切 MCP/flash/Agent 轻量解析"
- "不传 model_version，让官方默认 pipeline 决定"

这些都表示路径选错了，应立即改回正确路径。
