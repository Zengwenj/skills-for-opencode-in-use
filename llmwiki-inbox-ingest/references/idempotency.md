# 幂等性与 Apply 状态机

## apply-manifest.jsonl 状态机

apply 阶段每个 item 必须通过以下状态转移：

```
planned → copied_temp → committed
                      → failed
                      → failed_partial_deleted
planned → skipped_existing_committed
planned → preflight_failed
        → failed_divergent
```

### 核心状态

| 状态 | 含义 |
| --- | --- |
| `planned` | 进入 apply 阶段，等待处理 |
| `copied_temp` | 源文件已复制到 temp 路径 |
| `committed` | temp 通过 SHA256 验证，已原子 rename 为 final |
| `failed` | 处理失败，已清理 partial |
| `skipped_existing_committed` | 目标已存在且 hash 匹配，跳过 |

### 扩展状态

| 状态 | 含义 |
| --- | --- |
| `preflight_failed` | apply 前检查失败（source 变化、target 存在等） |
| `verified_temp` | temp 已通过 SHA256 验证，等待 rename |
| `failed_partial_deleted` | temp 验证失败，已删除 partial copy |
| `failed_divergent` | 幂等重跑时发现 divergence，拒绝处理 |

## 幂等重跑规则

当 `apply-approved-plan.ps1` 在同一 run 目录重跑时：

1. 对于状态为 `committed` 的 item：检查 `source_id + archive_path + source_sha256` 是否完全一致，且 final target 存在且 hash 相同。
   - 完全匹配：记录 `skipped_existing_committed`，不重复复制。
   - 任一字段 divergence：fail closed，记录 `failed_divergent`。不覆盖、不猜测、不自动修复。

2. 对于状态为 `failed` / `failed_partial_deleted` 的 item：检查 preflight 后从 `planned` 开始重新处理。

3. 对于非 terminal 状态（`copied_temp`、`verified_temp`）：视为上次运行异常中断，检查 temp 路径是否仍存在，清理后重新处理。

## Apply Lock

- apply 开始时创建 `.apply.lock` 文件。
- `.apply.lock` 已存在时拒绝执行。
- apply 完成（成功或失败）后不自动删除 `.apply.lock`。由操作者确认后手动删除或通过 `validate-run.ps1` 提示。
- 第一版不实现 stale-lock 自动解除。

## 每项 Apply 前检查

每个 item 在复制前必须重新验证：

1. source 仍存在且路径有效。
2. source 当前 hash 与 classification-plan 中冻结的 `source_sha256` 一致。
3. target canonical path 位于 `archiveRoot` 内（containment）。
4. target 不存在，除非满足 exact idempotent committed match。
5. source path 不在 `archiveRoot`、`rawSourcesRoot`、`reviewRoot` 内。
6. source_id 与 plan 一致。
7. extension policy 允许归档（见 capability matrix）。

## Copy + Verify + Atomic Commit 流程

```
1. copy source → target.tmp    (在 archiveRoot 内创建 temp 副本)
2. hash target.tmp             (计算 temp 副本 SHA256)
3. compare tmp hash vs source hash
4. if match: atomic rename target.tmp → final target
5. if mismatch: delete target.tmp, record failure (failed_partial_deleted)
6. after commit: verify source still exists and hash unchanged
```

## 失败清理

以下情况必须清理并记录：

- temp copy hash mismatch：删除 target.tmp，记录 `failed_partial_deleted`。
- rename 失败：删除可识别的 temp 文件，记录 `failed`。
- post-commit source 变化：记录 `failures.csv`（但 archive 已 committed 不回滚，源文件变化需人工关注）。
- 任一异常：不得把失败项标记为 `committed`。

## Source Retained

- 整个流程不删除、不移动 inbox 源文件。
- copy + verify + atomic rename 只发生在 archiveRoot 内。
- post-commit 校验确认源文件仍存在且未变。
