# 借鉴的历史 Artifact 命名与安全规则

## 历史命名模式

历史 `_review` 中已出现的命名模式作为本 skill schema 命名的参考来源：

| 历史路径 | 本 skill 对应物 |
| --- | --- |
| `scan-classify/<timestamp>/inventory.jsonl` | `inventory.jsonl`（保留） |
| `scan-classify/<timestamp>/candidates.csv` | `classification-plan.jsonl`（结构化升级） |
| `scan-classify/<timestamp>/candidates.jsonl` | `classification-plan.jsonl` |
| `scan-classify/<timestamp>/pack-candidates.md` | `classification-proposal.md`（更名，扩大范围） |
| `scan-classify/<timestamp>/pack-candidates.jsonl` | `classification-plan.jsonl` |
| `scan-classify/<timestamp>/conflicts.md` | `classification-proposal.md` 内 review-needed 节 |
| `scan-classify/<timestamp>/conflicts.jsonl` | `classification-plan.jsonl`（review_needed 字段） |
| `scan-classify/<timestamp>/precheck-report.md` | `classification-proposal.md` |
| `scan-classify/<timestamp>/approval.md` | `approval.md`（升级为 11 字段精确 schema） |
| `parse-generate/<timestamp>/source_snapshot_before.csv` | `source_snapshot_before.csv`（保留） |
| `parse-generate/<timestamp>/source_snapshot_after.csv` | `source_snapshot_after.csv`（保留） |
| `parse-generate/<timestamp>/source_snapshot_diff.csv` | `source_snapshot_diff.csv`（保留） |
| `parse-generate/<timestamp>/mineru_manifest.csv` | `parse-manifest.csv`（更名） |
| `parse-generate/<timestamp>/llm_wiki_ingest_manifest.csv` | `raw-output-manifest.csv`（更名） |
| `parse-generate/<timestamp>/failures.csv` | `failures.csv`（保留） |

## 继承的安全规则

历史流程已验证以下安全规则有效，本 skill 完整继承：

1. **copy + SHA256 verify + source retained。**
2. **never Move-Item source。** 源文件始终保留在原位。
3. **approval required before apply。** 无人工审批不得进入正式 archive。
4. **hash closure for approval。** 审批时必须比对产物 SHA256，防止"审批后篡改"。

## 命名改进

本 skill 在历史基础上做了以下命名改进：

- `proposal-manifest.json` 替代 proposal 阶段的 `manifest.json`。历史未明确区分 proposal manifest 和 apply manifest，现用不同文件名区分。
- `apply-manifest.jsonl` 成为 apply 机器真相（JSONL 格式，支持逐行状态转移）。
- `run/evidence/` 是 runtime evidence 目录（历史未结构化）。

## llmwiki-readme 层级原则

`llmwiki-readme.md` 确认的层级原则写入本 skill 的所有 reference：

| 层级 | 路径 | 职责 | 本 skill 操作 |
| --- | --- | --- | --- |
| 原始归档层 | `archiveRoot` | 保存 Word/PDF/Excel/PPT/图片等原件，是权威档案位置 | 写入（copy + atomic rename） |
| 解析原料层 | `rawSourcesRoot` | 保存由原件解析出来的 Markdown/文本 | 写入（含 raw frontmatter） |
| 来源页层 | `wiki/sources/` | 保存每份资料来源摘要、关键内容 | 不写 |
| 知识沉淀层 | `wiki/concepts/` 等 | 保存概念、实体、项目、决策、会议、综合总结 | 不写 |

稳定流程：

```
原始文档 → 资料库归档 → raw/sources 解析 → wiki/sources 来源页 → wiki 知识沉淀
```

本 skill 覆盖前半段（原始文档 → 归档 → raw/sources 解析），不涉及 wiki 层。

## 不做事项

以下内容明确不在本 skill 范围内：

- 不写 `.llm-wiki/`
- 不生成或修改 `wiki/sources`、`concepts`、`entities`、`projects`、`decisions`、`meetings`、`synthesis`
- 不写 `wiki/index.md`、`wiki/log.md`
