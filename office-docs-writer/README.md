# office-docs-writer 目录结构说明

## 结构概览

```
office-docs-writer/
├── SKILL.md                    # 技能入口（thin，~71行）
├── README.md                   # 本文件
├── agent-config.md             # agent 路由配置（权威）
├── agent-workflow.md           # 用户操作指南
├── quick-templates.md          # 快速调用模板索引（迁移用）
│
├── workflows/
│   ├── general-writing-workflow.md     # 通用写作流程（抽象）
│   └── source-fusion-workflow.md       # 多源信息融合协议
│
├── guidelines/
│   ├── formal-style.md                 # 格式规范（页面版式、行距、字体）
│   ├── political-stance.md             # 政治表述规范
│   ├── information-source-processing.md # 信息源处理规范
│   └── context-variables.md            # 上下文变量命名规范
│
├── document-types/
│   ├── README.md
│   ├── thematic-meeting-record/        # 专题会议记录（最成熟）
│   │   ├── template.md
│   │   ├── checklist.md
│   │   └── source-requirements.md
│   ├── study-record/                   # 学习记录
│   │   ├── template.md
│   │   ├── checklist.md
│   │   └── source-requirements.md
│   ├── work-summary/                   # 工作总结（草稿）
│   │   ├── template.md
│   │   ├── checklist.md
│   │   └── source-requirements.md
│   ├── work-brief/                     # 工作简报（草稿）
│   │   ├── template.md
│   │   ├── checklist.md
│   │   └── source-requirements.md
│   ├── news-snippet/                   # 新闻稿（草稿）
│   │   ├── template.md
│   │   ├── checklist.md
│   │   └── source-requirements.md
│   └── meeting-minutes/                # 会议纪要（轻量）
│       ├── template.md
│       ├── checklist.md
│       └── source-requirements.md
│
├── validators/
│   ├── factual-checklist.md            # 事实核查
│   ├── source-coverage-checklist.md    # 信息源覆盖
│   ├── policy-alignment-checklist.md   # 政策一致性
│   ├── style-checklist.md              # 格式规范
│   └── sensitive-content-checklist.md  # 敏感内容
│
├── quick-prompts/
│   ├── thematic-record.md
│   ├── study-record.md
│   ├── work-summary.md
│   ├── work-brief.md
│   ├── news-snippet.md
│   └── meeting-minutes.md
│
├── templates/                          # 遗留兼容层（勿用于新任务）
│   ├── work-report.md
│   ├── party-report.md
│   ├── discipline-report.md
│   ├── meeting-record-party-discipline.md
│   ├── quarterly-work-tracking.md
│   └── usage-examples.md
│
├── sources/
│   ├── README.md
│   └── mixed-source-input-template.md
│
├── examples/
│   └── README.md
│
└── maintenance/
    ├── change-log.md
    ├── backlog.md
    ├── source-catalog.md
    └── hardcoding-review-checklist.md
```

## 各层状态

| 层 | 状态 | 说明 |
|----|------|------|
| entry layer | ✅ 可用 | SKILL.md、agent-config.md、agent-workflow.md |
| workflows/ | ✅ 可用 | 通用流程 + 多源融合协议 |
| guidelines/ | ✅ 可用 | 格式/政治/信息源三类规范 |
| document-types/ | ⚠️ 部分完整 | thematic-meeting-record 和 study-record 最成熟；其余为草稿 |
| validators/ | ✅ 可用 | 五类校验清单均已提供 |
| quick-prompts/ | ✅ 可用 | 六类结构化输入模板 |
| templates/ | ⚠️ 遗留 | 仅向后兼容，新任务用 document-types/ |
| sources/ | ✅ 可用 | 通用多源输入模板 |
| examples/ | ❌ 待补充 | 尚无完整示例 |
| maintenance/ | ✅ 可用 | 变更日志、待办、源目录、硬编码审查 |
