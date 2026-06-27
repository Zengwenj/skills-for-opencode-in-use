# Run Artifacts 总表与 Schema

run 目录（`reviewRoot/YYYYMMDD-HHMMSS-<6位随机hex>/`）包含以下产物：

```text
inventory.jsonl
source_snapshot_before.csv
source_snapshot_after.csv
source_snapshot_diff.csv
classification-proposal.md
classification-plan.jsonl
proposal-manifest.json
approval.md
apply-log.md
apply-manifest.jsonl
mineru-batch.json
parse-manifest.csv
raw-output-manifest.csv
failures.csv
mineru-output/<source_id>/
evidence/
```

## 统一 Hash 规则

所有审批 hash 均为最终产物文件字节的 SHA256。禁止 apply 阶段重新序列化 JSON 后再计算 hash。

## 1. inventory.jsonl

生产阶段：scan。消费者：proposal、validate-run。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | 稳定 ID，由规范化相对路径和 SHA256 派生 |
| `run_id` | string | 是 | 当前 run 目录名 |
| `abs_path` | string | 是 | 源文件 canonical absolute path |
| `rel_path` | string | 是 | 相对 `inboxRoot` 的规范化路径 |
| `size` | integer | 是 | 文件字节数 |
| `mtime` | string | 是 | ISO 8601 修改时间 |
| `sha256` | string | 是 | 源文件 SHA256 |
| `parent_dir` | string | 是 | 相对父目录 |
| `extension` | string | 是 | 小写扩展名，含点 |
| `inferred_theme` | string | 是 | 推断主题；未知为空字符串 |
| `inferred_year` | integer/null | 是 | 推断年份或 null |
| `confidence` | number | 是 | 0 到 1 |
| `review_needed` | boolean | 是 | 是否必须人工审核 |

示例：

```json
{"source_id":"src_7f3a9c","run_id":"20260626-153000-a1b2c3","abs_path":"D:/vault/inbox/a.pdf","rel_path":"2026/a.pdf","size":12345,"mtime":"2026-06-26T15:30:00Z","sha256":"...","parent_dir":"2026","extension":".pdf","inferred_theme":"信息科技","inferred_year":2026,"confidence":0.82,"review_needed":false}
```

## 2. source_snapshot_before/after/diff.csv

### before/after 字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | 对应 inventory source_id |
| `rel_path` | string | 是 | 相对 inbox 路径 |
| `abs_path` | string | 是 | canonical absolute path |
| `sha256` | string | 是 | 当时源文件 SHA256 |
| `size` | integer | 是 | 文件字节数 |
| `mtime` | string | 是 | ISO 8601 修改时间 |
| `exists` | boolean | 是 | 文件是否存在 |

### diff 字段

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | source ID |
| `rel_path` | string | 是 | 相对 inbox 路径 |
| `before_sha256` | string/null | 是 | apply 前 SHA256 |
| `after_sha256` | string/null | 是 | apply 后 SHA256 |
| `change_type` | string | 是 | `unchanged`、`modified`、`missing`、`new` |
| `allowed` | boolean | 是 | 是否为允许变化；源文件默认必须 unchanged |
| `message` | string | 否 | 说明 |

## 3. classification-plan.jsonl

生产阶段：proposal。消费者：approval、apply、MinerU batch。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | inventory source_id |
| `run_id` | string | 是 | run ID |
| `action` | string | 是 | `archive_only`、`archive_and_raw`、`review_only`、`skip` |
| `source_abs_path` | string | 是 | 冻结的源路径 |
| `source_rel_path` | string | 是 | 冻结的相对路径 |
| `source_sha256` | string | 是 | 冻结的源 SHA256 |
| `target_archive_path` | string/null | 是 | 建议归档目标；skip 可为 null |
| `target_theme` | string/null | 是 | 来自 themeList 的主题 |
| `target_year` | integer/null | 是 | 目标年份 |
| `pack_key` | string/null | 否 | pack 候选键 |
| `enter_raw_sources` | boolean | 是 | 是否建议进入 raw |
| `mineru_candidate` | boolean | 是 | 是否候选 MinerU |
| `confidence` | number | 是 | 0 到 1 |
| `review_needed` | boolean | 是 | 是否人工复核 |
| `reason_codes` | array[string] | 是 | 分类原因和阻断原因 |

## 4. proposal-manifest.json

