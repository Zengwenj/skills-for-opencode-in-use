# 人工审批工作流

## 何时需要审批

运行 `build-proposal.ps1` 后，run 目录中会生成 `approval.md` 模板。此时所有文件的 `approval.md` 都处于 `status: pending`、`allow_apply: false` 状态。在人工审批完成之前，不得运行 `apply-approved-plan.ps1`。

## 审批步骤

### 1. 审阅 classification-proposal.md

打开 run 目录中的 `classification-proposal.md`，检查：

- run metadata 是否正确（时间、scope、文件数）。
- review-needed 列表是否合理。关注 `review_needed_reason_codes`。
- apply candidates 和 raw candidates 是否与预期一致。
- failures/blocked 列表是否为空或可接受。

### 2. 审阅 classification-plan.jsonl

逐项检查每条 action：

- `action` 是否合理（`archive_only` vs `archive_and_raw` vs `review_only` vs `skip`）。
- `target_archive_path` 是否与预期归档位置一致。
- `target_theme` 和 `target_year` 是否正确。
- `enter_raw_sources` 和 `mineru_candidate` 是否符合预期。

### 3. 编辑 approval.md

打开 `approval.md` 文件，修改 YAML frontmatter 中的以下字段：

```yaml
---
status: approved                    # 从 pending 改为 approved
allow_apply: true                   # 从 false 改为 true
approved_by: "your-identifier"      # 填入审批人标识
approved_at: "2026-06-26T16:00:00+08:00"  # 填入 ISO 8601 审批时间
run_id: ""                          # 核对与当前 run 目录名一致
scope: ""                           # 核对与 config scope 一致
config_sha256: ""                   # 核对与 config 文件 SHA256 一致
inventory_sha256: ""                # 核对与 inventory.jsonl SHA256 一致
source_snapshot_before_sha256: ""   # 核对与 before snapshot SHA256 一致
classification_plan_sha256: ""      # 核对与 classification plan SHA256 一致
proposal_manifest_sha256: ""        # 核对与 proposal manifest SHA256 一致
---
```

hash 字段的值由 `build-proposal.ps1` 在生成模板时自动填入。审批时需核对这些 hash 是否与当前产物文件一致（如期间重新生成过 proposal，hash 会变化）。

### 4. 不要做什么

- **不要**让 agent 或脚本填写 `status: approved` 或 `allow_apply: true`。
- **不要**删除或重命名 YAML frontmatter 中的任何字段。
- **不要**添加 schema 外的额外字段。
- **不要**在 hash 不匹配时强行 apply。
- **不要**修改 run_id、scope 或 hash 字段（审批人只修改 status、allow_apply、approved_by、approved_at）。
- **不要**复制其他 run 的 approval.md 到当前 run。
- **不要**在 proposal 生成前手动创建 approval.md。

## 审批完成后的验证

运行 `apply-approved-plan.ps1` 前，脚本会自动做以下验证（无需人工操作）：

1. 检查 11 字段完整性。
2. 检查 `status == "approved"` 且 `allow_apply == true`。
3. 重新计算 config、inventory、source_snapshot_before、classification plan、proposal manifest 的 SHA256。
4. 比对 hash 是否匹配。
5. 比对 run_id 和 scope。

任意一项不通过，脚本拒绝 apply 并输出明确的错误信息。

## 常见问题

**Q: 审批后发现 classification-plan 需要修改怎么办？**

重新运行 `build-proposal.ps1` 会生成新的 run 目录（新的时间戳 + 随机 hex），不会覆盖已有 run。旧的 run 目录可保留作为审计记录。

**Q: hash 不匹配怎么办？**

这通常意味着 proposal 生成后产物文件被修改。重新运行 `build-proposal.ps1` 生成新的 proposal 和 approval 模板。

**Q: 可以批量审批吗？**

一个 `approval.md` 对应一个 run 目录。每个 run 独立审批。不要跨 run 复用 approval 文件。
