---
name: llmwiki-inbox-ingest
description: This skill should be used when running weekly inbox cleanup, ingesting non-Markdown documents into a knowledge vault, or migrating files from inbox to theme/year archive with human approval gating.
---

# llmwiki-inbox-ingest

## 概述

本 skill 实现了一个可复用、可移植、人工审批门控的 inbox 原始文件处理流程，把 inbox 中的非 Markdown 原始文件安全地转化为分类提案、人工审批后的归档副本、MinerU 解析批次和可追溯的 `raw/sources` Markdown 原料。

架构固定为：配置解析与初始化 → scan inventory → proposal dry-run → 人工审批 → 带锁的 copy+hash+atomic rename apply → committed-only MinerU bridge → raw/sources ingest → validate-run。

所有路径来自 config 或 CLI 参数，脚本不得内置项目路径默认值。源文件始终保留在原位，使用 copy + SHA256 verify + atomic rename 写入 archive。

## 五分钟每周流程

操作者每周执行以下步骤：

1. **初始化或确认 config：** 运行 `--init` 生成示例配置，或在当前目录及父目录中确认 `.llmwiki-ingest/config.json` 存在且字段正确。缺失配置时拒绝一切后续操作。

2. **Scan inventory：** 运行 `scan-inbox.ps1`，递归扫描 `inboxRoot` 下所有文件，生成 `inventory.jsonl` 和 `source_snapshot_before.csv`。

3. **Build proposal：** 运行 `build-proposal.ps1`，产出 `classification-plan.jsonl`、`classification-proposal.md` 和 `proposal-manifest.json`。该阶段不产生正式写入。

4. **人工审阅 proposal：** 阅读 `classification-proposal.md`，确认分类建议是否合理。在 run 目录中找到生成的 `approval.md` 模板，严格按照 11 字段 YAML schema 手动编辑：将 `status` 改为 `approved`、`allow_apply` 改为 `true`，并填入审批人和时间。agent 和脚本均不得写入 `status: approved`。

5. **Apply approved batch：** 运行 `apply-approved-plan.ps1`。该脚本先做 approval gate 校验（11 字段 schema、hash 匹配、run_id/scope 匹配、agent/script 未自动批准），通过后逐项执行 copy + SHA256 verify + atomic rename，并写 `apply-manifest.jsonl`、`source_snapshot_after.csv`、`source_snapshot_diff.csv`。

6. **Prepare MinerU batch：** 运行 `prepare-mineru-batch.ps1`，仅从 `apply-manifest.jsonl` 中 `committed` 或 `skipped_existing_committed` 的 archive 文件生成 `mineru-batch.json`。未 committed 的文件不得进入批次。

7. **Agent 调 MinerU：** agent 读取 `mineru-batch.json`，按 source_id 调用 `mineru_parse_documents` MCP 工具，输出保存到 `run/mineru-output/<source_id>/`。PowerShell 脚本不得直接调用 MCP。

8. **Ingest raw 与 validate：** 运行 `ingest-mineru-output.ps1` 将合格 Markdown 写入 `rawSourcesRoot`，带 raw frontmatter；然后运行 `validate-run.ps1` 检查全链路产物完整性。

## 参考文档

详细 schema、安全契约和配置规则分布在 `references/` 目录中：

| 文件 | 内容 |
| --- | --- |
| `references/configuration.md` | 配置发现规则、`--init` 行为、运行目录格式、错误信息标准 |
| `references/taxonomy.md` | scan 排除规则、年份正则、pack 规则、主题推断、扩展名策略 |
| `references/path-safety.md` | PowerShell 编码契约、safe filename、Unicode NFC、Windows 保留名、collision suffix、canonical containment |
| `references/run-artifacts.md` | 全部 10 种运行产物的 schema、字段表和示例 |
| `references/approval-schema.md` | 11 字段 YAML schema 和 fail-closed 规则 |
| `references/human-approval.md` | 人工审批工作流、如何编辑 approval.md、禁止事项 |
| `references/idempotency.md` | apply-manifest 状态机、幂等重跑规则、失败清理 |
| `references/mineru-bridge-contract.md` | capability matrix、committed-only batch、mock mode、agent bridge 步骤 |
| `references/raw-source-frontmatter.md` | raw frontmatter 字段、来源规则、质量门、collision suffix |
| `references/borrowed-rules.md` | 历史 artifact 命名模式、安全规则传承、llmwiki-readme 层级原则 |

## 资源

### scripts/
PowerShell 7 脚本，每个脚本首行 `#Requires -Version 7.0`，输出 UTF-8 no BOM。分为七个执行阶段：`resolve-config.ps1`、`scan-inbox.ps1`、`build-proposal.ps1`、`apply-approved-plan.ps1`、`prepare-mineru-batch.ps1`、`ingest-mineru-output.ps1`、`validate-run.ps1`。

### references/
10 份参考文档，定义所有 schema、安全契约、配置规则和操作流程。详细内容在对应文件中。

### assets/
`example-config.json`（完整字段的示例配置）和 `approval-template.md`（11 字段 YAML 默认模板）。`tests/fixtures/` 存放 fixture 测试用例，通过 `tests/run-tests.ps1` 执行。

## 操作者 UX 与错误标准

- 每个脚本错误必须说明：发生了什么、哪个文件或字段出错、期望值是什么、下一步怎么修。
- 缺配置、pending approval、hash mismatch、source changed、target exists、path escape、raw quality failed 等场景一律 fail closed，并把可执行修复动作写入 stderr 或 `failures.csv`。
- 操作者只需要按五分钟每周流程顺序推进；任何非零退出都先阅读对应 run artifact 和 `failures.csv`，修复后重新从安全阶段开始。
- PowerShell 脚本不调用 MinerU MCP；agent 根据 `mineru-batch.json` 调用 MCP 或使用 mock mode fixture。

## 硬边界

- 不删除 inbox 源文件。
- 不把源文件移动到归档目录。
- 不覆盖正式归档文件。
- 不自动批准 `approval.md`。
- 不写 `.llm-wiki/`。
- 不把 `E:\llmwikivault`、`资料库`、`bocd-working-wiki` 作为脚本默认值或逻辑常量。
- 不直接写入真实 opencode skills 目录；staging 产出 zip 和 install notes。