生产阶段：proposal。消费者：approval、apply、validate-run。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schema_version` | string | 是 | manifest schema 版本 |
| `run_id` | string | 是 | run ID |
| `scope` | string | 是 | config scope |
| `created_at` | string | 是 | ISO 8601 生成时间 |
| `config_sha256` | string | 是 | config 文件字节 SHA256 |
| `inventory_sha256` | string | 是 | inventory.jsonl 字节 SHA256 |
| `source_snapshot_before_sha256` | string | 是 | before snapshot 字节 SHA256 |
| `classification_plan_sha256` | string | 是 | classification plan 字节 SHA256 |
| `item_count` | integer | 是 | plan item 数 |
| `review_needed_count` | integer | 是 | review_needed 数 |
| `actions` | object | 是 | action 计数 |
| `artifact_paths` | object | 是 | 相关 artifact 相对路径 |

## 5. apply-manifest.jsonl

生产阶段：apply。消费者：MinerU batch、raw ingest、validate-run。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | source ID |
| `run_id` | string | 是 | run ID |
| `state` | string | 是 | 状态机状态 |
| `source_path` | string | 是 | 当前源路径 |
| `source_sha256` | string | 是 | 当前源 SHA256 |
| `archive_path` | string | 是 | final archive path |
| `archive_sha256` | string/null | 是 | committed 后 archive SHA256 |
| `temp_path` | string/null | 否 | temp copy path |
| `attempt` | integer | 是 | 尝试次数 |
| `timestamp` | string | 是 | ISO 8601 状态时间 |
| `error_code` | string/null | 否 | 失败代码 |
| `message` | string | 否 | 状态说明 |

状态机状态：`planned` → `copied_temp` → `committed` / `failed` / `skipped_existing_committed`。允许扩展：`preflight_failed`、`verified_temp`、`failed_partial_deleted`、`failed_divergent`。

## 6. mineru-batch.json

生产阶段：prepare-mineru-batch。消费者：agent MinerU bridge。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `schema_version` | string | 是 | batch schema 版本 |
| `run_id` | string | 是 | run ID |
| `created_at` | string | 是 | ISO 8601 生成时间 |
| `items` | array[object] | 是 | 仅来自 committed 或 skipped_existing_committed archive |
| `items[].source_id` | string | 是 | source ID |
| `items[].archive_path` | string | 是 | committed archive path |
| `items[].archive_sha256` | string | 是 | committed archive SHA256 |
| `items[].extension` | string | 是 | 扩展名 |
| `items[].mineru_route` | string | 是 | `mcp_flash`、`mcp_token`、`mock`、`skip_unsupported` |
| `items[].output_dir` | string | 是 | `mineru-output/<source_id>/` |
| `items[].language` | string/null | 否 | OCR 语言提示 |
| `items[].raw_target_hint` | string | 是 | raw 目标提示路径 |
| `items[].reason_if_skipped` | string/null | 否 | 跳过原因 |

## 7. parse-manifest.csv

生产阶段：agent MinerU bridge 或 mock mode。消费者：raw ingest、validate-run。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | source ID |
| `run_id` | string | 是 | run ID |
| `archive_path` | string | 是 | committed archive path |
| `archive_sha256` | string | 是 | archive SHA256 |
| `route` | string | 是 | `mcp_flash`、`mcp_token`、`mock` |
| `status` | string | 是 | `parsed`、`failed`、`skipped` |
| `output_path` | string/null | 是 | MinerU markdown 输出路径 |
| `content_bytes` | integer | 是 | 输出字节数 |
| `has_heading` | boolean | 是 | 是否含 Markdown 标题 |
| `validation_flags` | string | 否 | 分号分隔 flags |
| `error_type` | string/null | 否 | 错误类型 |
| `retry_count` | integer | 是 | 重试次数 |

## 8. raw-output-manifest.csv

生产阶段：raw ingest。消费者：validate-run。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `source_id` | string | 是 | source ID |
| `run_id` | string | 是 | run ID |
| `archive_path` | string | 是 | committed archive path |
| `archive_sha256` | string | 是 | archive SHA256 |
| `raw_path` | string | 是 | 写入 raw markdown 路径 |
| `raw_sha256` | string | 是 | raw 文件 SHA256 |
| `collision_suffix` | string/null | 否 | 无冲突为空；冲突如 `__2` |
| `status` | string | 是 | `written`、`skipped`、`failed` |
| `message` | string | 否 | 说明 |

## 9. failures.csv

生产阶段：任意阶段。消费者：operator、validate-run。

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `run_id` | string | 是 | run ID |
| `source_id` | string/null | 否 | 相关 source；全局失败可空 |
| `stage` | string | 是 | `config`、`scan`、`proposal`、`approval`、`apply`、`mineru`、`raw`、`validate` |
| `error_code` | string | 是 | 机器可读错误码 |
| `message` | string | 是 | 人可读错误 |
| `retryable` | boolean | 是 | 是否可重试 |
| `next_action` | string | 是 | 操作者下一步 |
| `artifact_path` | string/null | 否 | 相关产物路径 |

## 10. classification-proposal.md / apply-log.md / evidence/

- **classification-proposal.md：** 给人审阅的 Markdown 摘要。必填章节：run metadata、统计、review-needed 列表、apply candidates 列表、raw candidates 列表、failures/blocked。
- **apply-log.md：** apply 阶段人类可读日志。不得作为机器状态真相，机器真相以 `apply-manifest.jsonl` 为准。
- **evidence/：** runtime QA、命令输出、validator report。
