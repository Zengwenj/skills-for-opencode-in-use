---
status: pending
allow_apply: false
approved_by: ""
approved_at: ""
run_id: ""
scope: ""
config_sha256: ""
inventory_sha256: ""
source_snapshot_before_sha256: ""
classification_plan_sha256: ""
proposal_manifest_sha256: ""
---

# Approval — Pending

> ⚠️ 这是待审批模板。在人工审批完成前，`apply-approved-plan.ps1` 将拒绝此批次。

## 审批前检查清单

- [ ] 已阅读 `classification-proposal.md`
- [ ] 已逐项检查 `classification-plan.jsonl` 中的 action、theme、year、enter_raw_sources
- [ ] 已确认 review_needed 项的处理决定
- [ ] 已确认 hash 字段与当前产物文件一致

## 审批步骤

将此文件 frontmatter 中的以下字段从默认值改为批准值：

1. **status:** `pending` → `approved`
2. **allow_apply:** `false` → `true`
3. **approved_by:** `""` → 填入审批人标识（如 `"张三"`）
4. **approved_at:** `""` → 填入 ISO 8601 审批时间（如 `"2026-06-26T16:00:00+08:00"`）

不要修改 run_id、scope 和 hash 字段。

## 审批后

运行 `apply-approved-plan.ps1` 执行归档。

---

*此模板由 `build-proposal.ps1` 生成。agent 和脚本均不得写入 `status: approved`。*
