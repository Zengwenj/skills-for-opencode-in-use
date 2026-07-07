# Routing Matrix

## Canonical Routes (Phase 2)

本 skill 的确定性路由返回以下五个值之一：

| Route | 含义 |
| --- | --- |
| `mineru` | MinerU Precision API（非 HTML 必须显式 `model_version: "vlm"`） |
| `mineru_html` | MinerU HTML 模型（`model_version="MinerU-HTML"`） |
| `multimodal_looker` | 非 MinerU 的多模态 OCR/vision guidance，显式 opt-in（`--prefer-multimodal`） |
| `unsupported` | 明确不支持的格式 |
| `invalid_input` | 文件不存在、不可读或 0-byte |

## 批量路径：Lifecycle Runner

本 skill 的 canonical batch 路径是 Precision API lifecycle runner（定义见 `llmwiki-inbox-ingest/references/mineru-bridge-contract.md` 的 "Precision API Lifecycle Contract" 章节）。lifecycle runner 驱动完整批量生命周期（prepare/submit/upload/poll/download/remap/validate），是唯一默认批量路径。

CLI `python -m scripts.mineru_convert` 是 bounded single-file diagnostic 工具，用于 operator 手动诊断单个文件，不作为批量默认路径。CLI long-polling 不在批量路径中使用。

MCP `mineru_parse_documents` 和 Agent 轻量 API `/api/v1/agent/parse/*` 是 non-batch manual diagnostic 工具，仅 operator 显式请求时使用，不作为批量默认或失败 fallback。

## 路由决策

| 输入类型 | Route | 说明 |
| --- | --- | --- |
| `.pdf` | `mineru` | Precision API，显式 `model_version: "vlm"` |
| `.doc` `.docx` `.ppt` `.pptx` | `mineru` | Precision API，显式 `model_version: "vlm"` |
| `.xls` `.xlsx` | `mineru` | Precision API，显式 `model_version: "vlm"`，官方 API 已支持 |
| `.html` `.htm` | `mineru_html` | MinerU-HTML 模型 |
| `.png` `.jpg` `.jpeg` `.jp2` `.webp` `.gif` `.bmp` | `mineru` | Precision API，显式 `model_version: "vlm"`，图片 OCR |
| `.csv` `.tsv` `.json` `.xml` `.epub` `.zip` | `unsupported` | 明确不支持 |
| 未知扩展名 | `unsupported` | 不委托其他 skill |
| 不存在 / 不可读 / 0-byte | `invalid_input` | 官方支持格式但无法读取 |

## `--prefer-multimodal` 行为

`--prefer-multimodal` 是非 MinerU 的显式 opt-in 路由，仅用户主动请求时使用。PDF 和官方图片格式路由到 `multimodal_looker`（guidance-only）。本 skill 不真实调用多模态 OCR/vision 工具，仅在输出中提供 guidance。

guidance-only 路径不产生转换产物，因此整体 exit 2。

手写/低质扫描件的推荐路径：先走 Precision API 的 vlm（`mineru` route），若 vlm 输出质量不满足需求，再由用户显式 opt-in `--prefer-multimodal`。这不是 MinerU fallback，也不会自动切换到 MCP、Agent 轻量 API、flash 或默认 `pipeline`。

## Fallback 定义

本 skill 的 fallback 只能是以下两种结果：

- Precision API 失败：失败即失败，记录错误或 manifest warning，不自动改走其他 MinerU/Agent 路径。
- 用户显式传 `--prefer-multimodal`：进入非 MinerU 的 `multimodal_looker` guidance-only 路由。

禁止把 MCP `mineru_parse_documents`、Agent 轻量解析 API `/api/v1/agent/parse/*`、flash/轻量路径或官方默认 `pipeline` 作为 fallback。

## 分流准则

- 官方支持格式 → `mineru` 或 `mineru_html`，且显式传 `model_version`
- 明确不支持的格式 → `unsupported`，不委托其他 skill
- 文件无法读取 → `invalid_input`
- 质量门控失败后 → 输出结构化 guidance（source、gate、reason、suggested route），不自动调用多模态工具，不自动调用 MCP/Agent/flash。
