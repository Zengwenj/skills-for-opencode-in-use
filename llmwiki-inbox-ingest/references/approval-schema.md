# Approval Schema — 11 字段 YAML 与 Fail-Closed 规则

## 11 字段 Schema

`approval.md` 的 YAML frontmatter 必须精确包含以下 11 个字段：

| # | 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | `status` | string | 是 | 默认 `pending`；人工批准时必须为 `approved` |
| 2 | `allow_apply` | boolean | 是 | 默认 `false`；人工批准时必须为 `true` |
| 3 | `approved_by` | string | 是 | 人工审批人标识；不得为空/占位 |
| 4 | `approved_at` | string | 是 | ISO 8601 人工审批时间；不得为空/占位 |
| 5 | `run_id` | string | 是 | 必须匹配当前 run ID |
| 6 | `scope` | string | 是 | 必须匹配 config scope |
| 7 | `config_sha256` | string | 是 | 必须匹配 config 文件字节 SHA256 |
| 8 | `inventory_sha256` | string | 是 | 必须匹配 inventory.jsonl 字节 SHA256 |
| 9 | `source_snapshot_before_sha256` | string | 是 | 必须匹配 before snapshot 字节 SHA256 |
| 10 | `classification_plan_sha256` | string | 是 | 必须匹配 classification plan 字节 SHA256 |
| 11 | `proposal_manifest_sha256` | string | 是 | 必须匹配 proposal manifest 字节 SHA256 |

## Fail-Closed 规则

以下任一情况必须拒绝 apply，且不得写 archive 或 raw：

1. approval schema 字段缺失或拼错。
2. 字段仍为空、`TODO`、`pending`、`false` 或其他占位值。
3. `status != "approved"`。
4. `allow_apply != true`。
5. `run_id` 与当前 run 目录名不匹配。
6. `scope` 与 config scope 不匹配。
7. 任一 hash 与对应产物文件字节 SHA256 不匹配（config、inventory、source_snapshot_before、classification plan、proposal manifest）。
8. `approval.md` 由 agent 或脚本自动写成 approved。

## Agent/Script 禁止行为

- agent 和脚本均不得写入 `status: approved`。
- agent 和脚本均不得写入 `allow_apply: true`。
- agent 和脚本只能生成 `status: pending` 与 `allow_apply: false` 的模板。
- `$start-work`、计划批准、proposal 生成成功都不等于批次批准。

## 额外替代字段

任何 schema 中未定义的额外字段（如 `reviewer`、`approved`、`authorized`）不得作为批准信号，且出现时应视为 schema 错误处理（fail closed 或明确警告）。

## Schema 版本

当前 schema 版本为 `1.0`。将来如增加字段需更新本文件并同步更新 `proposal-manifest.json` 中的 `schema_version`。
