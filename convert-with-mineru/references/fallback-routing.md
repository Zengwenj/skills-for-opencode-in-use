# Routing Matrix

## Canonical Routes (Phase 1)

本 skill 的确定性路由返回以下五个值之一：

| Route | 含义 |
| --- | --- |
| `mineru` | MinerU 精准模式处理 |
| `mineru_html` | MinerU HTML 模型（`model_version="MinerU-HTML"`） |
| `multimodal_looker` | 多模态 OCR/vision guidance（Phase 1 仅输出 guidance，不真实调用） |
| `unsupported` | 明确不支持的格式 |
| `invalid_input` | 文件不存在、不可读或 0-byte |

## 路由决策

| 输入类型 | Route | 说明 |
| --- | --- | --- |
| `.pdf` | `mineru` | 所有 PDF 统一走 MinerU |
| `.doc` `.docx` `.ppt` `.pptx` | `mineru` | Office 文档 |
| `.xls` `.xlsx` | `mineru` | 官方 API 已支持 Excel |
| `.html` `.htm` | `mineru_html` | 使用 MinerU-HTML 模型 |
| `.png` `.jpg` `.jpeg` `.jp2` `.webp` `.gif` `.bmp` | `mineru` | 图片 OCR |
| `.csv` `.tsv` `.json` `.xml` `.epub` `.zip` | `unsupported` | 明确不支持 |
| 未知扩展名 | `unsupported` | 不委托其他 skill |
| 不存在 / 不可读 / 0-byte | `invalid_input` | 官方支持格式但无法读取 |

## `--prefer-multimodal` 行为

当传入 `--prefer-multimodal` 时，PDF 和官方图片格式路由到 `multimodal_looker`（guidance-only）。Phase 1 不真实调用多模态 OCR/vision 工具，仅在输出中提供 guidance。

guidance-only 路径不产生转换产物，因此整体 exit 2。

## 分流准则

- 官方支持格式 → `mineru` 或 `mineru_html`
- 明确不支持的格式 → `unsupported`，不委托其他 skill
- 文件无法读取 → `invalid_input`
- 质量门控失败后 → 输出结构化 guidance（source、gate、reason、suggested route），不自动调用多模态工具
