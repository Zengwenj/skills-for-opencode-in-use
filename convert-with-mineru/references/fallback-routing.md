# Fallback Routing

## MineU 主路径优先级

优先把 MineU 当成这些场景的主路径：
- 本地 `.docx` / 数字导出 PDF / 非扫描类 Office
- 需要 Markdown
- 需要结构化 JSON
- 需要目录批量

## 类型与限制分流

| 输入类型/情况 | 推荐路径 | 说明 |
| --- | --- | --- |
| 数字导出 `pdf` / `docx` | MineU | 稳定主路径 |
| 扫描 `pdf` / `png` / `jpg` / `jpeg` | `multimodal-looker` | 不再默认进 MineU |
| `doc/ppt/pptx` | MineU | 继续维持现有 MineU 路径 |
| `xls/xlsx` | fallback（`xlsx` 技能或 `markdown-converter`） | 精准 API 不支持 Excel |
| `html/htm` | MineU 精准模式 | 精准 API 支持 HTML |
| `csv/tsv/json/xml/epub/zip` | `markdown-converter` | 不必强绑 MineU |
| 文件超页数/超大小限制 | fallback | 不要强压 MineU |
| MineU 输出重复灌词 | 已安装时切 `multimodal-looker` | 说明 OCR 结果不可信 |

## fallback 推荐顺序

1. 通用文档兜底：`markdown-converter`
2. 类型专门化：`pdf` / `docx` / `pptx` / `xlsx`
3. 扫描件 / 图像转写：已安装时使用 `multimodal-looker`

## 分流准则

- MineU 能做且质量可信：继续 MineU
- MineU 不能做：立即切 fallback
- 扫描 PDF 和图片：默认不进 MineU，直接切 `multimodal-looker`
- MineU 能做但结果不可信：立即切 `multimodal-looker`
- fallback 产物也沿用源文件名规则，但不要伪装成 MineU JSON
