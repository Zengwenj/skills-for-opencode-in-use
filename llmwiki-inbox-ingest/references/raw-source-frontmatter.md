# Raw Source Frontmatter

## Raw Frontmatter Schema

每个写入 `rawSourcesRoot` 的 Markdown 文件必须包含以下 YAML frontmatter：

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | inventory source_id |
| `run_id` | string | 是 | 本次 ingest run ID |
| `source_file` | string | 是 | 来自 committed archive_path 的归档文件路径 |
| `archive_path` | string | 是 | 来自 committed archive_path |
| `source_type` | string | 是 | 源文件扩展名（如 `pdf`、`docx`） |
| `theme` | string | 是 | 继承 committed classification/apply 的主题 |
| `year` | integer | 是 | 继承 committed classification/apply 的年份 |
| `parsed_date` | string | 是 | 解析日期 ISO 8601 |
| `status` | string | 是 | `raw-parsed` |
| `source_sha256` | string | 是 | committed archive 文件 SHA256 |
| `ingest_run` | string | 是 | 本次 run ID（与 run_id 相同） |
| `review_status` | string | 是 | `pending_review` 或 `reviewed` |

## 来源规则

- `source_file` 必须来自 committed archive_path（即 `apply-manifest.jsonl` 中的 archive_path）。
- `archive_path` 必须来自 committed archive_path。
- `source_sha256` 必须来自 committed archive 文件（不是 inbox 源文件）。
- **不得**指向 inbox 原件作为 raw 来源。
- `theme` 与 `year` 继承 committed classification/apply 结果，不建立 raw 专属分类体系。

## Raw Output Path

```
rawSourcesRoot/<theme>/<YYYY>/<safe_filename>.md
```

- `<theme>`：来自 committed classification 的 target_theme。
- `<YYYY>`：四位数年份。
- `<safe_filename>`：经 path-safety.md 规则处理的安全文件名。

## Collision Suffix

当 raw 目标路径已存在且 hash 不同时：

- 第一个冲突追加 `__2`
- 第二个冲突追加 `__3`
- 依此类推

不得覆盖已有 raw 文件。

## 质量门

写入 raw 前必须通过以下质量门：

1. Markdown 字节数 > 500。
2. 包含至少一个 Markdown heading（`# ` 开头）。
3. 不包含已知的 MinerU 错误占位文本。
4. source_id 与 batch/parse/apply 一致。
5. archive SHA256 与 apply-manifest 一致。

不通过质量门的文件进入 `failures.csv`（stage=`raw`），不写入 raw。

## 与其他 Layer 的关系

- `raw/sources` 是解析原料层，不替代 `资料库/` 原件。
- `raw/sources` 的主题/年份继承自 archive，不另起分类。
- `raw/sources` 中的文件是 `wiki/sources` 来源页的输入，但本 skill 不写 wiki/sources。
